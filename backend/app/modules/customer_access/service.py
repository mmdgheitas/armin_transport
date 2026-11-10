"""Customer portal application service.

A customer proves knowledge of a tracking code and receives a short-lived opaque
token bound to exactly one shipment. Only the SHA-256 hash of the token is
stored. Every failure looks the same to the caller, so the API cannot be used to
tell apart unknown, archived, retired or otherwise unavailable tracking codes.
"""

from __future__ import annotations

import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy.orm import Session, scoped_session

from app.config import Settings
from app.core.client_settings import TRACKING_CODE_MAX_LENGTH, TRACKING_CODE_PATTERN
from app.core.datetime_utils import utcnow
from app.core.errors import CustomerSessionInvalidError, NotFoundError
from app.core.pagination import Page
from app.core.rate_limit import RateLimiter
from app.core.security import generate_opaque_token, hash_token
from app.core.transactions import unit_of_work
from app.models import CustomerAccessSession, Document, Shipment, ShipmentStatus
from app.models.enums import ProductFieldType
from app.modules.audit_logs.service import AuditService
from app.modules.customer_access.repository import CustomerSessionRepository
from app.modules.documents.repository import DocumentRepository
from app.modules.documents.service import DocumentContent, DocumentService
from app.modules.product_fields.service import ProductValueManager
from app.modules.shipments.repository import ShipmentRepository
from app.modules.shipments.tracking_codes import normalize_tracking_code

LOOKUP_IP_SCOPE = "customer_lookup_ip"
LOOKUP_FAILURE_SCOPE = "customer_lookup_fail_ip"
ACCESS_IP_SCOPE = "customer_access_ip"

_UNKNOWN_CLIENT = "unknown"
_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
_CODE_PATTERN = re.compile(TRACKING_CODE_PATTERN)
_EXPIRED_SESSION_RETENTION = timedelta(days=30)


@dataclass(frozen=True)
class CustomerAccessGrant:
    access_token: str
    expires_at: datetime
    expires_in: int


@dataclass(frozen=True)
class CustomerProductDetail:
    label: str
    data_type: ProductFieldType
    value: Any


@dataclass(frozen=True)
class CustomerShipmentSummary:
    """The customer-safe view of a shipment: no internal identifiers of any kind."""

    tracking_code: str
    status: ShipmentStatus
    company_name: str | None
    description: str | None
    registered_at: datetime
    document_count: int
    product_details: list[CustomerProductDetail]
    session_expires_at: datetime


