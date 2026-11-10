"""Customer portal endpoints (no user account; access by tracking code)."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint, Response

from app.core.api import ApiResult, client_ip, endpoint, get_services
from app.core.schemas import PaginationQuerySchema
from app.modules.customer_access.schemas import (
    CustomerAccessGrantSchema,
    CustomerDocumentSchema,
    CustomerLookupSchema,
    CustomerShipmentSchema,
)
from app.modules.documents.http import download_response

bp = Blueprint("customer_access", __name__)
TAG = "customer"


@bp.post("/customer/lookup")
@endpoint(
    summary="جست‌وجوی محموله با کد رهگیری",
    description=(
        "در صورت معتبر بودن کد، توکن دسترسی کوتاه‌مدتی برمی‌گرداند که فقط به همان محموله محدود است. "
        "پاسخ خطا برای همهٔ حالت‌های ناموفق یکسان است و این عملیات محدودیت نرخ دارد."
    ),
    tag=TAG,
    auth="public",
    body=CustomerLookupSchema,
    response=CustomerAccessGrantSchema,
    errors=(404,),
)
def lookup(body: dict[str, Any]) -> ApiResult:
    grant = get_services().customer_access.lookup(body["tracking_code"], client_ip())
    return ApiResult(grant, message="محموله یافت شد.")


@bp.get("/customer/access/<string:token>/shipment")
@endpoint(
    summary="خلاصهٔ محموله برای مشتری",
    tag=TAG,
    auth="customer_token",
    response=CustomerShipmentSchema,
)
def customer_shipment(token: str) -> ApiResult:
    return ApiResult(get_services().customer_access.shipment_summary(token, client_ip()))


@bp.get("/customer/access/<string:token>/documents")
@endpoint(
    summary="فهرست سندهای قابل مشاهده برای مشتری",
    tag=TAG,
    auth="customer_token",
    query=PaginationQuerySchema,
    response=CustomerDocumentSchema,
    paginated=True,
)
def customer_documents(token: str, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().customer_access.list_documents(token, client_ip(), **query))


@bp.get("/customer/access/<string:token>/documents/<uuid:document_id>/download")
@endpoint(
    summary="دانلود سند توسط مشتری",
    description="سند باید متعلق به محمولهٔ همین نشست و برای مشتری قابل مشاهده باشد.",
    tag=TAG,
    auth="customer_token",
    binary=True,
)
def customer_download(token: str, document_id: uuid.UUID) -> Response:
    return download_response(get_services().customer_access.open_document(token, client_ip(), document_id))


@bp.post("/customer/access/<string:token>/revoke")
@endpoint(summary="پایان دادن به نشست مشتری", tag=TAG, auth="customer_token")
def customer_revoke(token: str) -> ApiResult:
    get_services().customer_access.revoke(token, client_ip())
    return ApiResult(message="نشست شما پایان یافت.")
