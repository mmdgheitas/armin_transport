"""Role and permission model.

Authorization decisions are expressed as explicit permissions instead of role
comparisons scattered through the code base. The role → permission mapping lives
here; a few employee permissions are configurable business rules (see Settings).
"""

from __future__ import annotations

import enum

from app.config import Settings
from app.models.enums import UserRole


class Permission(enum.StrEnum):
    # Scope: access data of every company (tenant) instead of only the actor's own.
    GLOBAL_SCOPE = "scope:global"

    DASHBOARD_VIEW = "dashboard:view"

    COMPANY_VIEW = "company:view"
    COMPANY_CREATE = "company:create"
    COMPANY_UPDATE = "company:update"
    COMPANY_SET_ACTIVE = "company:set_active"

    USER_VIEW = "user:view"
    USER_CREATE = "user:create"
    USER_UPDATE = "user:update"
    USER_SET_ACTIVE = "user:set_active"
    USER_RESET_PASSWORD = "user:reset_password"  # noqa: S105 - permission name, not a secret

    SHIPMENT_VIEW = "shipment:view"
    SHIPMENT_CREATE = "shipment:create"
    SHIPMENT_UPDATE = "shipment:update"
    SHIPMENT_ARCHIVE = "shipment:archive"
    SHIPMENT_UNARCHIVE = "shipment:unarchive"

    TRACKING_CODE_GENERATE = "tracking_code:generate"
    TRACKING_CODE_MANUAL = "tracking_code:manual"
    TRACKING_CODE_CHANGE = "tracking_code:change"
    TRACKING_HISTORY_VIEW = "tracking_code:history"

    DOCUMENT_VIEW = "document:view"
    DOCUMENT_UPLOAD = "document:upload"
    DOCUMENT_DOWNLOAD = "document:download"
    DOCUMENT_SET_VISIBILITY = "document:set_visibility"
    DOCUMENT_DELETE = "document:delete"

    PRODUCT_FIELD_VIEW = "product_field:view"
    PRODUCT_FIELD_MANAGE = "product_field:manage"
    PRODUCT_VALUE_VIEW = "product_value:view"
    PRODUCT_VALUE_EDIT = "product_value:edit"

    CUSTOMER_SESSION_REVOKE = "customer_session:revoke"

    AUDIT_LOG_VIEW = "audit_log:view"


_EMPLOYEE_BASE: frozenset[Permission] = frozenset(
    {
        Permission.DASHBOARD_VIEW,
        Permission.SHIPMENT_VIEW,
        Permission.SHIPMENT_CREATE,
        Permission.SHIPMENT_UPDATE,
        Permission.TRACKING_CODE_GENERATE,
        Permission.TRACKING_HISTORY_VIEW,
        Permission.DOCUMENT_VIEW,
        Permission.DOCUMENT_UPLOAD,
        Permission.DOCUMENT_DOWNLOAD,
        Permission.DOCUMENT_SET_VISIBILITY,
        Permission.PRODUCT_FIELD_VIEW,
        Permission.PRODUCT_VALUE_VIEW,
        Permission.PRODUCT_VALUE_EDIT,
        Permission.CUSTOMER_SESSION_REVOKE,
    }
)


def permissions_for_role(role: UserRole, settings: Settings) -> frozenset[Permission]:
    """Return the effective permission set of ``role`` under the current settings."""
    if role is UserRole.SUPER_ADMIN:
        return frozenset(Permission)

    permissions = set(_EMPLOYEE_BASE)
    if settings.employee_can_use_manual_tracking_code:
        permissions.add(Permission.TRACKING_CODE_MANUAL)
    if settings.employee_can_change_tracking_code:
        permissions.add(Permission.TRACKING_CODE_CHANGE)
    if settings.employee_can_archive_shipments:
        permissions.add(Permission.SHIPMENT_ARCHIVE)
    if settings.employee_can_delete_documents:
        permissions.add(Permission.DOCUMENT_DELETE)
    return frozenset(permissions)
