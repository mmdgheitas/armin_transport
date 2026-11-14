"""Data access for companies."""

from __future__ import annotations

import uuid

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session, scoped_session

from app.core.pagination import Page, escape_like, paginate
from app.models import Company, Shipment, User, UserRole


class CompanyRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def get(self, company_id: uuid.UUID) -> Company | None:
        return self._session.get(Company, company_id)

    def code_exists(self, company_code: str, exclude_id: uuid.UUID | None = None) -> bool:
        statement = select(func.count()).select_from(Company).where(Company.company_code == company_code)
        if exclude_id is not None:
            statement = statement.where(Company.id != exclude_id)
        return bool(self._session.scalar(statement))

    def search(self, *, page: int, per_page: int, q: str | None = None, is_active: bool | None = None) -> Page[Company]:
        statement = select(Company)
        if q:
            pattern = f"%{escape_like(q)}%"
            statement = statement.where(
                or_(Company.name.like(pattern, escape="\\"), Company.company_code.like(pattern, escape="\\"))
            )
        if is_active is not None:
            statement = statement.where(Company.is_active.is_(is_active))
        statement = statement.order_by(Company.name, Company.id)
        return paginate(self._session, statement, page, per_page)

    def count_employees(self, company_id: uuid.UUID) -> int:
        statement = select(func.count()).select_from(User).where(User.company_id == company_id, User.role == UserRole.EMPLOYEE)
        return int(self._session.scalar(statement) or 0)

    def count_shipments(self, company_id: uuid.UUID) -> int:
        statement = select(func.count()).select_from(Shipment).where(Shipment.company_id == company_id)
        return int(self._session.scalar(statement) or 0)
