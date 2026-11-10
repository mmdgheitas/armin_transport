"""Data access for users."""

from __future__ import annotations

import uuid

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session, scoped_session

from app.core.pagination import Page, escape_like, paginate
from app.models import User, UserRole


def normalize_username(username: str) -> str:
    """Usernames are case-insensitive; the canonical form is trimmed lower case."""
    return username.strip().lower()


class UserRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def get(self, user_id: uuid.UUID) -> User | None:
        return self._session.get(User, user_id)

    def get_by_username(self, username: str) -> User | None:
        return self._session.scalar(select(User).where(User.username == normalize_username(username)))

    def username_exists(self, username: str, exclude_id: uuid.UUID | None = None) -> bool:
        statement = select(func.count()).select_from(User).where(User.username == normalize_username(username))
        if exclude_id is not None:
            statement = statement.where(User.id != exclude_id)
        return bool(self._session.scalar(statement))

    def count_by_company(self, company_id: uuid.UUID) -> int:
        return int(
            self._session.scalar(select(func.count()).select_from(User).where(User.company_id == company_id)) or 0
        )

    def search(
        self,
        *,
        page: int,
        per_page: int,
        company_id: uuid.UUID | None = None,
        role: UserRole | None = None,
        is_active: bool | None = None,
        q: str | None = None,
    ) -> Page[User]:
        statement = select(User)
        if company_id is not None:
            statement = statement.where(User.company_id == company_id)
        if role is not None:
            statement = statement.where(User.role == role)
        if is_active is not None:
            statement = statement.where(User.is_active.is_(is_active))
        if q:
            pattern = f"%{escape_like(q)}%"
            statement = statement.where(
                or_(User.username.like(pattern, escape="\\"), User.full_name.like(pattern, escape="\\"))
            )
        statement = statement.order_by(User.created_at.desc(), User.id)
        return paginate(self._session, statement, page, per_page)
