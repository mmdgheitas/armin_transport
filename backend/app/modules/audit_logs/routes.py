"""Audit log endpoints (read-only, SUPER_ADMIN)."""

from __future__ import annotations

from typing import Any

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.modules.audit_logs.schemas import AuditLogQuerySchema, AuditLogSchema

bp = Blueprint("audit_logs", __name__)


@bp.get("/audit-logs")
@endpoint(
    summary="فهرست رویدادهای ممیزی",
    tag="audit-logs",
    permissions=(Permission.AUDIT_LOG_VIEW,),
    query=AuditLogQuerySchema,
    response=AuditLogSchema,
    paginated=True,
)
def list_audit_logs(actor: Actor, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().audit.search(**query))
