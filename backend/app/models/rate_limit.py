"""Fixed-window counters backing the database rate limiter."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db_types import UTCDateTime
from app.models.base import TABLE_OPTIONS, Model


class RateLimitCounter(Model):
    """Number of events for one (scope, key) in one time window.

    A natural composite key is used instead of a UUID because the row *is* the
    counter identity; keys are stored hashed so raw IPs/usernames are not kept.
    """

    __tablename__ = "rate_limit_counters"
    __table_args__ = (Index("ix_rate_limit_counters_expires_at", "expires_at"), TABLE_OPTIONS)

    scope: Mapped[str] = mapped_column(String(50), primary_key=True)
    key_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    window_start: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
