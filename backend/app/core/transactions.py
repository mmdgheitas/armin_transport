"""Explicit transaction boundary for application services."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy.orm import Session, scoped_session


@contextmanager
def unit_of_work(session: Session | scoped_session[Session]) -> Iterator[None]:
    """Commit on success; roll back the whole unit when anything fails."""
    try:
        yield
        session.commit()
    except BaseException:
        session.rollback()
        raise
