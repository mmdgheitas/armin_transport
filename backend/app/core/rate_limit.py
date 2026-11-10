"""Database-backed fixed-window rate limiter.

Counters live in MySQL so limits are shared by all application workers without
an additional service (e.g. Redis). Every operation runs in its own short
transaction on a dedicated connection, so a hit is recorded even when the
surrounding request fails or rolls back. If the counter cannot be updated the
error propagates and the request is rejected (the limiter fails closed).
"""

from __future__ import annotations

import hashlib
import logging
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.dialects.mysql import insert as mysql_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.engine import Connection, Engine
from sqlalchemy.exc import DBAPIError
from sqlalchemy.sql.expression import Executable

from app.config import RateLimitRule
from app.core.db_utils import affected_rows, is_transient_lock_error, table_of
from app.core.errors import RateLimitExceededError
from app.models.rate_limit import RateLimitCounter

logger = logging.getLogger(__name__)

_CLEANUP_PROBABILITY_DENOMINATOR = 50
_MAX_ATTEMPTS = 3


@dataclass(frozen=True)
class RateLimitStatus:
    allowed: bool
    count: int
    limit: int
    retry_after_seconds: int


class RateLimiter:
    def __init__(
        self,
        engine_provider: Callable[[], Engine],
        *,
        enabled: bool = True,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._engine_provider = engine_provider
        self._enabled = enabled
        self._clock = clock

    @staticmethod
    def _hash_key(key: str) -> str:
        return hashlib.sha256(key.encode("utf-8")).hexdigest()

    def _window(self, rule: RateLimitRule) -> tuple[int, int]:
        now = self._clock()
        window_start = int(now // rule.window_seconds) * rule.window_seconds
        retry_after = max(1, int(window_start + rule.window_seconds - now))
        return window_start, retry_after

    def _status(self, rule: RateLimitRule, count: int, retry_after: int, *, inclusive: bool) -> RateLimitStatus:
        allowed = count <= rule.limit if inclusive else count < rule.limit
        return RateLimitStatus(allowed=allowed, count=count, limit=rule.limit, retry_after_seconds=retry_after)

    def _increment_statement(self, engine: Engine, values: dict[str, Any]) -> Executable:
        """One atomic "insert the counter or add one to it" statement.

        A single upsert avoids the lock-upgrade deadlocks of the classic
        UPDATE-then-INSERT sequence when many requests hit a new counter at once.
        """
        table = table_of(RateLimitCounter)
        if engine.dialect.name == "mysql":
            return mysql_insert(table).values(**values).on_duplicate_key_update(count=table.c.count + 1)
        if engine.dialect.name == "sqlite":  # test fallback
            return (
                sqlite_insert(table)
                .values(**values)
                .on_conflict_do_update(
                    index_elements=[table.c.scope, table.c.key_hash, table.c.window_start],
                    set_={"count": table.c.count + 1},
                )
            )
        raise NotImplementedError(f"Rate limiting is not implemented for the '{engine.dialect.name}' dialect.")

    def hit(self, scope: str, rule: RateLimitRule, key: str) -> RateLimitStatus:
        """Record one event and report whether it is still within the limit."""
        if not self._enabled:
            return RateLimitStatus(True, 0, rule.limit, 0)
        window_start, retry_after = self._window(rule)
        table = table_of(RateLimitCounter)
        values: dict[str, Any] = {
            "scope": scope,
            "key_hash": self._hash_key(key),
            "window_start": window_start,
            "count": 1,
            "expires_at": datetime.fromtimestamp(window_start, tz=UTC) + timedelta(seconds=rule.window_seconds * 2),
        }
        match = (
            (table.c.scope == scope) & (table.c.key_hash == values["key_hash"]) & (table.c.window_start == window_start)
        )
        engine = self._engine_provider()
        increment = self._increment_statement(engine, values)
        for attempt in range(1, _MAX_ATTEMPTS + 1):
            try:
                with engine.begin() as connection:
                    connection.execute(increment)
                    count = int(connection.execute(select(table.c.count).where(match)).scalar_one())
                break
            except DBAPIError as error:
                if attempt == _MAX_ATTEMPTS or not is_transient_lock_error(error):
                    raise  # fail closed: the request is rejected rather than left uncounted
        if secrets.randbelow(_CLEANUP_PROBABILITY_DENOMINATOR) == 0:
            self._purge_quietly()
        return self._status(rule, count, retry_after, inclusive=True)

    def peek(self, scope: str, rule: RateLimitRule, key: str) -> RateLimitStatus:
        """Report whether another event would be allowed, without recording one."""
        if not self._enabled:
            return RateLimitStatus(True, 0, rule.limit, 0)
        window_start, retry_after = self._window(rule)
        table = table_of(RateLimitCounter)
        statement = select(table.c.count).where(
            (table.c.scope == scope)
            & (table.c.key_hash == self._hash_key(key))
            & (table.c.window_start == window_start)
        )
        with self._engine_provider().connect() as connection:
            count = int(connection.execute(statement).scalar() or 0)
        return self._status(rule, count, retry_after, inclusive=False)

    def enforce(self, scope: str, rule: RateLimitRule, key: str) -> None:
        """Record one event and raise :class:`RateLimitExceededError` when over the limit."""
        status = self.hit(scope, rule, key)
        if not status.allowed:
            raise RateLimitExceededError(status.retry_after_seconds)

    def ensure_available(self, scope: str, rule: RateLimitRule, key: str) -> None:
        """Raise when the limit is already exhausted, without recording an event."""
        status = self.peek(scope, rule, key)
        if not status.allowed:
            raise RateLimitExceededError(status.retry_after_seconds)

    def reset(self, scope: str, key: str) -> None:
        if not self._enabled:
            return
        table = table_of(RateLimitCounter)
        with self._engine_provider().begin() as connection:
            connection.execute(
                delete(table).where((table.c.scope == scope) & (table.c.key_hash == self._hash_key(key)))
            )

    def purge_expired(self) -> int:
        with self._engine_provider().begin() as connection:
            return self._purge(connection)

    def _purge_quietly(self) -> None:
        """Opportunistic clean-up; never allowed to fail the request that triggered it."""
        try:
            self.purge_expired()
        except DBAPIError:
            logger.warning("Opportunistic rate-limit counter clean-up failed", exc_info=True)

    def _purge(self, connection: Connection) -> int:
        table = table_of(RateLimitCounter)
        now = datetime.fromtimestamp(self._clock(), tz=UTC)
        return affected_rows(connection.execute(delete(table).where(table.c.expires_at < now)))
