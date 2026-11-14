"""Dashboard summary service."""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from sqlalchemy import case, func, select
from sqlalchemy.orm import Session, scoped_session

from app.core.actor import Actor
from app.models import Company, Document, Shipment, ShipmentStatus, User, UserRole
from app.modules.shipments.service import ShipmentService, ShipmentView

RECENT_SHIPMENT_COUNT = 5


@dataclass(frozen=True)
class ActiveCount:
    total: int
    active: int


@dataclass(frozen=True)
class ShipmentCount:
    total: int
    active: int
    archived: int


@dataclass(frozen=True)
class DashboardSummary:
    scope: str
    company: Company | None
    companies: ActiveCount | None
    employees: ActiveCount | None
    shipments: ShipmentCount
    documents: int
    recent_shipments: list[ShipmentView]


class DashboardService:
    def __init__(self, session: scoped_session[Session], shipments: ShipmentService) -> None:
        self._session = session
        self._shipments = shipments

    def _active_count(self, model: type[Company] | type[User], *conditions: object) -> ActiveCount:
        statement = select(
            func.count(), func.coalesce(func.sum(case((model.is_active.is_(True), 1), else_=0)), 0)
        ).select_from(model)
        for condition in conditions:
            statement = statement.where(condition)  # type: ignore[arg-type]
        total, active = self._session.execute(statement).one()
        return ActiveCount(total=int(total), active=int(active))

    def _shipment_count(self, company_id: uuid.UUID | None) -> ShipmentCount:
        statement = select(
            func.count(),
            func.coalesce(func.sum(case((Shipment.status == ShipmentStatus.ACTIVE, 1), else_=0)), 0),
        ).select_from(Shipment)
        if company_id is not None:
            statement = statement.where(Shipment.company_id == company_id)
        total, active = self._session.execute(statement).one()
        return ShipmentCount(total=int(total), active=int(active), archived=int(total) - int(active))

    def _document_count(self, company_id: uuid.UUID | None, actor: Actor) -> int:
        statement = select(func.count()).select_from(Document).where(Document.deleted_at.is_(None))
        if company_id is not None:
            statement = statement.join(Shipment, Document.shipment_id == Shipment.id).where(
                Shipment.company_id == company_id
            )
        if actor.role is UserRole.EMPLOYEE:
            statement = statement.where(Document.uploaded_by == actor.user_id)
        return int(self._session.scalar(statement) or 0)

    def summary(self, actor: Actor) -> DashboardSummary:
        """Counters limited to the actor's tenant scope (global only for SUPER_ADMIN)."""
        company_id = self._shipments.scope_company_id(actor)
        is_global = company_id is None
        recent = self._shipments.list_shipments(actor, page=1, per_page=RECENT_SHIPMENT_COUNT)
        return DashboardSummary(
            scope="GLOBAL" if is_global else "COMPANY",
            company=None if is_global else self._session.get(Company, company_id),
            companies=self._active_count(Company) if is_global else None,
            employees=self._active_count(User, User.role == UserRole.EMPLOYEE) if is_global else None,
            shipments=self._shipment_count(company_id),
            documents=self._document_count(company_id, actor),
            recent_shipments=list(recent.items),
        )
