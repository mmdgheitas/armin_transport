"""New transport workspace. Legacy management/reporting APIs are retained."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from werkzeug.datastructures import FileStorage

from app.core import fields
from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.errors import ConflictError, NotFoundError, PermissionDeniedError, ValidationFailedError
from app.core.pagination import paginate
from app.core.permissions import Permission
from app.core.schemas import InputSchema, PaginationQuerySchema
from app.core.transactions import unit_of_work
from app.extensions import db, scoped_db_session
from app.models import Company, Document, Shipment, ShipmentAssignment, TrackingCodeType, User, UserRole
from app.modules.documents.schemas import DocumentSchema
from app.modules.documents.service import IncomingFile
from app.modules.users.schemas import UserCreateSchema, UserSchema

bp = Blueprint("transport", __name__)
COUNTRIES = ("CI", "KZ", "UZ")


class NameSchema(InputSchema):
    name = fields.String(required=True, validate=fields.length(min=1, max=200))


class AccountSchema(InputSchema):
    username = UserCreateSchema().fields["username"]
    password = UserCreateSchema().fields["password"]


class EmployeeSchema(AccountSchema):
    full_name = fields.String(required=True, validate=fields.length(min=1, max=200))
    country = fields.String(required=True, validate=fields.one_of(COUNTRIES))


class ListQuery(PaginationQuerySchema):
    company_id = fields.UUID()
    q = fields.String(strip=False)


class ShipmentInput(InputSchema):
    company_id = fields.UUID(required=True)
    tracking_code = fields.String(required=True, strip=False, validate=fields.length(min=1))
    countries = fields.List(
        fields.String(validate=fields.one_of(COUNTRIES)), required=True, validate=fields.length(min=1)
    )
    upload_limit = fields.Integer(required=True, validate=fields.number_range(min=1))
    truck_count = fields.Integer(required=True, validate=fields.number_range(min=1))
    border_count = fields.Integer(required=True, validate=fields.number_range(min=0))
    employee_ids = fields.List(fields.UUID(), load_default=list)


class CodeInput(InputSchema):
    tracking_code = fields.String(required=True, strip=False, validate=fields.length(min=1))


class UploadForm(InputSchema):
    country = fields.String(validate=fields.one_of(COUNTRIES))


def admin(actor: Actor) -> None:
    if actor.role is not UserRole.SUPER_ADMIN:
        raise PermissionDeniedError()


def company_dict(company: Company) -> dict[str, Any]:
    account = db.session.scalar(
        select(User).where(User.company_id == company.id, User.role == UserRole.CUSTOMER).limit(1)
    )
    return {"id": str(company.id), "name": company.name, "account_username": account.username if account else None}


def shipment_dict(shipment: Shipment, actor: Actor) -> dict[str, Any]:
    users = db.session.scalars(
        select(User)
        .join(ShipmentAssignment, ShipmentAssignment.user_id == User.id)
        .where(ShipmentAssignment.shipment_id == shipment.id)
        .order_by(User.full_name)
    ).all()
    if actor.role is UserRole.EMPLOYEE:
        users = [user for user in users if user.id == actor.user_id]
    return {
        "id": str(shipment.id),
        "company_id": str(shipment.company_id),
        "company_name": shipment.company.name,
        "tracking_code": shipment.tracking_code,
        "countries": shipment.countries,
        "upload_limit": shipment.upload_limit,
        "truck_count": shipment.truck_count,
        "border_count": shipment.border_count,
        "employees": [{"id": str(user.id), "full_name": user.full_name, "country": user.country} for user in users],
    }


def get_shipment(actor: Actor, shipment_id: uuid.UUID) -> Shipment:
    shipment = get_services().shipments.get_entity(actor, shipment_id)
    if not shipment.transport_enabled:
        raise NotFoundError()
    return shipment


@bp.get("/transport/companies")
@endpoint(summary="شرکت‌های ترانسپورت", tag="transport", permissions=(Permission.COMPANY_VIEW,), query=ListQuery)
def companies(actor: Actor, query: dict[str, Any]) -> ApiResult:
    statement = select(Company).order_by(Company.name, Company.id)
    if query.get("q"):
        statement = statement.where(Company.name.contains(query["q"], autoescape=True))
    page = paginate(scoped_db_session(), statement, query["page"], query["per_page"])
    return ApiResult({"items": [company_dict(item) for item in page.items], "pagination": page.meta()})


@bp.post("/transport/companies")
@endpoint(
    summary="ثبت شرکت فقط با نام",
    tag="transport",
    permissions=(Permission.COMPANY_CREATE,),
    body=NameSchema,
    status=201,
)
def create_company(actor: Actor, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    company = Company(name=body["name"], company_code=uuid.uuid4().hex)
    with unit_of_work(scoped_db_session()):
        db.session.add(company)
        db.session.flush()
        get_services().audit.record("COMPANY_CREATED", "company", company.id, actor_id=actor.user_id)
    return ApiResult(company_dict(company), message="شرکت ثبت شد؛ حساب ورود را جداگانه تعریف کنید.")


@bp.post("/transport/companies/<uuid:company_id>/account")
@endpoint(
    summary="ساخت حساب ورود شرکت",
    tag="transport",
    permissions=(Permission.USER_CREATE,),
    body=AccountSchema,
    status=201,
)
def create_account(actor: Actor, company_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    company = get_services().companies.get(company_id)
    if db.session.scalar(select(User.id).where(User.company_id == company_id, User.role == UserRole.CUSTOMER).limit(1)):
        raise ConflictError("این شرکت از قبل حساب ورود دارد.")
    user = get_services().users.create_employee(
        actor, {**body, "full_name": company.name, "role": UserRole.CUSTOMER, "company_id": company_id}
    )
    return ApiResult({"id": str(user.id), "username": user.username}, message="حساب شرکت ساخته شد.")


@bp.get("/transport/employees")
@endpoint(summary="مدیریت کارمندان ترانسپورت", tag="transport", permissions=(Permission.USER_VIEW,), query=ListQuery)
def employees(actor: Actor, query: dict[str, Any]) -> ApiResult:
    admin(actor)
    statement = select(User).where(User.role == UserRole.EMPLOYEE, User.country.in_(COUNTRIES)).order_by(User.full_name)
    if query.get("q"):
        statement = statement.where(User.full_name.contains(query["q"], autoescape=True))
    page = paginate(scoped_db_session(), statement, query["page"], query["per_page"])
    return ApiResult({"items": UserSchema(many=True).dump(page.items), "pagination": page.meta()})


@bp.post("/transport/employees")
@endpoint(
    summary="ثبت کارمند با کشور",
    tag="transport",
    permissions=(Permission.USER_CREATE,),
    body=EmployeeSchema,
    status=201,
)
def create_employee(actor: Actor, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    user = get_services().users.create_employee(actor, {**body, "role": UserRole.EMPLOYEE})
    return ApiResult(UserSchema().dump(user), message="کارمند ثبت شد.")


@bp.get("/transport/shipments")
@endpoint(summary="بارهای قابل دسترسی", tag="transport", permissions=(Permission.SHIPMENT_VIEW,), query=ListQuery)
def shipments(actor: Actor, query: dict[str, Any]) -> ApiResult:
    statement = (
        select(Shipment).where(Shipment.transport_enabled.is_(True)).order_by(Shipment.created_at.desc(), Shipment.id)
    )
    if actor.role is UserRole.CUSTOMER:
        statement = statement.where(Shipment.company_id == actor.company_id)
    elif actor.role is UserRole.EMPLOYEE:
        statement = statement.where(
            Shipment.id.in_(select(ShipmentAssignment.shipment_id).where(ShipmentAssignment.user_id == actor.user_id))
        )
    if query.get("company_id"):
        statement = statement.where(Shipment.company_id == query["company_id"])
    if query.get("q"):
        statement = statement.where(Shipment.tracking_code.contains(query["q"], autoescape=True))
    page = paginate(scoped_db_session(), statement, query["page"], query["per_page"])
    return ApiResult({"items": [shipment_dict(item, actor) for item in page.items], "pagination": page.meta()})


@bp.post("/transport/shipments")
@endpoint(
    summary="ثبت بار با کد دستی و تخصیص کارمند",
    tag="transport",
    permissions=(Permission.SHIPMENT_CREATE,),
    body=ShipmentInput,
    status=201,
)
def create_shipment(actor: Actor, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    company = get_services().companies.get(body["company_id"])
    if not company.is_active:
        raise ValidationFailedError.single("company_id", "شرکت غیرفعال است.")
    ids = set(body["employee_ids"])
    users = db.session.scalars(select(User).where(User.id.in_(ids))).all() if ids else []
    if len(users) != len(ids) or any(
        user.role is not UserRole.EMPLOYEE or not user.is_active or user.country not in body["countries"]
        for user in users
    ):
        raise ValidationFailedError.single("employee_ids", "فقط کارمند فعال از کشورهای انتخاب‌شده قابل تخصیص است.")
    shipment = Shipment(
        company_id=company.id,
        created_by=actor.user_id,
        tracking_code=body["tracking_code"],
        tracking_code_type=TrackingCodeType.MANUAL,
        transport_enabled=True,
        countries=list(dict.fromkeys(body["countries"])),
        upload_limit=body["upload_limit"],
        truck_count=body["truck_count"],
        border_count=body["border_count"],
    )
    try:
        with unit_of_work(scoped_db_session()):
            db.session.add(shipment)
            db.session.flush()
            db.session.add_all([ShipmentAssignment(shipment_id=shipment.id, user_id=user.id) for user in users])
            get_services().audit.record("SHIPMENT_CREATED", "shipment", shipment.id, actor_id=actor.user_id)
    except IntegrityError as exc:
        raise ConflictError("این کد برای بار دیگری ثبت شده است.", code="tracking_code_taken") from exc
    return ApiResult(shipment_dict(shipment, actor), message="بار ثبت شد.")


@bp.get("/transport/shipments/<uuid:shipment_id>")
@endpoint(summary="بار و گرید فایل‌ها به تفکیک کشور و کارمند", tag="transport", permissions=(Permission.SHIPMENT_VIEW,))
def detail(actor: Actor, shipment_id: uuid.UUID) -> ApiResult:
    shipment = get_shipment(actor, shipment_id)
    data = shipment_dict(shipment, actor)
    docs = (
        select(Document)
        .where(Document.shipment_id == shipment.id, Document.deleted_at.is_(None))
        .order_by(Document.created_at, Document.id)
    )
    if actor.role is UserRole.EMPLOYEE:
        docs = docs.where(Document.uploaded_by == actor.user_id)
    documents = db.session.scalars(docs).all()
    groups: list[dict[str, Any]] = []
    for country in shipment.countries:
        people = {user["id"]: user["full_name"] for user in data["employees"] if user["country"] == country}
        for doc in documents:
            if doc.country == country:
                people[str(doc.uploaded_by)] = doc.uploader.full_name
        if actor.role is UserRole.SUPER_ADMIN:
            current_user = db.session.get(User, actor.user_id)
            people[str(actor.user_id)] = current_user.full_name if current_user else actor.username
        for user_id, name in people.items():
            group_docs = [doc for doc in documents if str(doc.uploaded_by) == user_id and doc.country == country]
            groups.append(
                {
                    "user_id": user_id,
                    "full_name": name,
                    "country": country,
                    "limit": shipment.upload_limit,
                    "can_upload": user_id == str(actor.user_id) and actor.role is not UserRole.CUSTOMER,
                    "files": DocumentSchema(many=True).dump(group_docs),
                }
            )
    data["groups"] = groups
    return ApiResult(data)


@bp.patch("/transport/shipments/<uuid:shipment_id>/code")
@endpoint(
    summary="ویرایش دقیق کد دستی بار توسط ادمین",
    tag="transport",
    permissions=(Permission.TRACKING_CODE_CHANGE,),
    body=CodeInput,
)
def change_code(actor: Actor, shipment_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    admin(actor)
    shipment = get_shipment(actor, shipment_id)
    try:
        with unit_of_work(scoped_db_session()):
            shipment.tracking_code = body["tracking_code"]
            get_services().audit.record("TRACKING_CODE_CHANGED", "shipment", shipment.id, actor_id=actor.user_id)
    except IntegrityError as exc:
        raise ConflictError("کد تکراری است.", code="tracking_code_taken") from exc
    return ApiResult(shipment_dict(shipment, actor), message="کد بار تغییر کرد.")


@bp.post("/transport/shipments/<uuid:shipment_id>/files")
@endpoint(
    summary="آپلود در مربع‌های کشور مجاز",
    tag="transport",
    permissions=(Permission.DOCUMENT_UPLOAD,),
    form=UploadForm,
    files_field="files",
    status=201,
)
def upload(actor: Actor, shipment_id: uuid.UUID, form: dict[str, Any], files: list[FileStorage]) -> ApiResult:
    get_shipment(actor, shipment_id)
    documents = get_services().documents.upload(
        actor,
        shipment_id,
        [IncomingFile(file.filename, file.mimetype, file.stream) for file in files],
        country=form.get("country"),
    )
    return ApiResult(DocumentSchema(many=True).dump(documents), message="فایل‌ها بارگذاری شدند.")
