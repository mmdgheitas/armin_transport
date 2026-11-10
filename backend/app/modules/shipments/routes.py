"""Shipment endpoints."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.core.schemas import PaginationQuerySchema
from app.modules.product_fields.schemas import ProductValuesSchema, ProductValuesUpdateSchema
from app.modules.shipments.schemas import (
    RevokedSessionsSchema,
    ShipmentCreateSchema,
    ShipmentQuerySchema,
    ShipmentSchema,
    ShipmentUpdateSchema,
    TrackingCodeChangeSchema,
    TrackingHistorySchema,
)

bp = Blueprint("shipments", __name__)
TAG = "shipments"


@bp.get("/shipments")
@endpoint(
    summary="فهرست محموله‌ها",
    description="کارمند فقط محموله‌های شرکت خودش را می‌بیند؛ مدیر مرکزی می‌تواند با company_id فیلتر کند.",
    tag=TAG,
    permissions=(Permission.SHIPMENT_VIEW,),
    query=ShipmentQuerySchema,
    response=ShipmentSchema,
    paginated=True,
)
def list_shipments(actor: Actor, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().shipments.list_shipments(actor, **query))


@bp.post("/shipments")
@endpoint(
    summary="ثبت محموله",
    description=(
        "اگر tracking_code ارسال نشود کد امن خودکار تولید می‌شود. شرکتِ کارمند از حساب کاربری او گرفته می‌شود؛ "
        "مدیر مرکزی باید company_id را مشخص کند."
    ),
    tag=TAG,
    permissions=(Permission.SHIPMENT_CREATE,),
    body=ShipmentCreateSchema,
    response=ShipmentSchema,
    status=201,
    errors=(503,),
)
def create_shipment(actor: Actor, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().shipments.create(actor, body), message="محموله با موفقیت ثبت شد.")


@bp.get("/shipments/<uuid:shipment_id>")
@endpoint(summary="جزئیات محموله", tag=TAG, permissions=(Permission.SHIPMENT_VIEW,), response=ShipmentSchema)
def get_shipment(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().shipments.get(actor, shipment_id))


@bp.patch("/shipments/<uuid:shipment_id>")
@endpoint(
    summary="ویرایش محموله",
    description="توضیحات، کد رهگیری (دستی) و مقادیر فیلدهای پویا را در یک تراکنش به‌روزرسانی می‌کند.",
    tag=TAG,
    permissions=(Permission.SHIPMENT_UPDATE,),
    body=ShipmentUpdateSchema,
    response=ShipmentSchema,
)
def update_shipment(actor: Actor, shipment_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().shipments.update(actor, shipment_id, body), message="محموله به‌روزرسانی شد.")


@bp.post("/shipments/<uuid:shipment_id>/archive")
@endpoint(
    summary="بایگانی محموله",
    tag=TAG,
    permissions=(Permission.SHIPMENT_ARCHIVE,),
    response=ShipmentSchema,
)
def archive_shipment(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().shipments.archive(actor, shipment_id), message="محموله بایگانی شد.")


@bp.post("/shipments/<uuid:shipment_id>/unarchive")
@endpoint(
    summary="خارج کردن محموله از بایگانی",
    tag=TAG,
    permissions=(Permission.SHIPMENT_UNARCHIVE,),
    response=ShipmentSchema,
)
def unarchive_shipment(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().shipments.unarchive(actor, shipment_id), message="محموله دوباره فعال شد.")


@bp.post("/shipments/<uuid:shipment_id>/tracking-code")
@endpoint(
    summary="تغییر کد رهگیری",
    description="کد قبلی بلافاصله بی‌اعتبار می‌شود، در تاریخچه ثبت می‌گردد و نشست‌های مشتری باطل می‌شوند.",
    tag=TAG,
    permissions=(Permission.TRACKING_CODE_CHANGE,),
    body=TrackingCodeChangeSchema,
    response=ShipmentSchema,
    errors=(503,),
)
def change_tracking_code(actor: Actor, shipment_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    shipment = get_services().shipments.change_tracking_code(actor, shipment_id, body.get("tracking_code"))
    return ApiResult(shipment, message="کد رهگیری تغییر کرد.")


@bp.get("/shipments/<uuid:shipment_id>/tracking-history")
@endpoint(
    summary="تاریخچهٔ کدهای رهگیری محموله",
    tag=TAG,
    permissions=(Permission.TRACKING_HISTORY_VIEW,),
    query=PaginationQuerySchema,
    response=TrackingHistorySchema,
    paginated=True,
)
def tracking_history(actor: Actor, shipment_id: uuid.UUID, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().shipments.tracking_history(actor, shipment_id, **query))


@bp.get("/shipments/<uuid:shipment_id>/product-values")
@endpoint(
    summary="مقادیر فیلدهای پویای محموله",
    tag="product-fields",
    permissions=(Permission.PRODUCT_VALUE_VIEW,),
    response=ProductValuesSchema,
)
def get_product_values(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().shipments.get_product_values(actor, shipment_id))


@bp.put("/shipments/<uuid:shipment_id>/product-values")
@endpoint(
    summary="ثبت مقادیر فیلدهای پویای محموله",
    description="مجموعهٔ کامل مقادیر فیلدهای فعال را جایگزین می‌کند؛ اعتبارسنجی بر اساس تعریف فعلی فیلدها است.",
    tag="product-fields",
    permissions=(Permission.PRODUCT_VALUE_EDIT,),
    body=ProductValuesUpdateSchema,
    response=ProductValuesSchema,
)
def set_product_values(actor: Actor, shipment_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    values = get_services().shipments.set_product_values(actor, shipment_id, body["values"])
    return ApiResult(values, message="مشخصات محصول ذخیره شد.")


@bp.post("/shipments/<uuid:shipment_id>/customer-sessions/revoke")
@endpoint(
    summary="ابطال نشست‌های فعال مشتری برای محموله",
    tag=TAG,
    permissions=(Permission.CUSTOMER_SESSION_REVOKE,),
    response=RevokedSessionsSchema,
)
def revoke_customer_sessions(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    revoked = get_services().shipments.revoke_customer_sessions(actor, shipment_id)
    return ApiResult({"revoked": revoked}, message="نشست‌های مشتری باطل شدند.")
