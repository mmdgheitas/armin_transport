"""Shipment application service: tenant scoping, tracking codes, archive, product values."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, scoped_session

from app.config import Settings
from app.core.actor import Actor
from app.core.datetime_utils import utcnow
from app.core.errors import (
    ConflictError,
    NotFoundError,
    PermissionDeniedError,
    ServiceUnavailableError,
    ValidationFailedError,
)
from app.core.pagination import Page
from app.core.permissions import Permission
from app.core.transactions import unit_of_work
from app.models import Company, Shipment, ShipmentStatus, TrackingCodeHistory, TrackingCodeType
from app.modules.audit_logs.service import AuditService
from app.modules.companies.repository import CompanyRepository
from app.modules.customer_access.repository import CustomerSessionRepository
from app.modules.product_fields.service import ProductValueManager, ProductValues
from app.modules.shipments.repository import ShipmentRepository
from app.modules.shipments.tracking_codes import (
    InvalidTrackingCodeError,
    TrackingCodeGenerator,
    normalize_tracking_code,
    validate_tracking_code,
)


@dataclass(frozen=True)
class ShipmentView:
    """A shipment plus derived read-only attributes for serialization."""

    shipment: Shipment
    document_count: int

    def __getattr__(self, name: str) -> Any:
        return getattr(self.shipment, name)


class ShipmentService:
    def __init__(
        self,
        session: scoped_session[Session],
        settings: Settings,
        audit: AuditService,
        shipments: ShipmentRepository,
        companies: CompanyRepository,
        product_values: ProductValueManager,
        customer_sessions: CustomerSessionRepository,
        code_generator: TrackingCodeGenerator,
    ) -> None:
        self._session = session
        self._settings = settings
        self._audit = audit
        self._shipments = shipments
        self._companies = companies
        self._product_values = product_values
        self._customer_sessions = customer_sessions
        self._generator = code_generator

    # ------------------------------------------------------------------ scoping helpers
    @staticmethod
    def scope_company_id(actor: Actor) -> uuid.UUID | None:
        """Company filter for ``actor``: ``None`` only for principals with global scope."""
        if actor.has_global_scope:
            return None
        if actor.company_id is None:
            raise PermissionDeniedError()
        return actor.company_id

    def _resolve_list_scope(self, actor: Actor, requested_company_id: uuid.UUID | None) -> uuid.UUID | None:
        scope = self.scope_company_id(actor)
        if scope is None:
            return requested_company_id
        if requested_company_id is not None and requested_company_id != scope:
            raise PermissionDeniedError("دسترسی به اطلاعات شرکت دیگر مجاز نیست.", code="company_scope_violation")
        return scope

    def get_entity(self, actor: Actor, shipment_id: uuid.UUID, *, for_update: bool = False) -> Shipment:
        """Load a shipment inside the actor's tenant scope.

        A shipment of another company is indistinguishable from a missing one (404).
        """
        shipment = self._shipments.get_scoped(shipment_id, self.scope_company_id(actor), for_update=for_update)
        if shipment is None:
            raise NotFoundError("محمولهٔ موردنظر یافت نشد.")
        return shipment

    @staticmethod
    def ensure_writable(shipment: Shipment) -> None:
        if shipment.status is ShipmentStatus.ARCHIVED:
            raise ConflictError("این محموله بایگانی شده است و قابل تغییر نیست.", code="shipment_archived")

    def _view(self, shipment: Shipment) -> ShipmentView:
        counts = self._shipments.document_counts([shipment.id])
        return ShipmentView(shipment=shipment, document_count=counts.get(shipment.id, 0))

    # ------------------------------------------------------------------ tracking codes
    @staticmethod
    def _code_taken() -> ConflictError:
        return ConflictError(
            "این کد رهگیری قبلاً استفاده شده است.",
            code="tracking_code_taken",
            details={"fields": {"tracking_code": ["این کد رهگیری قبلاً استفاده شده است و قابل استفادهٔ دوباره نیست."]}},
        )

    def _prepare_manual_code(self, actor: Actor, raw_code: str) -> str:
        if not actor.can(Permission.TRACKING_CODE_MANUAL):
            raise PermissionDeniedError(
                "ثبت کد رهگیری دستی برای شما مجاز نیست؛ از کد خودکار استفاده کنید.",
                code="manual_tracking_code_not_allowed",
                details={"required_permissions": [Permission.TRACKING_CODE_MANUAL.value]},
            )
        try:
            code = validate_tracking_code(normalize_tracking_code(raw_code), self._settings.tracking_code_min_length)
        except InvalidTrackingCodeError as exc:
            raise ValidationFailedError.single("tracking_code", exc.message, code="invalid_tracking_code") from exc
        if self._shipments.code_ever_used(code):
            raise self._code_taken()
        return code

    def _next_free_auto_code(self) -> str:
        """Generate a code that is not in use; bounded retries guard against collisions."""
        for _ in range(self._settings.tracking_code_max_attempts):
            code = self._generator.generate()
            if not self._shipments.code_ever_used(code):
                return code
        raise ServiceUnavailableError(
            "تولید کد رهگیری یکتا ممکن نشد. لطفاً دوباره تلاش کنید.", code="tracking_code_generation_failed"
        )

    def _assign_code(
        self, actor: Actor, shipment: Shipment, manual_code: str | None, old_code: str | None = None
    ) -> None:
        """Set a new code on ``shipment`` and record history, atomically within the caller's transaction.

        For generated codes a unique-constraint collision (a concurrent request won
        the race) is retried inside a SAVEPOINT a bounded number of times.
        """
        attempts = 1 if manual_code is not None else self._settings.tracking_code_max_attempts
        for _ in range(attempts):
            code = manual_code if manual_code is not None else self._next_free_auto_code()
            try:
                with self._session.begin_nested():
                    shipment.tracking_code = code
                    shipment.tracking_code_type = (
                        TrackingCodeType.MANUAL if manual_code is not None else TrackingCodeType.AUTO
                    )
                    self._session.add(shipment)
                    self._session.flush()
                    self._session.add(
                        TrackingCodeHistory(
                            shipment_id=shipment.id, old_code=old_code, new_code=code, changed_by=actor.user_id
                        )
                    )
                    self._session.flush()
                return
            except IntegrityError as exc:
                if not self._shipments.code_ever_used(code):
                    raise  # not a tracking-code collision
                if manual_code is not None:
                    raise self._code_taken() from exc
        raise ServiceUnavailableError(
            "تولید کد رهگیری یکتا ممکن نشد. لطفاً دوباره تلاش کنید.", code="tracking_code_generation_failed"
        )

    # ------------------------------------------------------------------ queries
    def list_shipments(
        self, actor: Actor, *, company_id: uuid.UUID | None = None, **filters: Any
    ) -> Page[ShipmentView]:
        if filters.get("tracking_code"):
            filters["tracking_code"] = normalize_tracking_code(filters["tracking_code"])
        page = self._shipments.search(company_id=self._resolve_list_scope(actor, company_id), **filters)
        counts = self._shipments.document_counts([shipment.id for shipment in page.items])
        views = [ShipmentView(shipment=item, document_count=counts.get(item.id, 0)) for item in page.items]
        return Page(items=views, total=page.total, page=page.page, per_page=page.per_page)

    def get(self, actor: Actor, shipment_id: uuid.UUID) -> ShipmentView:
        return self._view(self.get_entity(actor, shipment_id))

    def tracking_history(
        self, actor: Actor, shipment_id: uuid.UUID, page: int, per_page: int
    ) -> Page[TrackingCodeHistory]:
        shipment = self.get_entity(actor, shipment_id)
        return self._shipments.history(shipment.id, page, per_page)

    def get_product_values(self, actor: Actor, shipment_id: uuid.UUID) -> ProductValues:
        return self._product_values.read(self.get_entity(actor, shipment_id))

    # ------------------------------------------------------------------ commands
    def _resolve_target_company(self, actor: Actor, requested_company_id: uuid.UUID | None) -> Company:
        scope = self.scope_company_id(actor)
        if scope is None:
            if requested_company_id is None:
                raise ValidationFailedError.single("company_id", "انتخاب شرکت برای ثبت محموله الزامی است.")
            company_id = requested_company_id
        else:
            # The tenant always comes from the authenticated user, never from the request body.
            if requested_company_id is not None and requested_company_id != scope:
                raise PermissionDeniedError("ثبت محموله برای شرکت دیگر مجاز نیست.", code="company_scope_violation")
            company_id = scope
        company = self._companies.get(company_id)
        if company is None:
            raise ValidationFailedError.single("company_id", "شرکت انتخاب‌شده وجود ندارد.")
        if not company.is_active:
            raise ValidationFailedError.single("company_id", "شرکت انتخاب‌شده غیرفعال است.", code="company_inactive")
        return company

    def create(self, actor: Actor, data: dict[str, Any]) -> ShipmentView:
        company = self._resolve_target_company(actor, data.get("company_id"))
        raw_code = data.get("tracking_code")
        if raw_code is None:
            actor.require(Permission.TRACKING_CODE_GENERATE)
        manual_code = self._prepare_manual_code(actor, raw_code) if raw_code is not None else None

        shipment = Shipment(
            company_id=company.id,
            created_by=actor.user_id,
            description=data.get("description") or None,
            status=ShipmentStatus.ACTIVE,
        )
        with unit_of_work(self._session):
            self._assign_code(actor, shipment, manual_code)
            product_summary = None
            if data.get("product_values") is not None:
                product_summary = self._product_values.apply(shipment, data["product_values"])
            self._audit.record(
                "SHIPMENT_CREATED",
                "shipment",
                shipment.id,
                actor_id=actor.user_id,
                metadata={
                    "company_id": str(company.id),
                    "tracking_code": shipment.tracking_code,
                    "tracking_code_type": shipment.tracking_code_type.value,
                    "product_fields": product_summary,
                },
            )
        return self._view(shipment)

    def update(self, actor: Actor, shipment_id: uuid.UUID, data: dict[str, Any]) -> ShipmentView:
        if data.get("product_values") is not None:
            actor.require(Permission.PRODUCT_VALUE_EDIT)

        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id, for_update=True)
            self.ensure_writable(shipment)
            changes: dict[str, Any] = {}
            if "description" in data:
                description = data["description"] or None
                if description != shipment.description:
                    changes["description"] = True
                    shipment.description = description
            if data.get("tracking_code") is not None:
                changed = self._change_code(actor, shipment, data["tracking_code"], allow_same=True)
                if changed is not None:
                    changes["tracking_code"] = changed
            if data.get("product_values") is not None:
                summary = self._product_values.apply(shipment, data["product_values"])
                if summary["changed"] or summary["removed"]:
                    changes["product_fields"] = summary
            if changes:
                shipment.updated_at = utcnow()
                self._audit.record(
                    "SHIPMENT_UPDATED", "shipment", shipment.id, actor_id=actor.user_id, metadata={"changes": changes}
                )
        return self._view(shipment)

    def _change_code(
        self, actor: Actor, shipment: Shipment, raw_code: str | None, *, allow_same: bool = False
    ) -> dict[str, Any] | None:
        """Replace the tracking code. The old code stops working immediately and is never reused."""
        old_code = shipment.tracking_code
        if raw_code is not None and normalize_tracking_code(raw_code) == old_code:
            if allow_same:
                return None
            raise ValidationFailedError.single("tracking_code", "کد رهگیری جدید با کد فعلی یکسان است.")
        actor.require(Permission.TRACKING_CODE_CHANGE)
        manual_code = self._prepare_manual_code(actor, raw_code) if raw_code is not None else None
        if manual_code is None:
            actor.require(Permission.TRACKING_CODE_GENERATE)

        self._assign_code(actor, shipment, manual_code, old_code)
        revoked = self._customer_sessions.revoke_for_shipment(shipment.id, utcnow())
        change = {
            "old_code": old_code,
            "new_code": shipment.tracking_code,
            "tracking_code_type": shipment.tracking_code_type.value,
            "revoked_customer_sessions": revoked,
        }
        self._audit.record("TRACKING_CODE_CHANGED", "shipment", shipment.id, actor_id=actor.user_id, metadata=change)
        return change

    def change_tracking_code(self, actor: Actor, shipment_id: uuid.UUID, raw_code: str | None) -> ShipmentView:
        """Assign ``raw_code`` (manual) or, when it is ``None``, a freshly generated code."""
        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id, for_update=True)
            self.ensure_writable(shipment)
            self._change_code(actor, shipment, raw_code)
            shipment.updated_at = utcnow()
        return self._view(shipment)

    def archive(self, actor: Actor, shipment_id: uuid.UUID) -> ShipmentView:
        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id, for_update=True)
            if shipment.status is ShipmentStatus.ARCHIVED:
                raise ConflictError("این محموله قبلاً بایگانی شده است.", code="shipment_archived")
            shipment.status = ShipmentStatus.ARCHIVED
            revoked = 0
            if not self._settings.customer_allow_archived_shipments:
                revoked = self._customer_sessions.revoke_for_shipment(shipment.id, utcnow())
            self._audit.record(
                "SHIPMENT_ARCHIVED",
                "shipment",
                shipment.id,
                actor_id=actor.user_id,
                metadata={"revoked_customer_sessions": revoked},
            )
        return self._view(shipment)

    def unarchive(self, actor: Actor, shipment_id: uuid.UUID) -> ShipmentView:
        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id, for_update=True)
            if shipment.status is ShipmentStatus.ACTIVE:
                raise ConflictError("این محموله بایگانی نشده است.", code="shipment_not_archived")
            shipment.status = ShipmentStatus.ACTIVE
            self._audit.record("SHIPMENT_UNARCHIVED", "shipment", shipment.id, actor_id=actor.user_id)
        return self._view(shipment)

    def set_product_values(self, actor: Actor, shipment_id: uuid.UUID, values: dict[str, Any]) -> ProductValues:
        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id, for_update=True)
            self.ensure_writable(shipment)
            summary = self._product_values.apply(shipment, values)
            if summary["changed"] or summary["removed"]:
                shipment.updated_at = utcnow()
                self._audit.record(
                    "PRODUCT_VALUES_UPDATED", "shipment", shipment.id, actor_id=actor.user_id, metadata=summary
                )
        return self._product_values.read(shipment)

    def revoke_customer_sessions(self, actor: Actor, shipment_id: uuid.UUID) -> int:
        with unit_of_work(self._session):
            shipment = self.get_entity(actor, shipment_id)
            revoked = self._customer_sessions.revoke_for_shipment(shipment.id, utcnow())
            self._audit.record(
                "CUSTOMER_SESSIONS_REVOKED",
                "shipment",
                shipment.id,
                actor_id=actor.user_id,
                metadata={"revoked_customer_sessions": revoked},
            )
        return revoked
