"""Company (tenant) model."""

from __future__ import annotations

from typing import TYPE_CHECKING

from sqlalchemy import Boolean, String, Text, UniqueConstraint, select, true
from sqlalchemy.orm import Mapped, mapped_column, object_session

from app.models.base import TABLE_OPTIONS, Model, TimestampMixin, UUIDPrimaryKeyMixin

if TYPE_CHECKING:
    from app.models.audit_log import AuditLog


class Company(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    __tablename__ = "companies"
    __table_args__ = (UniqueConstraint("company_code"), TABLE_OPTIONS)

    name: Mapped[str] = mapped_column(String(200), nullable=False)
    company_code: Mapped[str] = mapped_column(String(50), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(30))
    address: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default=true())

    @property
    def last_activity(self) -> AuditLog | None:
        # Lazy imports avoid the Company → User → AuditLog model cycle.
        from app.models.audit_log import AuditLog  # noqa: PLC0415
        from app.modules.audit_logs.service import COMPANY_WORK_ACTIONS  # noqa: PLC0415

        session = object_session(self)
        if session is None:
            return None
        return session.scalar(
            select(AuditLog)
            .where(AuditLog.company_id == self.id, AuditLog.action.in_(COMPANY_WORK_ACTIONS))
            .order_by(AuditLog.created_at.desc(), AuditLog.id.desc())
            .limit(1)
        )
