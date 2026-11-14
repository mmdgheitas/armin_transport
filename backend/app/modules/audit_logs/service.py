"""Audit logging service."""

from __future__ import annotations

import uuid
from collections.abc import Mapping
from datetime import datetime
from typing import Any

from flask import g, has_request_context, request
from sqlalchemy import select
from sqlalchemy.orm import Session, scoped_session

from app.core.pagination import Page, paginate
from app.models import AuditLog, Company, Document, Shipment, User, UserRole

_SENSITIVE_KEY_FRAGMENTS = ("password", "token", "secret", "authorization")
_MAX_STRING_LENGTH = 500


def _sanitize(value: Any) -> Any:
    """Make metadata JSON-safe and drop anything that looks like a credential."""
    if isinstance(value, Mapping):
        return {
            str(key): _sanitize(item)
            for key, item in value.items()
            if not any(fragment in str(key).lower() for fragment in _SENSITIVE_KEY_FRAGMENTS)
        }
    if isinstance(value, list | tuple | set | frozenset):
        return [_sanitize(item) for item in value]
    if isinstance(value, str):
        return value[:_MAX_STRING_LENGTH]
    if value is None or isinstance(value, bool | int | float):
        return value
    return str(value)[:_MAX_STRING_LENGTH]


# Only successful business changes appear in the company work history.
COMPANY_WORK_ACTIONS = frozenset(
    {
        "COMPANY_CREATED",
        "COMPANY_UPDATED",
        "COMPANY_ACTIVATED",
        "COMPANY_DEACTIVATED",
        "SHIPMENT_CREATED",
        "SHIPMENT_UPDATED",
        "SHIPMENT_ARCHIVED",
        "SHIPMENT_UNARCHIVED",
        "TRACKING_CODE_CHANGED",
        "PRODUCT_VALUES_UPDATED",
        "DOCUMENT_UPLOADED",
        "DOCUMENT_DELETED",
        "DOCUMENT_VISIBILITY_CHANGED",
        "CUSTOMER_SESSIONS_REVOKED",
    }
)


class AuditService:
    """Writes audit entries; entries are never updated or deleted by the application."""

    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def record(
        self,
        action: str,
        entity_type: str,
        entity_id: uuid.UUID | str | None = None,
        *,
        actor_id: uuid.UUID | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> AuditLog:
        """Add an audit entry to the current transaction (committed by the caller)."""
        company_id = None
        if entity_id is not None:
            try:
                key = uuid.UUID(str(entity_id))
            except ValueError:
                key = None
            if key is not None:
                with self._session.no_autoflush:
                    if entity_type == "company":
                        company = self._session.get(Company, key)
                        company_id = company.id if company else None
                    elif entity_type == "shipment":
                        shipment = self._session.get(Shipment, key)
                        company_id = shipment.company_id if shipment else None
                    elif entity_type == "document":
                        document = self._session.get(Document, key)
                        company_id = document.shipment.company_id if document else None
                    elif entity_type == "user":
                        user = self._session.get(User, key)
                        company_id = user.company_id if user and user.role is UserRole.CUSTOMER else None
        entry = AuditLog(
            company_id=company_id,
            user_id=actor_id,
            action=action,
            entity_type=entity_type,
            entity_id=str(entity_id) if entity_id is not None else None,
            meta=_sanitize(metadata) if metadata else None,
            ip_address=request.remote_addr if has_request_context() else None,
            request_id=g.get("request_id") if has_request_context() else None,
        )
        self._session.add(entry)
        return entry

    def record_isolated(
        self,
        action: str,
        entity_type: str,
        entity_id: uuid.UUID | str | None = None,
        *,
        actor_id: uuid.UUID | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> None:
        """Persist an entry in its own transaction (failure paths: denied access, failed login)."""
        self._session.rollback()
        try:
            self.record(action, entity_type, entity_id, actor_id=actor_id, metadata=metadata)
            self._session.commit()
        except Exception:
            self._session.rollback()
            raise

    def search(
        self,
        *,
        page: int,
        per_page: int,
        company_id: uuid.UUID | None = None,
        work_only: bool = False,
        action: str | None = None,
        entity_type: str | None = None,
        entity_id: str | None = None,
        user_id: uuid.UUID | None = None,
        created_from: datetime | None = None,
        created_to: datetime | None = None,
    ) -> Page[AuditLog]:
        statement = select(AuditLog)
        if company_id is not None:
            statement = statement.where(AuditLog.company_id == company_id)
        if work_only:
            statement = statement.where(AuditLog.action.in_(COMPANY_WORK_ACTIONS))
        if action:
            statement = statement.where(AuditLog.action == action)
        if entity_type:
            statement = statement.where(AuditLog.entity_type == entity_type)
        if entity_id:
            statement = statement.where(AuditLog.entity_id == entity_id)
        if user_id:
            statement = statement.where(AuditLog.user_id == user_id)
        if created_from:
            statement = statement.where(AuditLog.created_at >= created_from)
        if created_to:
            statement = statement.where(AuditLog.created_at <= created_to)
        statement = statement.order_by(AuditLog.created_at.desc(), AuditLog.id.desc())
        return paginate(self._session, statement, page, per_page)
