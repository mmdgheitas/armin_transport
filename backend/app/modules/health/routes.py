"""Health endpoints for load balancers and orchestrators."""

from __future__ import annotations

import logging

from flask import Blueprint, Response
from sqlalchemy import text

from app.core.api import ApiResult, endpoint, get_services
from app.core.datetime_utils import utcnow
from app.core.responses import error_response
from app.extensions import db
from app.modules.health.schemas import HealthSchema, ReadinessSchema

bp = Blueprint("health", __name__)
logger = logging.getLogger(__name__)
TAG = "health"


@bp.get("/health")
@endpoint(
    summary="بررسی زنده بودن سرویس (liveness)",
    description="بدون دسترسی به پایگاه داده پاسخ می‌دهد.",
    tag=TAG,
    auth="public",
    response=HealthSchema,
)
def health() -> ApiResult:
    settings = get_services().settings
    return ApiResult({"status": "ok", "version": settings.app_version, "time": utcnow()})


def _database_ready() -> bool:
    try:
        db.session.execute(text("SELECT 1"))
    except Exception:
        logger.exception("Readiness probe: database check failed")
        db.session.rollback()
        return False
    return True


@bp.get("/health/ready")
@endpoint(
    summary="بررسی آمادگی سرویس (readiness)",
    description="اتصال پایگاه داده و قابل‌نوشتن بودن محل ذخیرهٔ سندها را بررسی می‌کند؛ در صورت خطا 503 برمی‌گرداند.",
    tag=TAG,
    auth="public",
    response=ReadinessSchema,
    errors=(503,),
)
def ready() -> ApiResult | Response:
    checks = {
        "database": "ok" if _database_ready() else "unavailable",
        "storage": "ok" if get_services().storage.is_writable() else "unavailable",
    }
    if any(state != "ok" for state in checks.values()):
        return error_response("سرویس آماده نیست.", 503, "not_ready", {"checks": checks})
    return ApiResult({"status": "ready", "checks": checks})
