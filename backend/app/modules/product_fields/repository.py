"""Data access for product field definitions and shipment values."""

from __future__ import annotations

import uuid
from collections.abc import Sequence

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session, scoped_session

from app.core.pagination import Page, escape_like, paginate
from app.models import ProductFieldDefinition, ShipmentProductValue


class ProductFieldRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def get(self, definition_id: uuid.UUID) -> ProductFieldDefinition | None:
        return self._session.get(ProductFieldDefinition, definition_id)

    def active_key_exists(self, field_key: str, exclude_id: uuid.UUID | None = None) -> bool:
        statement = (
            select(func.count())
            .select_from(ProductFieldDefinition)
            .where(ProductFieldDefinition.field_key == field_key, ProductFieldDefinition.is_active.is_(True))
        )
        if exclude_id is not None:
            statement = statement.where(ProductFieldDefinition.id != exclude_id)
        return bool(self._session.scalar(statement))

    def search(
        self, *, page: int, per_page: int, include_inactive: bool, q: str | None = None
    ) -> Page[ProductFieldDefinition]:
        statement = select(ProductFieldDefinition)
        if not include_inactive:
            statement = statement.where(ProductFieldDefinition.is_active.is_(True))
        if q:
            pattern = f"%{escape_like(q)}%"
            statement = statement.where(
                or_(
                    ProductFieldDefinition.field_key.like(pattern, escape="\\"),
                    ProductFieldDefinition.label.like(pattern, escape="\\"),
                )
            )
        statement = statement.order_by(
            ProductFieldDefinition.display_order, ProductFieldDefinition.label, ProductFieldDefinition.id
        )
        return paginate(self._session, statement, page, per_page)

    def active_definitions(self) -> Sequence[ProductFieldDefinition]:
        statement = (
            select(ProductFieldDefinition)
            .where(ProductFieldDefinition.is_active.is_(True))
            .order_by(ProductFieldDefinition.display_order, ProductFieldDefinition.label, ProductFieldDefinition.id)
        )
        return self._session.scalars(statement).all()

    def values_for_shipment(self, shipment_id: uuid.UUID) -> Sequence[ShipmentProductValue]:
        statement = select(ShipmentProductValue).where(ShipmentProductValue.shipment_id == shipment_id)
        return self._session.scalars(statement).all()
