"""Dynamic product field definitions and per-shipment values."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import JSON, Boolean, Computed, ForeignKey, Integer, String, UniqueConstraint, false, true
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import TABLE_OPTIONS, Model, TimestampMixin, UUIDPrimaryKeyMixin, enum_column
from app.models.enums import ProductFieldType


class ProductFieldDefinition(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    """Global definition of a dynamic product field (managed by SUPER_ADMIN)."""

    __tablename__ = "product_field_definitions"
    __table_args__ = (
        # ``active_field_key`` is NULL for inactive definitions, so the unique index
        # forbids duplicate *active* keys while allowing retired definitions to remain.
        UniqueConstraint("active_field_key"),
        TABLE_OPTIONS,
    )

    field_key: Mapped[str] = mapped_column(String(100), nullable=False, index=True)
    label: Mapped[str] = mapped_column(String(200), nullable=False)
    data_type: Mapped[ProductFieldType] = mapped_column(
        enum_column(ProductFieldType, "product_field_type"), nullable=False
    )
    is_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default=false())
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default=true())
    is_customer_visible: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default=false())
    display_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    validation_rules: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    options: Mapped[list[dict[str, Any]] | None] = mapped_column(JSON)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1, server_default="1")
    active_field_key: Mapped[str | None] = mapped_column(
        String(100), Computed("CASE WHEN is_active THEN field_key ELSE NULL END", persisted=True)
    )


class ShipmentProductValue(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    """Value of one dynamic field for one shipment, validated against ``field_version``."""

    __tablename__ = "shipment_product_values"
    __table_args__ = (UniqueConstraint("shipment_id", "field_definition_id"), TABLE_OPTIONS)

    shipment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shipments.id", ondelete="RESTRICT"), nullable=False)
    field_definition_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("product_field_definitions.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    field_version: Mapped[int] = mapped_column(Integer, nullable=False)
    value: Mapped[Any] = mapped_column(JSON, nullable=False)

    field_definition: Mapped[ProductFieldDefinition] = relationship(lazy="joined")
