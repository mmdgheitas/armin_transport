"""Product field definitions (SUPER_ADMIN) and per-shipment values."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, scoped_session

from app.core.actor import Actor
from app.core.errors import ConflictError, NotFoundError, ValidationFailedError
from app.core.pagination import Page
from app.core.permissions import Permission
from app.core.transactions import unit_of_work
from app.models import ProductFieldDefinition, Shipment, ShipmentProductValue
from app.modules.audit_logs.service import AuditService
from app.modules.product_fields.repository import ProductFieldRepository
from app.modules.product_fields.validation import (
    FieldValidationError,
    display_value,
    is_empty_value,
    normalize_options,
    normalize_rules,
    validate_value,
)

# Changing any of these alters how values are validated or interpreted → new version.
_VERSIONED_ATTRIBUTES = ("label", "is_required", "validation_rules", "options")
_PLAIN_ATTRIBUTES = ("display_order", "is_customer_visible")


@dataclass(frozen=True)
class ProductValueItem:
    """A field definition together with the value stored for one shipment (if any)."""

    field: ProductFieldDefinition
    value: Any
    display_value: Any
    field_version: int | None
    is_outdated: bool
    updated_at: datetime | None


@dataclass(frozen=True)
class ProductValues:
    items: list[ProductValueItem]


def _snapshot(definition: ProductFieldDefinition) -> dict[str, Any]:
    return {
        "field_key": definition.field_key,
        "label": definition.label,
        "data_type": definition.data_type.value,
        "is_required": definition.is_required,
        "is_active": definition.is_active,
        "is_customer_visible": definition.is_customer_visible,
        "display_order": definition.display_order,
        "validation_rules": definition.validation_rules,
        "options": definition.options,
        "version": definition.version,
    }


class ProductFieldService:
    """Manages the global field definitions."""

    def __init__(self, session: scoped_session[Session], audit: AuditService, fields: ProductFieldRepository) -> None:
        self._session = session
        self._audit = audit
        self._fields = fields

    @staticmethod
    def _key_conflict() -> ConflictError:
        return ConflictError(
            "فیلد فعال دیگری با همین کلید وجود دارد.",
            code="field_key_taken",
            details={"fields": {"field_key": ["فیلد فعال دیگری با این کلید وجود دارد."]}},
        )

    @staticmethod
    def _normalize(
        data_type: Any, rules: Any, options: Any
    ) -> tuple[dict[str, Any] | None, list[dict[str, str]] | None]:
        try:
            normalized_options = normalize_options(data_type, options)
        except FieldValidationError as exc:
            raise ValidationFailedError.single("options", exc.message) from exc
        try:
            normalized_rules = normalize_rules(data_type, rules)
        except FieldValidationError as exc:
            raise ValidationFailedError.single("validation_rules", exc.message) from exc
        return normalized_rules, normalized_options

    def list_fields(
        self, actor: Actor, *, page: int, per_page: int, include_inactive: bool, q: str | None = None
    ) -> Page[ProductFieldDefinition]:
        # Only managers may see retired definitions; everyone else gets the active set.
        include = include_inactive and actor.can(Permission.PRODUCT_FIELD_MANAGE)
        return self._fields.search(page=page, per_page=per_page, include_inactive=include, q=q)

    def get(self, actor: Actor, definition_id: uuid.UUID) -> ProductFieldDefinition:
        definition = self._fields.get(definition_id)
        if definition is None or (not definition.is_active and not actor.can(Permission.PRODUCT_FIELD_MANAGE)):
            raise NotFoundError("فیلد موردنظر یافت نشد.")
        return definition

    def create(self, actor: Actor, data: dict[str, Any]) -> ProductFieldDefinition:
        rules, options = self._normalize(data["data_type"], data.get("validation_rules"), data.get("options"))
        is_active = data.get("is_active", True)
        if is_active and self._fields.active_key_exists(data["field_key"]):
            raise self._key_conflict()
        definition = ProductFieldDefinition(
            field_key=data["field_key"],
            label=data["label"],
            data_type=data["data_type"],
            is_required=data.get("is_required", False),
            is_active=is_active,
            is_customer_visible=data.get("is_customer_visible", False),
            display_order=data.get("display_order", 0),
            validation_rules=rules,
            options=options,
            version=1,
        )
        try:
            with unit_of_work(self._session):
                self._session.add(definition)
                self._session.flush()
                self._audit.record(
                    "PRODUCT_FIELD_CREATED",
                    "product_field_definition",
                    definition.id,
                    actor_id=actor.user_id,
                    metadata={"definition": _snapshot(definition)},
                )
        except IntegrityError as exc:
            raise self._key_conflict() from exc
        return definition

    @staticmethod
    def _reject_immutable_changes(definition: ProductFieldDefinition, data: dict[str, Any]) -> None:
        """``field_key`` and ``data_type`` never change, so stored values keep their meaning."""
        errors: dict[str, list[str]] = {}
        if "field_key" in data and data["field_key"] != definition.field_key:
            errors["field_key"] = ["کلید فیلد قابل تغییر نیست؛ فیلد جدیدی تعریف کنید."]
        if "data_type" in data and data["data_type"] != definition.data_type.value:
            errors["data_type"] = ["نوع دادهٔ فیلد قابل تغییر نیست؛ این فیلد را غیرفعال و فیلد جدیدی تعریف کنید."]
        if errors:
            raise ValidationFailedError(errors, code="immutable_field")

    def _collect_updates(self, definition: ProductFieldDefinition, data: dict[str, Any]) -> dict[str, Any]:
        updates: dict[str, Any] = {
            attribute: data[attribute]
            for attribute in ("label", "is_required", *_PLAIN_ATTRIBUTES)
            if attribute in data
        }
        if "validation_rules" in data or "options" in data:
            updates["validation_rules"], updates["options"] = self._normalize(
                definition.data_type,
                data.get("validation_rules", definition.validation_rules),
                data.get("options", definition.options),
            )
        return updates

    def update(self, actor: Actor, definition_id: uuid.UUID, data: dict[str, Any]) -> ProductFieldDefinition:
        definition = self._fields.get(definition_id)
        if definition is None:
            raise NotFoundError("فیلد موردنظر یافت نشد.")
        self._reject_immutable_changes(definition, data)
        updates = self._collect_updates(definition, data)

        activating = data.get("is_active") is True and not definition.is_active
        if activating and self._fields.active_key_exists(definition.field_key, exclude_id=definition.id):
            raise self._key_conflict()

        before = _snapshot(definition)
        try:
            with unit_of_work(self._session):
                changed = {name for name, value in updates.items() if getattr(definition, name) != value}
                for name in changed:
                    setattr(definition, name, updates[name])
                if "is_active" in data:
                    definition.is_active = data["is_active"]
                if changed.intersection(_VERSIONED_ATTRIBUTES):
                    definition.version += 1
                after = _snapshot(definition)
                if after != before:
                    self._audit.record(
                        "PRODUCT_FIELD_UPDATED",
                        "product_field_definition",
                        definition.id,
                        actor_id=actor.user_id,
                        metadata={"before": before, "after": after},
                    )
        except IntegrityError as exc:
            raise self._key_conflict() from exc
        return definition


class ProductValueManager:
    """Reads and writes the dynamic values of a shipment (no transaction management)."""

    def __init__(self, session: scoped_session[Session], fields: ProductFieldRepository) -> None:
        self._session = session
        self._fields = fields

    def read(self, shipment: Shipment) -> ProductValues:
        """All active fields (with or without a value) plus retired fields that still hold a value."""
        stored = {value.field_definition_id: value for value in self._fields.values_for_shipment(shipment.id)}
        definitions = {definition.id: definition for definition in self._fields.active_definitions()}
        for value in stored.values():
            definitions.setdefault(value.field_definition_id, value.field_definition)

        items = []
        ordered = sorted(definitions.values(), key=lambda d: (not d.is_active, d.display_order, d.label, str(d.id)))
        for definition in ordered:
            row = stored.get(definition.id)
            items.append(
                ProductValueItem(
                    field=definition,
                    value=row.value if row else None,
                    display_value=display_value(definition, row.value) if row else None,
                    field_version=row.field_version if row else None,
                    is_outdated=bool(row and row.field_version < definition.version),
                    updated_at=row.updated_at if row else None,
                )
            )
        return ProductValues(items=items)

    def customer_visible(self, shipment: Shipment) -> list[ProductValueItem]:
        """Values of active fields that the administrator approved for customers."""
        return [
            item
            for item in self.read(shipment).items
            if item.field.is_active and item.field.is_customer_visible and item.value is not None
        ]

    @staticmethod
    def _validate_submission(
        active: dict[str, ProductFieldDefinition], submitted: dict[str, Any]
    ) -> tuple[dict[uuid.UUID, Any], set[uuid.UUID]]:
        """Return ``(validated values, cleared field ids)`` or raise with every field error."""
        errors: dict[str, list[str]] = {
            f"values.{key}": ["این فیلد تعریف نشده یا غیرفعال است."] for key in submitted if key not in active
        }
        validated: dict[uuid.UUID, Any] = {}
        cleared: set[uuid.UUID] = set()
        for key, definition in active.items():
            raw = submitted.get(key)
            if is_empty_value(raw):
                if definition.is_required:
                    errors[f"values.{key}"] = ["وارد کردن این فیلد الزامی است."]
                else:
                    cleared.add(definition.id)
                continue
            try:
                validated[definition.id] = validate_value(definition, raw)
            except FieldValidationError as exc:
                errors[f"values.{key}"] = [exc.message]
        if errors:
            raise ValidationFailedError(errors)
        return validated, cleared

    def apply(self, shipment: Shipment, submitted: dict[str, Any]) -> dict[str, Any]:
        """Validate and store the complete value set for the active fields of ``shipment``.

        Unknown or inactive keys are rejected. Values of retired fields are left
        untouched, so historical data survives definition changes. Returns a summary
        of the changes for auditing. Nothing is written when any value is invalid.
        """
        active = {definition.field_key: definition for definition in self._fields.active_definitions()}
        validated, cleared = self._validate_submission(active, submitted)

        existing = {value.field_definition_id: value for value in self._fields.values_for_shipment(shipment.id)}
        by_id = {definition.id: definition for definition in active.values()}
        changed: list[str] = []
        removed: list[str] = []
        for definition_id, value in validated.items():
            definition = by_id[definition_id]
            row = existing.get(definition_id)
            if row is None:
                self._session.add(
                    ShipmentProductValue(
                        shipment_id=shipment.id,
                        field_definition_id=definition_id,
                        field_version=definition.version,
                        value=value,
                    )
                )
            elif row.value != value or row.field_version != definition.version:
                row.value = value
                row.field_version = definition.version
            else:
                continue
            changed.append(definition.field_key)
        for definition_id in cleared.intersection(existing):
            self._session.delete(existing[definition_id])
            removed.append(by_id[definition_id].field_key)
        self._session.flush()
        return {"changed": sorted(changed), "removed": sorted(removed)}
