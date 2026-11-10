"""Company management application service (SUPER_ADMIN only)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, scoped_session

from app.core.actor import Actor
from app.core.errors import ConflictError, NotFoundError
from app.core.pagination import Page
from app.core.permissions import Permission
from app.core.transactions import unit_of_work
from app.models import Company
from app.modules.audit_logs.service import AuditService
from app.modules.companies.repository import CompanyRepository

_EDITABLE_FIELDS = ("name", "company_code", "phone", "address")


def normalize_company_code(code: str) -> str:
    return code.strip().upper()


@dataclass(frozen=True)
class CompanyDetail:
    """Company plus aggregate counters for the detail view."""

    company: Company
    employee_count: int
    shipment_count: int

    def __getattr__(self, name: str) -> Any:
        # Delegate to the company's columns so one flat schema can serialize the detail view.
        return getattr(self.company, name)


class CompanyService:
    def __init__(self, session: scoped_session[Session], audit: AuditService, companies: CompanyRepository) -> None:
        self._session = session
        self._audit = audit
        self._companies = companies

    def _conflict(self) -> ConflictError:
        return ConflictError(
            "شرکتی با این کد قبلاً ثبت شده است.",
            code="company_code_taken",
            details={"fields": {"company_code": ["این کد شرکت قبلاً استفاده شده است."]}},
        )

    def list_companies(
        self, *, page: int, per_page: int, q: str | None = None, is_active: bool | None = None
    ) -> Page[Company]:
        return self._companies.search(page=page, per_page=per_page, q=q, is_active=is_active)

    def get(self, company_id: uuid.UUID) -> Company:
        company = self._companies.get(company_id)
        if company is None:
            raise NotFoundError("شرکت موردنظر یافت نشد.")
        return company

    def get_detail(self, company_id: uuid.UUID) -> CompanyDetail:
        company = self.get(company_id)
        return CompanyDetail(
            company=company,
            employee_count=self._companies.count_employees(company.id),
            shipment_count=self._companies.count_shipments(company.id),
        )

    def create(self, actor: Actor, data: dict[str, Any]) -> Company:
        code = normalize_company_code(data["company_code"])
        if self._companies.code_exists(code):
            raise self._conflict()
        company = Company(
            name=data["name"],
            company_code=code,
            phone=data.get("phone") or None,
            address=data.get("address") or None,
            is_active=data.get("is_active", True),
        )
        try:
            with unit_of_work(self._session):
                self._session.add(company)
                self._session.flush()
                self._audit.record(
                    "COMPANY_CREATED",
                    "company",
                    company.id,
                    actor_id=actor.user_id,
                    metadata={"name": company.name, "company_code": company.company_code},
                )
        except IntegrityError as exc:
            raise self._conflict() from exc
        return company

    def update(self, actor: Actor, company_id: uuid.UUID, data: dict[str, Any]) -> Company:
        company = self.get(company_id)
        changes: dict[str, Any] = {}

        if "company_code" in data:
            data = {**data, "company_code": normalize_company_code(data["company_code"])}
            if data["company_code"] != company.company_code and self._companies.code_exists(
                data["company_code"], exclude_id=company.id
            ):
                raise self._conflict()
        if "is_active" in data and data["is_active"] != company.is_active:
            actor.require(Permission.COMPANY_SET_ACTIVE)

        try:
            with unit_of_work(self._session):
                for field in _EDITABLE_FIELDS:
                    if field not in data:
                        continue
                    value = data[field] if field in ("name", "company_code") else (data[field] or None)
                    if getattr(company, field) != value:
                        changes[field] = {"from": getattr(company, field), "to": value}
                        setattr(company, field, value)
                if changes:
                    self._audit.record(
                        "COMPANY_UPDATED", "company", company.id, actor_id=actor.user_id, metadata={"changes": changes}
                    )
                if "is_active" in data and data["is_active"] != company.is_active:
                    company.is_active = data["is_active"]
                    self._audit.record(
                        "COMPANY_ACTIVATED" if company.is_active else "COMPANY_DEACTIVATED",
                        "company",
                        company.id,
                        actor_id=actor.user_id,
                    )
        except IntegrityError as exc:
            raise self._conflict() from exc
        return company
