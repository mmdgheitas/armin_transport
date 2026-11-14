"""Unit tests for the database-backed rate limiter."""

from __future__ import annotations

import threading

import pytest
from flask import Flask
from sqlalchemy.exc import OperationalError

from app.config import RateLimitRule
from app.core.errors import RateLimitExceededError
from app.core.rate_limit import RateLimiter
from app.extensions import db
from app.models import RateLimitCounter


class FakeClock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock()


@pytest.fixture
def limiter(app_context: None, clock: FakeClock) -> RateLimiter:
    return RateLimiter(lambda: db.engine, clock=clock)


RULE = RateLimitRule(limit=3, window_seconds=60)


def test_events_within_the_limit_are_allowed(limiter: RateLimiter) -> None:
    statuses = [limiter.hit("scope", RULE, "key") for _ in range(3)]
    assert [status.allowed for status in statuses] == [True, True, True]
    assert [status.count for status in statuses] == [1, 2, 3]


def test_event_over_the_limit_is_rejected_with_retry_after(limiter: RateLimiter, clock: FakeClock) -> None:
    clock.now = 1_800_000_000.0 - (1_800_000_000.0 % 60) + 10  # 10 s into a window
    for _ in range(3):
        limiter.enforce("scope", RULE, "key")
    with pytest.raises(RateLimitExceededError) as error:
        limiter.enforce("scope", RULE, "key")
    assert error.value.status_code == 429
    assert error.value.headers["Retry-After"] == "50"
    assert error.value.details["retry_after_seconds"] == 50


def test_keys_and_scopes_are_independent(limiter: RateLimiter) -> None:
    for _ in range(3):
        limiter.enforce("scope", RULE, "client-a")
    assert limiter.hit("scope", RULE, "client-b").allowed
    assert limiter.hit("other-scope", RULE, "client-a").allowed
    assert not limiter.hit("scope", RULE, "client-a").allowed


def test_limit_resets_in_the_next_window(limiter: RateLimiter, clock: FakeClock) -> None:
    for _ in range(4):
        limiter.hit("scope", RULE, "key")
    assert not limiter.peek("scope", RULE, "key").allowed
    clock.now += 60
    assert limiter.peek("scope", RULE, "key").allowed
    assert limiter.hit("scope", RULE, "key").count == 1


def test_peek_does_not_record_an_event(limiter: RateLimiter) -> None:
    for _ in range(10):
        assert limiter.peek("scope", RULE, "key").allowed
    assert limiter.hit("scope", RULE, "key").count == 1


def test_ensure_available_raises_only_when_exhausted(limiter: RateLimiter) -> None:
    for _ in range(3):
        limiter.ensure_available("scope", RULE, "key")
        limiter.hit("scope", RULE, "key")
    with pytest.raises(RateLimitExceededError):
        limiter.ensure_available("scope", RULE, "key")


def test_reset_clears_a_key(limiter: RateLimiter) -> None:
    for _ in range(5):
        limiter.hit("scope", RULE, "key")
    limiter.reset("scope", "key")
    assert limiter.hit("scope", RULE, "key").count == 1


def test_keys_are_stored_hashed(limiter: RateLimiter) -> None:
    limiter.hit("login_ip", RULE, "203.0.113.77")
    stored = db.session.scalars(db.select(RateLimitCounter.key_hash)).all()
    assert len(stored) == 1
    assert "203.0.113.77" not in stored[0]
    assert len(stored[0]) == 64


def test_purge_removes_only_expired_counters(limiter: RateLimiter, clock: FakeClock) -> None:
    limiter.hit("scope", RULE, "old")
    clock.now += 600
    limiter.hit("scope", RULE, "fresh")
    assert limiter.purge_expired() == 1
    assert db.session.scalar(db.select(db.func.count()).select_from(RateLimitCounter)) == 1


def test_disabled_limiter_allows_everything(app_context: None) -> None:
    limiter = RateLimiter(lambda: db.engine, enabled=False)
    for _ in range(20):
        limiter.enforce("scope", RULE, "key")
    assert db.session.scalar(db.select(db.func.count()).select_from(RateLimitCounter)) == 0


@pytest.mark.parametrize("round_number", range(5))
def test_concurrent_hits_are_all_counted(app: Flask, round_number: int) -> None:
    """Many workers hitting a counter that does not exist yet: no lost updates, no deadlocks."""
    rule = RateLimitRule(limit=10_000, window_seconds=3600)
    threads_count, hits_per_thread = 12, 15
    errors: list[BaseException] = []
    counts: list[int] = []
    start = threading.Barrier(threads_count)

    def worker() -> None:
        try:
            with app.app_context():
                limiter = RateLimiter(lambda: db.engine)
                start.wait(timeout=10)
                for _ in range(hits_per_thread):
                    counts.append(limiter.hit("concurrent", rule, f"shared-key-{round_number}").count)
        except BaseException as exc:  # pragma: no cover - reported through the assertion below
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(threads_count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    with app.app_context():
        total = db.session.scalar(db.select(db.func.sum(RateLimitCounter.count)))
        db.session.remove()
    assert total == threads_count * hits_per_thread
    # Every event observed a distinct position in the window: the limit can never be overshot.
    assert sorted(counts) == list(range(1, threads_count * hits_per_thread + 1))


def test_transient_lock_errors_are_retried_and_others_fail_closed(
    app_context: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    limiter = RateLimiter(lambda: db.engine)
    failures = {"remaining": 2, "code": 1213}
    original_begin = db.engine.begin

    def begin_with_failures() -> object:
        """Fails like MySQL does for a deadlock victim, a given number of times."""
        if failures["remaining"] > 0:
            failures["remaining"] -= 1
            raise OperationalError("INSERT", {}, Exception(failures["code"], "simulated"))
        return original_begin()

    monkeypatch.setattr(db.engine, "begin", begin_with_failures)

    assert limiter.hit("retry", RULE, "key").count == 1  # two deadlocks, the third attempt succeeds

    failures.update(remaining=3, code=1213)
    with pytest.raises(OperationalError):
        limiter.hit("retry", RULE, "key")  # gives up after three attempts: the request is rejected

    failures.update(remaining=1, code=2006)  # "server has gone away" is not a lock error: no blind retry
    with pytest.raises(OperationalError):
        limiter.hit("retry", RULE, "key")
    assert failures["remaining"] == 0

    monkeypatch.undo()
    assert limiter.hit("retry", RULE, "key").count == 2  # failed attempts were never counted
