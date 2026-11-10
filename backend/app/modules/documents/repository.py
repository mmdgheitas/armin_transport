"""Data access for documents."""

from __future__ import annotations

import uuid

from sqlalchemy import func, select
from sqlalchemy.orm import Session, contains_eager, scoped_session

from app.core.pagination import Page, paginate
from app.models import Document, Shipment


class DocumentRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def get_scoped(
        self, document_id: uuid.UUID, company_id: uuid.UUID | None, *, for_update: bool = False
    ) -> Document | None:
        """Load a non-deleted document; the tenant filter is applied through its shipment."""
        statement = (
            select(Document)
            .join(Document.shipment)
            .options(contains_eager(Document.shipment))
            .where(Document.id == document_id, Document.deleted_at.is_(None))
        )
        if company_id is not None:
            statement = statement.where(Shipment.company_id == company_id)
        if for_update:
            statement = statement.with_for_update(of=Document)
        return self._session.scalar(statement)

    def get_customer_visible(self, document_id: uuid.UUID, shipment_id: uuid.UUID) -> Document | None:
        """A document is reachable by a customer only inside the shipment of the session."""
        return self._session.scalar(
            select(Document).where(
                Document.id == document_id,
                Document.shipment_id == shipment_id,
                Document.deleted_at.is_(None),
                Document.is_customer_visible.is_(True),
            )
        )

    def list_for_shipment(
        self, shipment_id: uuid.UUID, page: int, per_page: int, *, customer_visible_only: bool = False
    ) -> Page[Document]:
        statement = select(Document).where(Document.shipment_id == shipment_id, Document.deleted_at.is_(None))
        if customer_visible_only:
            statement = statement.where(Document.is_customer_visible.is_(True))
        statement = statement.order_by(Document.created_at.desc(), Document.id.desc())
        return paginate(self._session, statement, page, per_page)

    def count_customer_visible(self, shipment_id: uuid.UUID) -> int:
        statement = (
            select(func.count())
            .select_from(Document)
            .where(
                Document.shipment_id == shipment_id,
                Document.deleted_at.is_(None),
                Document.is_customer_visible.is_(True),
            )
        )
        return int(self._session.scalar(statement) or 0)
