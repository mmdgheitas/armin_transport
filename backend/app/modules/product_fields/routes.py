"""Product field definition endpoints."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.modules.product_fields.schemas import (
    ProductFieldCreateSchema,
    ProductFieldQuerySchema,
    ProductFieldSchema,
    ProductFieldUpdateSchema,
)

bp = Blueprint("product_fields", __name__)
TAG = "product-fields"


@bp.get("/product-fields")
@endpoint(
    summary="فهرست فیلدهای پویای محصول",
    description="کارمندان فقط فیلدهای فعال را می‌بینند؛ مدیر مرکزی با include_inactive=true همه را می‌بیند.",
    tag=TAG,
    permissions=(Permission.PRODUCT_FIELD_VIEW,),
    query=ProductFieldQuerySchema,
    response=ProductFieldSchema,
    paginated=True,
)
def list_product_fields(actor: Actor, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().product_fields.list_fields(actor, **query))


@bp.post("/product-fields")
@endpoint(
    summary="تعریف فیلد پویای جدید",
    tag=TAG,
    permissions=(Permission.PRODUCT_FIELD_MANAGE,),
    body=ProductFieldCreateSchema,
    response=ProductFieldSchema,
    status=201,
)
def create_product_field(actor: Actor, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().product_fields.create(actor, body), message="فیلد با موفقیت تعریف شد.")


@bp.get("/product-fields/<uuid:field_id>")
@endpoint(
    summary="جزئیات فیلد پویا",
    tag=TAG,
    permissions=(Permission.PRODUCT_FIELD_VIEW,),
    response=ProductFieldSchema,
)
def get_product_field(actor: Actor, field_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().product_fields.get(actor, field_id))


@bp.patch("/product-fields/<uuid:field_id>")
@endpoint(
    summary="ویرایش، فعال‌سازی یا غیرفعال‌سازی فیلد پویا",
    description="کلید و نوع داده تغییرناپذیرند. تغییر برچسب، الزامی بودن، قواعد یا گزینه‌ها نسخهٔ فیلد را افزایش می‌دهد.",
    tag=TAG,
    permissions=(Permission.PRODUCT_FIELD_MANAGE,),
    body=ProductFieldUpdateSchema,
    response=ProductFieldSchema,
)
def update_product_field(actor: Actor, field_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().product_fields.update(actor, field_id, body), message="فیلد به‌روزرسانی شد.")
