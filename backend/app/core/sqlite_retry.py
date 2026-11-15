"""Restart uncommitted SQLite requests after a WAL snapshot/write conflict.

SQLite has one writer and no SELECT FOR UPDATE. A request that read a snapshot
before another worker committed cannot upgrade it to a writer (BUSY_SNAPSHOT).
Retry the whole request, including authentication and quota checks, never just
its last INSERT. Never replay a request after a top-level ORM commit.
"""

from __future__ import annotations

import sqlite3
import time
from collections.abc import Callable
from functools import wraps
from typing import ParamSpec, TypeVar

from flask import request
from sqlalchemy import event
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from app.extensions import db

P = ParamSpec("P")
R = TypeVar("R")
_COMMIT_KEY = "sqlite_request_commits"
_MAX_ATTEMPTS = 6


@event.listens_for(Session, "after_commit")
def _remember_commit(session: Session) -> None:
    # Releasing a SAVEPOINT isn't a durable commit of the enclosing transaction.
    if not session.in_nested_transaction():
        session.info[_COMMIT_KEY] = session.info.get(_COMMIT_KEY, 0) + 1


def retry_sqlite_request(operation: Callable[P, R]) -> Callable[P, R]:
    @wraps(operation)
    def wrapped(*args: P.args, **kwargs: P.kwargs) -> R:
        if db.session.get_bind().dialect.name != "sqlite":
            return operation(*args, **kwargs)
        commits = db.session.info.get(_COMMIT_KEY, 0)
        for attempt in range(_MAX_ATTEMPTS):
            try:
                return operation(*args, **kwargs)
            except OperationalError as error:
                code = getattr(error.orig, "sqlite_errorcode", 0) or 0
                if (
                    code & 0xFF not in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED}
                    or db.session.info.get(_COMMIT_KEY, 0) != commits
                    or attempt == _MAX_ATTEMPTS - 1
                ):
                    raise
                db.session.rollback()
                # DocumentService compensates file writes on rollback. Rewind the
                # original uploads so a retry hashes and stores the complete bytes.
                for _, upload in request.files.items(multi=True):
                    try:
                        upload.stream.seek(0)
                    except (OSError, ValueError):
                        raise error from None
                time.sleep(0.01 * 2**attempt)
        raise AssertionError("unreachable")

    return wrapped
