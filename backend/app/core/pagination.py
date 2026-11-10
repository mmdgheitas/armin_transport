"""Pagination primitives for collection endpoints."""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Generic, TypeVar

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session, scoped_session

T = TypeVar("T")


@dataclass(frozen=True)
class Page(Generic[T]):
    """One page of results plus the metadata required by clients."""

    items: Sequence[T]
    total: int
    page: int
    per_page: int

    @property
    def total_pages(self) -> int:
        return math.ceil(self.total / self.per_page) if self.per_page else 0

    def meta(self) -> dict[str, Any]:
        return {
            "page": self.page,
            "per_page": self.per_page,
            "total": self.total,
            "total_pages": self.total_pages,
            "has_next": self.page < self.total_pages,
            "has_prev": self.page > 1,
        }


def paginate(
    session: Session | scoped_session[Session],
    statement: Select[tuple[T]],
    page: int,
    per_page: int,
) -> Page[T]:
    """Execute ``statement`` for a single page and count the unpaginated total."""
    count_statement = select(func.count()).select_from(statement.order_by(None).subquery())
    total = int(session.scalar(count_statement) or 0)
    items = session.scalars(statement.limit(per_page).offset((page - 1) * per_page)).all()
    return Page(items=items, total=total, page=page, per_page=per_page)


def escape_like(term: str, escape: str = "\\") -> str:
    """Escape LIKE wildcards so user input is always matched literally."""
    return term.replace(escape, escape * 2).replace("%", f"{escape}%").replace("_", f"{escape}_")
