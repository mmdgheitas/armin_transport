"""Recoverable transport CRUD; employee mutation stays restricted to owned files."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from werkzeug.datastructures import FileStorage

from app.core import fields
from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.datetime_utils import utcnow
from app.core.errors import ConflictError, NotFoundError, PermissionDeniedError, ValidationFailedError
from app.core.permissions import Permission
from app.core.schemas import InputSchema
from app.core.transactions import unit_of_work
from app.extensions import db, scoped_db_session
from app.models import Company, Document, Shipment, ShipmentAssignment, User, UserRole
from app.modules.documents.schemas import DocumentSchema
from app.modules.documents.service import IncomingFile
from app.modules.documents.validation import sanitize_filename
from app.modules.transport.routes import (
    COUNTRIES,
    AccountSchema,
    NameSchema,
    ShipmentInput,
    admin,
    bp,
    company_dict,
    get_shipment,
    shipment_dict,
)
from app.modules.users.schemas import UserCreateSchema, UserSchema


class EmployeeEdit(InputSchema):
    full_name = fields.String(validate=fields.length(min=1, max=200))
    username = UserCreateSchema().fields["username"]
    password = UserCreateSchema().fields["password"]
    country = fields.String(validate=fields.one_of(COUNTRIES))

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self.fields["username"].required = False
        self.fields["password"].required = False


class AccountEdit(AccountSchema):
    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        for field in self.fields.values():
            field.required = False


class FileName(InputSchema):
    original_name = fields.String(required=True, strip=False, validate=fields.length(min=1, max=255))


def audit(actor: Actor, action: str, kind: str, entity_id: uuid.UUID) -> None:
    get_services().audit.record(action, kind, entity_id, actor_id=actor.user_id)


def entity(model: Any, entity_id: uuid.UUID, *, deleted: bool = False) -> Any:
    item = db.session.get(model, entity_id)
    if item is None or (item.deleted_at is not None) != deleted:
        raise NotFoundError()
    return item


def company_account(company_id: uuid.UUID) -> User:
    entity(Company, company_id)
    account = db.session.scalar(select(User).where(User.company_id == company_id, User.role == UserRole.CUSTOMER))
    if account is None:
        raise NotFoundError()
    return account


@bp.patch("/transport/companies/<uuid:company_id>")
@endpoint(summary="ویرایش نام شرکت", tag="transport", permissions=(Permission.COMPANY_UPDATE,), body=NameSchema)
def edit_company(actor: Actor, company_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        company = entity(Company, company_id)
        company.name = body["name"]
        audit(actor, "COMPANY_UPDATED", "company", company_id)
    return ApiResult(company_dict(company))


@bp.delete("/transport/companies/<uuid:company_id>")
@endpoint(summary="حذف نرم شرکت و قطع دسترسی", tag="transport", permissions=(Permission.COMPANY_UPDATE,))
def delete_company(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        company = entity(Company, company_id)
        company.deleted_at = utcnow()
        for account in db.session.scalars(
            select(User).where(User.company_id == company_id, User.role == UserRole.CUSTOMER)
        ):
            get_services().auth.invalidate_user_tokens(account)
        audit(actor, "COMPANY_DELETED", "company", company_id)
    return ApiResult(message="شرکت حذف شد؛ اطلاعات و فایل‌ها محفوظ هستند.")


@bp.post("/transport/companies/<uuid:company_id>/restore")
@endpoint(summary="بازیابی شرکت", tag="transport", permissions=(Permission.COMPANY_UPDATE,))
def restore_company(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        company = entity(Company, company_id, deleted=True)
        company.deleted_at = None
        audit(actor, "COMPANY_RESTORED", "company", company_id)
    return ApiResult(company_dict(company))


@bp.patch("/transport/companies/<uuid:company_id>/account")
@endpoint(summary="ویرایش حساب شرکت و رمز", tag="transport", permissions=(Permission.USER_UPDATE,), body=AccountEdit)
def edit_account(actor: Actor, company_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    account = company_account(company_id)
    if account.deleted_at:
        raise ConflictError("ابتدا حساب را بازیابی کنید.")
    return edit_user(actor, account, body)


@bp.delete("/transport/companies/<uuid:company_id>/account")
@endpoint(summary="حذف نرم حساب شرکت", tag="transport", permissions=(Permission.USER_UPDATE,))
def delete_account(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    return delete_user(actor, company_account(company_id))


@bp.post("/transport/companies/<uuid:company_id>/account/restore")
@endpoint(summary="بازیابی حساب شرکت", tag="transport", permissions=(Permission.USER_UPDATE,))
def restore_account(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    account = company_account(company_id)
    if not account.deleted_at:
        raise ConflictError("حساب حذف نشده است.")
    return restore_user(actor, account)


def edit_user(actor: Actor, user: User, body: dict[str, Any]) -> ApiResult:
    if "country" in body and body["country"] != user.country:
        documents = db.session.scalar(
            select(Document.id).where(Document.uploaded_by == user.id, Document.deleted_at.is_(None)).limit(1)
        )
        assignments = db.session.scalars(
            select(Shipment)
            .join(ShipmentAssignment, ShipmentAssignment.shipment_id == Shipment.id)
            .where(ShipmentAssignment.user_id == user.id)
        ).all()
        if documents or any(body["country"] not in shipment.countries for shipment in assignments):
            raise ConflictError("تغییر کشور با فایل‌ها یا بارهای تخصیص‌یافته ناسازگار است.")
    user = get_services().users.update_employee(actor, user.id, body)
    return ApiResult(UserSchema().dump(user))


def delete_user(actor: Actor, user: User) -> ApiResult:
    if user.deleted_at:
        raise NotFoundError()
    with unit_of_work(scoped_db_session()):
        user.deleted_at = utcnow()
        get_services().auth.invalidate_user_tokens(user)
        audit(actor, "USER_DELETED", "user", user.id)
    return ApiResult(message="حساب حذف شد؛ فایل‌ها محفوظ هستند.")


def restore_user(actor: Actor, user: User) -> ApiResult:
    with unit_of_work(scoped_db_session()):
        user.deleted_at = None
        audit(actor, "USER_RESTORED", "user", user.id)
    return ApiResult(UserSchema().dump(user))


@bp.patch("/transport/employees/<uuid:user_id>")
@endpoint(summary="ویرایش کارمند و رمز", tag="transport", permissions=(Permission.USER_UPDATE,), body=EmployeeEdit)
def edit_employee(actor: Actor, user_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    user = entity(User, user_id)
    if user.role is not UserRole.EMPLOYEE:
        raise NotFoundError()
    return edit_user(actor, user, body)


@bp.delete("/transport/employees/<uuid:user_id>")
@endpoint(summary="حذف نرم کارمند", tag="transport", permissions=(Permission.USER_UPDATE,))
def delete_employee(actor: Actor, user_id: uuid.UUID) -> ApiResult:
    admin(actor)
    user = entity(User, user_id)
    if user.role is not UserRole.EMPLOYEE:
        raise NotFoundError()
    return delete_user(actor, user)


@bp.post("/transport/employees/<uuid:user_id>/restore")
@endpoint(summary="بازیابی کارمند", tag="transport", permissions=(Permission.USER_UPDATE,))
def restore_employee(actor: Actor, user_id: uuid.UUID) -> ApiResult:
    admin(actor)
    user = entity(User, user_id, deleted=True)
    if user.role is not UserRole.EMPLOYEE:
        raise NotFoundError()
    return restore_user(actor, user)


@bp.patch("/transport/shipments/<uuid:shipment_id>")
@endpoint(
    summary="ویرایش کامل بار و تخصیص‌ها", tag="transport", permissions=(Permission.SHIPMENT_UPDATE,), body=ShipmentInput
)
def edit_shipment(actor: Actor, shipment_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    try:
        with unit_of_work(scoped_db_session()):
            shipment = get_shipment(actor, shipment_id)
            if body["company_id"] != shipment.company_id:
                raise ConflictError("شرکت بار قابل تغییر نیست.")
            existing_ids = set(
                db.session.scalars(
                    select(ShipmentAssignment.user_id).where(ShipmentAssignment.shipment_id == shipment_id)
                )
            )
            ids = set(body["employee_ids"])
            users = db.session.scalars(select(User).where(User.id.in_(ids))).all() if ids else []
            if len(users) != len(ids) or any(
                user.role is not UserRole.EMPLOYEE
                or (user.id not in existing_ids and (user.deleted_at or not user.is_active))
                or user.country not in body["countries"]
                for user in users
            ):
                raise ValidationFailedError.single("employee_ids", "کارمند فعال از کشورهای انتخاب‌شده لازم است.")
            docs = db.session.scalars(
                select(Document).where(Document.shipment_id == shipment_id, Document.deleted_at.is_(None))
            ).all()
            counts: dict[tuple[uuid.UUID, str | None], int] = {}
            for document in docs:
                if document.country not in body["countries"] or (
                    document.uploader.role is UserRole.EMPLOYEE and document.uploaded_by not in ids
                ):
                    raise ConflictError("حذف کشور یا کارمندی که فایل دارد مجاز نیست.")
                group_key = (document.uploaded_by, document.country)
                counts[group_key] = counts.get(group_key, 0) + 1
            if any(count > body["upload_limit"] for count in counts.values()):
                raise ConflictError("سهمیه نباید از تعداد فایل‌های موجود کمتر باشد.")
            for key in ("tracking_code", "countries", "upload_limit", "truck_count", "border_count"):
                setattr(shipment, key, body[key])
            db.session.execute(delete(ShipmentAssignment).where(ShipmentAssignment.shipment_id == shipment_id))
            db.session.add_all([ShipmentAssignment(shipment_id=shipment_id, user_id=user.id) for user in users])
            db.session.flush()
            audit(actor, "SHIPMENT_UPDATED", "shipment", shipment_id)
    except IntegrityError as exc:
        raise ConflictError("کد بار تکراری است.") from exc
    return ApiResult(shipment_dict(shipment, actor))


@bp.delete("/transport/shipments/<uuid:shipment_id>")
@endpoint(summary="حذف نرم بار", tag="transport", permissions=(Permission.SHIPMENT_UPDATE,))
def delete_shipment(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        shipment = get_shipment(actor, shipment_id)
        shipment.deleted_at = utcnow()
        audit(actor, "SHIPMENT_DELETED", "shipment", shipment_id)
    return ApiResult(message="بار حذف شد؛ فایل‌ها محفوظ هستند.")


@bp.post("/transport/shipments/<uuid:shipment_id>/restore")
@endpoint(summary="بازیابی بار", tag="transport", permissions=(Permission.SHIPMENT_UPDATE,))
def restore_shipment(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        shipment = entity(Shipment, shipment_id, deleted=True)
        if not shipment.transport_enabled or shipment.company.deleted_at:
            raise ConflictError("ابتدا شرکت را بازیابی کنید.")
        shipment.deleted_at = None
        audit(actor, "SHIPMENT_RESTORED", "shipment", shipment_id)
    return ApiResult(shipment_dict(shipment, actor))


def managed_file(actor: Actor, document_id: uuid.UUID, *, deleted: bool = False) -> Document:
    document: Document = entity(Document, document_id, deleted=deleted)
    get_shipment(actor, document.shipment_id)
    if actor.role is UserRole.CUSTOMER:
        raise PermissionDeniedError()
    if actor.role is UserRole.EMPLOYEE and document.uploaded_by != actor.user_id:
        raise NotFoundError()
    return document


@bp.patch("/transport/files/<uuid:document_id>")
@endpoint(summary="تغییر نام فایل", tag="transport", permissions=(Permission.DOCUMENT_UPLOAD,), body=FileName)
def rename_file(actor: Actor, document_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    with unit_of_work(scoped_db_session()):
        document = managed_file(actor, document_id)
        document.original_name = sanitize_filename(body["original_name"])
        audit(actor, "DOCUMENT_RENAMED", "document", document_id)
    return ApiResult(DocumentSchema().dump(document))


@bp.delete("/transport/files/<uuid:document_id>")
@endpoint(summary="حذف نرم فایل خود یا فایل توسط ادمین", tag="transport", permissions=(Permission.DOCUMENT_UPLOAD,))
def delete_file(actor: Actor, document_id: uuid.UUID) -> ApiResult:
    with unit_of_work(scoped_db_session()):
        document = managed_file(actor, document_id)
        document.deleted_at = utcnow()
        document.deleted_by = actor.user_id
        audit(actor, "DOCUMENT_DELETED", "document", document_id)
    return ApiResult(message="فایل حذف شد و توسط ادمین قابل‌بازیابی است.")


@bp.post("/transport/files/<uuid:document_id>/restore")
@endpoint(summary="بازیابی فایل با رعایت سهمیه", tag="transport", permissions=(Permission.DOCUMENT_UPLOAD,))
def restore_file(actor: Actor, document_id: uuid.UUID) -> ApiResult:
    admin(actor)
    with unit_of_work(scoped_db_session()):
        document = managed_file(actor, document_id, deleted=True)
        shipment = get_services().shipments.get_entity(actor, document.shipment_id, for_update=True)
        assigned = db.session.get(ShipmentAssignment, (shipment.id, document.uploaded_by))
        if document.country not in shipment.countries or (
            document.uploader.role is UserRole.EMPLOYEE
            and (not assigned or document.uploader.country != document.country)
        ):
            raise ConflictError("بازیابی با کشور یا تخصیص فعلی ناسازگار است.")
        count = (
            db.session.scalar(
                select(func.count())
                .select_from(Document)
                .where(
                    Document.shipment_id == shipment.id,
                    Document.uploaded_by == document.uploaded_by,
                    Document.country == document.country,
                    Document.deleted_at.is_(None),
                )
            )
            or 0
        )
        if count >= shipment.upload_limit:
            raise ConflictError("سهمیه پر است؛ ابتدا سهمیه را افزایش دهید یا فایلی حذف کنید.")
        document.deleted_at = None
        document.deleted_by = None
        audit(actor, "DOCUMENT_RESTORED", "document", document_id)
    return ApiResult(DocumentSchema().dump(document))


@bp.post("/transport/files/<uuid:document_id>/replace")
@endpoint(
    summary="جایگزینی اتمی فایل در همان مربع",
    tag="transport",
    permissions=(Permission.DOCUMENT_UPLOAD,),
    files_field="files",
)
def replace_file(actor: Actor, document_id: uuid.UUID, files: list[FileStorage]) -> ApiResult:
    managed_file(actor, document_id)
    if len(files) != 1:
        raise ValidationFailedError.single("files", "دقیقاً یک فایل انتخاب کنید.")
    file = files[0]
    document = get_services().documents.replace_content(
        actor, document_id, IncomingFile(file.filename, file.mimetype, file.stream)
    )
    return ApiResult(DocumentSchema().dump(document))


@bp.get("/transport/companies/<uuid:company_id>")
@endpoint(summary="نمایش شرکت و وضعیت حساب", tag="transport", permissions=(Permission.COMPANY_VIEW,))
def read_company(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    return ApiResult(company_dict(entity(Company, company_id)))


@bp.get("/transport/companies/<uuid:company_id>/account")
@endpoint(summary="نمایش حساب شرکت بدون رمز", tag="transport", permissions=(Permission.USER_VIEW,))
def read_account(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    admin(actor)
    return ApiResult(UserSchema().dump(company_account(company_id)))


@bp.get("/transport/employees/<uuid:user_id>")
@endpoint(summary="نمایش کارمند", tag="transport", permissions=(Permission.USER_VIEW,))
def read_employee(actor: Actor, user_id: uuid.UUID) -> ApiResult:
    admin(actor)
    user = entity(User, user_id)
    if user.role is not UserRole.EMPLOYEE:
        raise NotFoundError()
    return ApiResult(UserSchema().dump(user))


@bp.get("/transport/files/<uuid:document_id>")
@endpoint(summary="نمایش مشخصات فایل مجاز", tag="transport", permissions=(Permission.DOCUMENT_VIEW,))
def read_file(actor: Actor, document_id: uuid.UUID) -> ApiResult:
    document = entity(Document, document_id)
    get_shipment(actor, document.shipment_id)
    if actor.role is UserRole.EMPLOYEE and document.uploaded_by != actor.user_id:
        raise NotFoundError()
    return ApiResult(DocumentSchema().dump(document))
