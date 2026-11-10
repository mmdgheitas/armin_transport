"""UTC-only date/time helpers. All timestamps are stored and exchanged in UTC."""

from __future__ import annotations

from datetime import UTC, datetime


def utcnow() -> datetime:
    """Return the current time as a timezone-aware UTC datetime."""
    return datetime.now(UTC)


def ensure_utc(value: datetime) -> datetime:
    """Convert an aware datetime to UTC; naive values are interpreted as UTC."""
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def to_iso(value: datetime | None) -> str | None:
    """Serialize a datetime as ISO 8601 in UTC with millisecond precision, e.g. ``2026-01-31T08:15:30.123Z``."""
    if value is None:
        return None
    return ensure_utc(value).isoformat(timespec="milliseconds").replace("+00:00", "Z")
