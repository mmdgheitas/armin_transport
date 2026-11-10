"""Model base class, shared mixins and table options."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import Enum, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.datetime_utils import utcnow
from app.core.db_types import UTCDateTime
from app.extensions import Base, db

if TYPE_CHECKING:
    Model = Base
else:
    Model = db.Model

# Every table uses InnoDB with utf8mb4 so foreign keys, transactions and Persian text work.
TABLE_OPTIONS: dict[str, Any] = {
    "mysql_engine": "InnoDB",
    "mysql_charset": "utf8mb4",
    "mysql_collate": "utf8mb4_unicode_ci",
}


def enum_column(enum_class: type[enum.Enum], name: str) -> Enum:
    """Native ENUM column type that stores the enum *values* and validates input."""
    return Enum(
        enum_class,
        name=name,
        native_enum=True,
        validate_strings=True,
        values_callable=lambda members: [member.value for member in members],
    )


class UUIDPrimaryKeyMixin:
    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4, sort_order=-100)


class CreatedAtMixin:
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False, default=utcnow, sort_order=900)


class TimestampMixin(CreatedAtMixin):
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime(), nullable=False, default=utcnow, onupdate=utcnow, sort_order=901
    )
