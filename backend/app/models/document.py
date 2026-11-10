"""Shipment document metadata (file bytes live in private storage)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, ForeignKey, Index, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db_types import UTCDateTime
from app.models.base import TABLE_OPTIONS, CreatedAtMixin, Model, UUIDPrimaryKeyMixin
from app.models.shipment import Shipment
from app.models.user import User


class Document(UUIDPrimaryKeyMixin, CreatedAtMixin, Model):
    __tablename__ = "documents"
    __table_args__ = (
        UniqueConstraint("storage_name"),
        Index("ix_documents_shipment_id_deleted_at", "shipment_id", "deleted_at"),
        TABLE_OPTIONS,
    )

    shipment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shipments.id", ondelete="RESTRICT"), nullable=False)
    uploaded_by: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    original_name: Mapped[str] = mapped_column(String(255), nullable=False)
    storage_name: Mapped[str] = mapped_column(String(255), nullable=False)
    storage_path: Mapped[str] = mapped_column(String(500), nullable=False)
    mime_type: Mapped[str] = mapped_column(String(150), nullable=False)
    extension: Mapped[str] = mapped_column(String(20), nullable=False)
    file_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    checksum: Mapped[str] = mapped_column(String(64), nullable=False)
    # Explicit permission for the tracking-code based customer portal.
    is_customer_visible: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # Soft deletion preserves the audit trail (see docs/DATABASE.md).
    deleted_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    deleted_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)

    shipment: Mapped[Shipment] = relationship(lazy="joined")
    uploader: Mapped[User] = relationship(lazy="joined", foreign_keys=[uploaded_by])
