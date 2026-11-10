"""Dashboard endpoint."""

from __future__ import annotations

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.modules.dashboard.schemas import DashboardSummarySchema

bp = Blueprint("dashboard", __name__)


@bp.get("/dashboard/summary")
@endpoint(
    summary="خلاصهٔ داشبورد",
    description="شمارنده‌ها در محدودهٔ دسترسی کاربر محاسبه می‌شوند (کل سامانه برای مدیر مرکزی، شرکت خود برای کارمند).",
    tag="dashboard",
    permissions=(Permission.DASHBOARD_VIEW,),
    response=DashboardSummarySchema,
)
def dashboard_summary(actor: Actor) -> ApiResult:
    return ApiResult(get_services().dashboard.summary(actor))
