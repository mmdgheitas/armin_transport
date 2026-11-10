"""Short-lived, shipment-scoped customer access sessions."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db_types import UTCDateTime
from app.models.base import TABLE_OPTIONS, CreatedAtMixin, Model, UUIDPrimaryKeyMixin
from app.models.shipment import Shipment


class CustomerAccessSession(UUIDPrimaryKeyMixin, CreatedAtMixin, Model):
    """Grants access to exactly one shipment. Only the token hash is stored."""

    __tablename__ = "customer_access_sessions"
    __table_args__ = (
        UniqueConstraint("token_hash"),
        Index("ix_customer_access_sessions_expires_at", "expires_at"),
        TABLE_OPTIONS,
    )

    shipment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("shipments.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    # Snapshot of the code used for the lookup: a later code change invalidates the session.
    tracking_code: Mapped[str] = mapped_column(String(64), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    last_used_at: Mapped[datetime | None] = mapped_column(UTCDateTime())

    shipment: Mapped[Shipment] = relationship(lazy="joined")
