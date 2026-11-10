"""Company (tenant) model."""

from __future__ import annotations

from sqlalchemy import Boolean, String, Text, UniqueConstraint, true
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import TABLE_OPTIONS, Model, TimestampMixin, UUIDPrimaryKeyMixin


class Company(UUIDPrimaryKeyMixin, TimestampMixin, Model):
    __tablename__ = "companies"
    __table_args__ = (UniqueConstraint("company_code"), TABLE_OPTIONS)

    name: Mapped[str] = mapped_column(String(200), nullable=False)
    company_code: Mapped[str] = mapped_column(String(50), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(30))
    address: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default=true())