class CustomerAccessService:
    def __init__(
        self,
        session: scoped_session[Session],
        settings: Settings,
        rate_limiter: RateLimiter,
        audit: AuditService,
        sessions: CustomerSessionRepository,
        shipments: ShipmentRepository,
        documents: DocumentRepository,
        document_service: DocumentService,
        product_values: ProductValueManager,
    ) -> None:
        self._session = session
        self._settings = settings
        self._limiter = rate_limiter
        self._audit = audit
        self._sessions = sessions
        self._shipments = shipments
        self._documents = documents
        self._document_service = document_service
        self._product_values = product_values

    # ------------------------------------------------------------------ helpers
    @staticmethod
    def _lookup_failed() -> NotFoundError:
        return NotFoundError(
            "محموله‌ای با این کد رهگیری یافت نشد. کد را بررسی کنید و دوباره تلاش کنید.",
            code="tracking_code_not_found",
        )

    def _is_customer_accessible(self, shipment: Shipment) -> bool:
        if not shipment.company.is_active:
            return False
        if shipment.status is ShipmentStatus.ARCHIVED:
            return self._settings.customer_allow_archived_shipments
        return True

    def _find_shipment(self, code: str) -> Shipment | None:
        if len(code) > TRACKING_CODE_MAX_LENGTH or _CODE_PATTERN.fullmatch(code) is None:
            return None
        shipment = self._shipments.get_by_tracking_code(code)
        if shipment is None or not self._is_customer_accessible(shipment):
            return None
        return shipment

    def _resolve_session(self, raw_token: str, client_ip: str | None) -> CustomerAccessSession:
        """Validate a customer token and return its session (same error for every failure)."""
        self._limiter.enforce(
            ACCESS_IP_SCOPE, self._settings.rate_limit_customer_access_ip, client_ip or _UNKNOWN_CLIENT
        )
        if _TOKEN_PATTERN.fullmatch(raw_token) is None:
            raise CustomerSessionInvalidError()
        access_session = self._sessions.get_by_token_hash(hash_token(raw_token))
        now = utcnow()
        if access_session is None or access_session.revoked_at is not None or access_session.expires_at <= now:
            raise CustomerSessionInvalidError()
        shipment = access_session.shipment
        # A changed tracking code retires every session that was opened with the old code.
        if shipment.tracking_code != access_session.tracking_code or not self._is_customer_accessible(shipment):
            raise CustomerSessionInvalidError()
        access_session.last_used_at = now
        return access_session

    # ------------------------------------------------------------------ use cases
    def lookup(self, raw_code: str, client_ip: str | None) -> CustomerAccessGrant:
        key = client_ip or _UNKNOWN_CLIENT
        self._limiter.enforce(LOOKUP_IP_SCOPE, self._settings.rate_limit_customer_lookup_ip, key)
        failure_rule = self._settings.rate_limit_customer_lookup_failures_ip
        self._limiter.ensure_available(LOOKUP_FAILURE_SCOPE, failure_rule, key)

        code = normalize_tracking_code(raw_code)
        shipment = self._find_shipment(code)
        if shipment is None:
            self._limiter.hit(LOOKUP_FAILURE_SCOPE, failure_rule, key)
            # Only a fingerprint is stored: failed guesses may be near misses of real codes.
            fingerprint = hashlib.sha256(code.encode("utf-8")).hexdigest()[:16]
            self._audit.record_isolated(
                "CUSTOMER_LOOKUP_FAILED", "shipment", None, metadata={"code_fingerprint": fingerprint}
            )
            raise self._lookup_failed()

        raw_token = generate_opaque_token()
        ttl = self._settings.customer_session_ttl_seconds
        with unit_of_work(self._session):
            now = utcnow()
            expires_at = now + timedelta(seconds=ttl)
            self._sessions.add(
                CustomerAccessSession(
                    shipment_id=shipment.id,
                    token_hash=hash_token(raw_token),
                    tracking_code=shipment.tracking_code,
                    expires_at=expires_at,
                )
            )
            self._audit.record("CUSTOMER_LOOKUP_SUCCESS", "shipment", shipment.id)
        return CustomerAccessGrant(access_token=raw_token, expires_at=expires_at, expires_in=ttl)

    def shipment_summary(self, raw_token: str, client_ip: str | None) -> CustomerShipmentSummary:
        with unit_of_work(self._session):
            access_session = self._resolve_session(raw_token, client_ip)
            shipment = access_session.shipment
            details = [
                CustomerProductDetail(label=item.field.label, data_type=item.field.data_type, value=item.display_value)
                for item in self._product_values.customer_visible(shipment)
            ]
            return CustomerShipmentSummary(
                tracking_code=shipment.tracking_code,
                status=shipment.status,
                company_name=shipment.company.name if self._settings.customer_show_company_name else None,
                description=shipment.description if self._settings.customer_show_description else None,
                registered_at=shipment.created_at,
                document_count=self._documents.count_customer_visible(shipment.id),
                product_details=details,
                session_expires_at=access_session.expires_at,
            )

    def list_documents(self, raw_token: str, client_ip: str | None, page: int, per_page: int) -> Page[Document]:
        with unit_of_work(self._session):
            access_session = self._resolve_session(raw_token, client_ip)
            return self._documents.list_for_shipment(
                access_session.shipment_id, page, per_page, customer_visible_only=True
            )

    def open_document(self, raw_token: str, client_ip: str | None, document_id: uuid.UUID) -> DocumentContent:
        """Authorize a single download: the document must belong to the session's shipment."""
        access_session = self._resolve_session(raw_token, client_ip)
        document = self._documents.get_customer_visible(document_id, access_session.shipment_id)
        if document is None:
            self._session.rollback()
            raise NotFoundError("سند موردنظر یافت نشد.", code="document_not_found")
        content = self._document_service.open_content(document)
        try:
            with unit_of_work(self._session):
                self._audit.record(
                    "CUSTOMER_DOCUMENT_DOWNLOADED",
                    "document",
                    document.id,
                    metadata={"shipment_id": str(document.shipment_id)},
                )
        except BaseException:
            content.stream.close()
            raise
        return content

    def revoke(self, raw_token: str, client_ip: str | None) -> None:
        """Let the customer end the session explicitly (e.g. on a shared computer)."""
        with unit_of_work(self._session):
            access_session = self._resolve_session(raw_token, client_ip)
            access_session.revoked_at = utcnow()

    def purge_expired(self) -> int:
        """Delete sessions that expired long ago (maintenance task)."""
        with unit_of_work(self._session):
            return self._sessions.purge_older_than(utcnow() - _EXPIRED_SESSION_RETENTION)
