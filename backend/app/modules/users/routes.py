"""User management endpoints (SUPER_ADMIN only)."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.modules.users.schemas import (
    PasswordResetSchema,
    UserCreateSchema,
    UserQuerySchema,
    UserSchema,
    UserUpdateSchema,
)

bp = Blueprint("users", __name__)
TAG = "users"


@bp.get("/users")
@endpoint(
    summary="فهرست کاربران",
    tag=TAG,
    permissions=(Permission.USER_VIEW,),
    query=UserQuerySchema,
    response=UserSchema,
    paginated=True,
)
def list_users(actor: Actor, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().users.list_users(**query))


@bp.post("/users")
@endpoint(
    summary="ایجاد کارمند",
    tag=TAG,
    permissions=(Permission.USER_CREATE,),
    body=UserCreateSchema,
    response=UserSchema,
    status=201,
)
def create_user(actor: Actor, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().users.create_employee(actor, body), message="کارمند با موفقیت ایجاد شد.")


@bp.get("/users/<uuid:user_id>")
@endpoint(summary="جزئیات کاربر", tag=TAG, permissions=(Permission.USER_VIEW,), response=UserSchema)
def get_user(actor: Actor, user_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().users.get(user_id))


@bp.patch("/users/<uuid:user_id>")
@endpoint(
    summary="ویرایش، فعال‌سازی یا غیرفعال‌سازی کارمند",
    tag=TAG,
    permissions=(Permission.USER_UPDATE,),
    body=UserUpdateSchema,
    response=UserSchema,
)
def update_user(actor: Actor, user_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    return ApiResult(
        get_services().users.update_employee(actor, user_id, body), message="اطلاعات کارمند به‌روزرسانی شد."
    )


@bp.post("/users/<uuid:user_id>/reset-password")
@endpoint(
    summary="بازنشانی رمز عبور کارمند توسط مدیر",
    tag=TAG,
    permissions=(Permission.USER_RESET_PASSWORD,),
    body=PasswordResetSchema,
    response=UserSchema,
)
def reset_user_password(actor: Actor, user_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    user = get_services().users.reset_password(actor, user_id, body["new_password"])
    return ApiResult(user, message="رمز عبور کارمند بازنشانی شد و نشست‌های قبلی او باطل شدند.")
