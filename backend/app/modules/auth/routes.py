"""Authentication endpoints."""

from __future__ import annotations

from typing import Any

from flask import Blueprint, request

from app.core.actor import Actor
from app.core.api import ApiResult, client_ip, endpoint, get_services
from app.modules.auth.schemas import (
    AuthSessionSchema,
    ChangePasswordSchema,
    LoginSchema,
    ProfileSchema,
    RefreshSchema,
)
from app.modules.auth.service import ClientContext

bp = Blueprint("auth", __name__)
TAG = "auth"


def _client_context() -> ClientContext:
    return ClientContext(ip=client_ip(), user_agent=request.headers.get("User-Agent"))


@bp.post("/auth/login")
@endpoint(
    summary="ورود با نام کاربری و رمز عبور",
    description="در صورت موفقیت، توکن دسترسی (JWT) و توکن نوسازی برمی‌گرداند. این عملیات محدودیت نرخ دارد.",
    tag=TAG,
    auth="public",
    body=LoginSchema,
    response=AuthSessionSchema,
    errors=(401, 403),
)
def login(body: dict[str, Any]) -> ApiResult:
    session = get_services().auth.login(body["username"], body["password"], _client_context())
    return ApiResult(session, message="ورود با موفقیت انجام شد.")


@bp.post("/auth/refresh")
@endpoint(
    summary="نوسازی توکن دسترسی (چرخش توکن نوسازی)",
    description="توکن نوسازی یک‌بارمصرف است؛ استفادهٔ دوباره از توکن قبلی کل نشست را باطل می‌کند.",
    tag=TAG,
    auth="public",
    body=RefreshSchema,
    response=AuthSessionSchema,
    errors=(401,),
)
def refresh(body: dict[str, Any]) -> ApiResult:
    session = get_services().auth.refresh(body["refresh_token"], _client_context())
    return ApiResult(session, message="نشست نوسازی شد.")


@bp.get("/auth/me")
@endpoint(summary="نمایهٔ کاربر جاری، مجوزها و تنظیمات کلاینت", tag=TAG, response=ProfileSchema)
def me(actor: Actor) -> ApiResult:
    return ApiResult(get_services().auth.profile(actor))


@bp.post("/auth/logout")
@endpoint(summary="خروج و ابطال نشست جاری", tag=TAG)
def logout(actor: Actor) -> ApiResult:
    get_services().auth.logout(actor)
    return ApiResult(message="خروج با موفقیت انجام شد.")


@bp.post("/auth/change-password")
@endpoint(
    summary="تغییر رمز عبور کاربر جاری",
    description="همهٔ نشست‌های قبلی کاربر باطل می‌شوند و توکن‌های تازه برای همین کلاینت صادر می‌شود.",
    tag=TAG,
    body=ChangePasswordSchema,
    response=AuthSessionSchema,
)
def change_password(actor: Actor, body: dict[str, Any]) -> ApiResult:
    session = get_services().auth.change_password(
        actor, body["current_password"], body["new_password"], _client_context()
    )
    return ApiResult(session, message="رمز عبور با موفقیت تغییر کرد.")
