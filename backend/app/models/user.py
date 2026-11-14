"""User model (central administrators and company employees)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, ForeignKey, Integer, String, UniqueConstraint, true
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db_types import UTCDateTime
from app.models.base import TABLE_OPTIONS, Model, TimestampMixin, UUIDPrimaryKeyMixin, enum_column
from app.models.company import Company
from app.models.enums import UserRole


class User(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("username"),
        # A SUPER_ADMIN is global (no company); an EMPLOYEE always belongs to a company.
        CheckConstraint(
            "(role = 'SUPER_ADMIN' AND company_id IS NULL) OR role = 'EMPLOYEE' OR (role = 'CUSTOMER' AND company_id IS NOT NULL)",
            name="role_company_consistency",
        ),
        TABLE_OPTIONS,
    )

    company_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("companies.id", ondelete="RESTRICT"), index=True)
    username: Mapped[str] = mapped_column(String(100), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    full_name: Mapped[str] = mapped_column(String(200), nullable=False)
    role: Mapped[UserRole] = mapped_column(enum_column(UserRole, "user_role"), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default=true())
    # Incremented to invalidate every issued token (password reset, deactivation).
    token_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    last_login_at: Mapped[datetime | None] = mapped_column(UTCDateTime())

    company: Mapped[Company | None] = relationship(lazy="joined")
