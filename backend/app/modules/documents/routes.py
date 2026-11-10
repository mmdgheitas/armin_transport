"""Document endpoints."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint, Response
from werkzeug.datastructures import FileStorage

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.core.schemas import PaginationQuerySchema
from app.modules.documents.http import download_response
from app.modules.documents.schemas import DocumentSchema, DocumentUpdateSchema, DocumentUploadFormSchema
from app.modules.documents.service import IncomingFile

bp = Blueprint("documents", __name__)
TAG = "documents"
FILES_FIELD = "files"


@bp.get("/shipments/<uuid:shipment_id>/documents")
@endpoint(
    summary="فهرست سندهای محموله",
    tag=TAG,
    permissions=(Permission.DOCUMENT_VIEW,),
    query=PaginationQuerySchema,
    response=DocumentSchema,
    paginated=True,
)
def list_documents(actor: Actor, shipment_id: uuid.UUID, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().documents.list_for_shipment(actor, shipment_id, **query))


@bp.post("/shipments/<uuid:shipment_id>/documents")
@endpoint(
    summary="بارگذاری یک یا چند سند برای محموله",
    description=(
        "درخواست multipart/form-data با فیلد تکرارشوندهٔ files. پسوند، نوع MIME اعلام‌شده و امضای محتوای هر فایل "
        "بررسی می‌شود؛ اگر حتی یک فایل رد شود هیچ فایلی ذخیره نمی‌شود."
    ),
    tag=TAG,
    permissions=(Permission.DOCUMENT_UPLOAD,),
    form=DocumentUploadFormSchema,
    files_field=FILES_FIELD,
    response=DocumentSchema,
    many=True,
    status=201,
    errors=(503,),
)
def upload_documents(actor: Actor, shipment_id: uuid.UUID, form: dict[str, Any], files: list[FileStorage]) -> ApiResult:
    incoming = [IncomingFile(item.filename, item.mimetype, item.stream) for item in files]
    documents = get_services().documents.upload(actor, shipment_id, incoming, form.get("customer_visible"))
    return ApiResult(documents, message="سندها با موفقیت بارگذاری شدند.")


@bp.get("/documents/<uuid:document_id>/download")
@endpoint(
    summary="دانلود سند",
    description="پس از بررسی مجوز و محدودهٔ شرکت، فایل به‌صورت پیوست (attachment) ارسال می‌شود.",
    tag=TAG,
    permissions=(Permission.DOCUMENT_DOWNLOAD,),
    binary=True,
)
def download_document(actor: Actor, document_id: uuid.UUID) -> Response:
    return download_response(get_services().documents.open_for_download(actor, document_id))


@bp.patch("/documents/<uuid:document_id>")
@endpoint(
    summary="تغییر قابلیت مشاهدهٔ سند برای مشتری",
    tag=TAG,
    permissions=(Permission.DOCUMENT_SET_VISIBILITY,),
    body=DocumentUpdateSchema,
    response=DocumentSchema,
)
def update_document(actor: Actor, document_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    document = get_services().documents.set_customer_visibility(actor, document_id, body["is_customer_visible"])
    return ApiResult(document, message="وضعیت نمایش سند به‌روزرسانی شد.")


@bp.delete("/documents/<uuid:document_id>")
@endpoint(
    summary="حذف سند",
    description="حذف نرم همراه با ثبت در ممیزی. به‌صورت پیش‌فرض فقط مدیر مرکزی مجاز است.",
    tag=TAG,
    permissions=(Permission.DOCUMENT_DELETE,),
)
def delete_document(actor: Actor, document_id: uuid.UUID) -> ApiResult:
    get_services().documents.delete(actor, document_id)
    return ApiResult(message="سند حذف شد.")
