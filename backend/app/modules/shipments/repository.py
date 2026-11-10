"""Data access for shipments and tracking-code history."""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session, scoped_session

from app.core.pagination import Page, escape_like, paginate
from app.models import Document, Shipment, ShipmentStatus, TrackingCodeHistory, TrackingCodeType
from app.modules.shipments.tracking_codes import normalize_tracking_code

SORT_OPTIONS = {
    "created_at": (Shipment.created_at.asc(), Shipment.id.asc()),
    "-created_at": (Shipment.created_at.desc(), Shipment.id.desc()),
    "updated_at": (Shipment.updated_at.asc(), Shipment.id.asc()),
    "-updated_at": (Shipment.updated_at.desc(), Shipment.id.desc()),
    "tracking_code": (Shipment.tracking_code.asc(),),
    "-tracking_code": (Shipment.tracking_code.desc(),),
}
DEFAULT_SORT = "-created_at"


class ShipmentRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def get_scoped(
        self, shipment_id: uuid.UUID, company_id: uuid.UUID | None, *, for_update: bool = False
    ) -> Shipment | None:
        """Load a shipment; when ``company_id`` is given the tenant filter is part of the query."""
        statement = select(Shipment).where(Shipment.id == shipment_id)
        if company_id is not None:
            statement = statement.where(Shipment.company_id == company_id)
        if for_update:
            statement = statement.with_for_update(of=Shipment)
        return self._session.scalar(statement)

    def get_by_tracking_code(self, tracking_code: str) -> Shipment | None:
        return self._session.scalar(select(Shipment).where(Shipment.tracking_code == tracking_code))

    def code_ever_used(self, tracking_code: str) -> bool:
        """True when the code is, or ever was, assigned to any shipment."""
        current = select(Shipment.id).where(Shipment.tracking_code == tracking_code).limit(1)
        historic = select(TrackingCodeHistory.id).where(TrackingCodeHistory.new_code == tracking_code).limit(1)
        return self._session.scalar(current) is not None or self._session.scalar(historic) is not None

    def search(
        self,
        *,
        page: int,
        per_page: int,
        company_id: uuid.UUID | None = None,
        status: ShipmentStatus | None = None,
        tracking_code: str | None = None,
        tracking_code_type: TrackingCodeType | None = None,
        q: str | None = None,
        created_by: uuid.UUID | None = None,
        created_from: datetime | None = None,
        created_to: datetime | None = None,
        sort: str = DEFAULT_SORT,
    ) -> Page[Shipment]:
        statement = select(Shipment)
        if company_id is not None:
            statement = statement.where(Shipment.company_id == company_id)
        if status is not None:
            statement = statement.where(Shipment.status == status)
        if tracking_code:
            statement = statement.where(Shipment.tracking_code == tracking_code)
        if tracking_code_type is not None:
            statement = statement.where(Shipment.tracking_code_type == tracking_code_type)
        if created_by is not None:
            statement = statement.where(Shipment.created_by == created_by)
        if created_from is not None:
            statement = statement.where(Shipment.created_at >= created_from)
        if created_to is not None:
            statement = statement.where(Shipment.created_at <= created_to)
        if q:
            conditions = [Shipment.description.like(f"%{escape_like(q)}%", escape="\\")]
            # A code is matched in its stored form, however it was typed (Persian digits, lower case, spaces).
            code = normalize_tracking_code(q)
            if code:
                conditions.append(Shipment.tracking_code.like(f"%{escape_like(code)}%", escape="\\"))
            statement = statement.where(or_(*conditions))
        statement = statement.order_by(*SORT_OPTIONS.get(sort, SORT_OPTIONS[DEFAULT_SORT]))
        return paginate(self._session, statement, page, per_page)

    def document_counts(self, shipment_ids: Sequence[uuid.UUID]) -> dict[uuid.UUID, int]:
        if not shipment_ids:
            return {}
        statement = (
            select(Document.shipment_id, func.count())
            .where(Document.shipment_id.in_(shipment_ids), Document.deleted_at.is_(None))
            .group_by(Document.shipment_id)
        )
        return {shipment_id: int(count) for shipment_id, count in self._session.execute(statement).all()}

    def history(self, shipment_id: uuid.UUID, page: int, per_page: int) -> Page[TrackingCodeHistory]:
        statement = (
            select(TrackingCodeHistory)
            .where(TrackingCodeHistory.shipment_id == shipment_id)
            .order_by(TrackingCodeHistory.changed_at.desc(), TrackingCodeHistory.id.desc())
        )
        return paginate(self._session, statement, page, per_page)
