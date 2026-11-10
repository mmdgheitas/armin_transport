"""Shipment and tracking-code history models."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.datetime_utils import utcnow
from app.core.db_types import UTCDateTime
from app.models.base import TABLE_OPTIONS, Model, TimestampMixin, UUIDPrimaryKeyMixin, enum_column
from app.models.company import Company
from app.models.enums import ShipmentStatus, TrackingCodeType
from app.models.user import User


class Shipment(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    __tablename__ = "shipments"
    __table_args__ = (
        UniqueConstraint("tracking_code"),
        Index("ix_shipments_company_id_created_at", "company_id", "created_at"),
        Index("ix_shipments_status", "status"),
        TABLE_OPTIONS,
    )

    company_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("companies.id", ondelete="RESTRICT"), nullable=False)
    tracking_code: Mapped[str] = mapped_column(String(64), nullable=False)
    tracking_code_type: Mapped[TrackingCodeType] = mapped_column(
        enum_column(TrackingCodeType, "tracking_code_type"), nullable=False
    )
    created_by: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    description: Mapped[str | None] = mapped_column(Text)
    status: Mapped[ShipmentStatus] = mapped_column(
        enum_column(ShipmentStatus, "shipment_status"),
        nullable=False,
        default=ShipmentStatus.ACTIVE,
        server_default=ShipmentStatus.ACTIVE.value,
    )

    company: Mapped[Company] = relationship(lazy="joined")
    creator: Mapped[User] = relationship(lazy="joined", foreign_keys=[created_by])


class TrackingCodeHistory(UUIDPrimaryKeyMixin, Model):
    """Append-only record of every tracking code ever assigned to a shipment.

    ``new_code`` is globally unique: a code that was ever assigned can never be
    assigned again, so a retired code cannot grant access to a different shipment.
    """

    __tablename__ = "tracking_code_history"
    __table_args__ = (
        UniqueConstraint("new_code"),
        Index("ix_tracking_code_history_shipment_id_changed_at", "shipment_id", "changed_at"),
        TABLE_OPTIONS,
    )

    shipment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shipments.id", ondelete="RESTRICT"), nullable=False)
    old_code: Mapped[str | None] = mapped_column(String(64))
    new_code: Mapped[str] = mapped_column(String(64), nullable=False)
    changed_by: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    changed_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False, default=utcnow)

    changer: Mapped[User] = relationship(lazy="joined", foreign_keys=[changed_by])
