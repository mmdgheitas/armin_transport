"""Company endpoints (SUPER_ADMIN only)."""

from __future__ import annotations

import uuid
from typing import Any

from flask import Blueprint

from app.core.actor import Actor
from app.core.api import ApiResult, endpoint, get_services
from app.core.permissions import Permission
from app.modules.companies.schemas import (
    CompanyCreateSchema,
    CompanyDetailSchema,
    CompanyQuerySchema,
    CompanySchema,
    CompanyUpdateSchema,
)

bp = Blueprint("companies", __name__)
TAG = "companies"


@bp.get("/companies")
@endpoint(
    summary="فهرست شرکت‌ها",
    tag=TAG,
    permissions=(Permission.COMPANY_VIEW,),
    query=CompanyQuerySchema,
    response=CompanySchema,
    paginated=True,
)
def list_companies(actor: Actor, query: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().companies.list_companies(**query))


@bp.post("/companies")
@endpoint(
    summary="ایجاد شرکت",
    tag=TAG,
    permissions=(Permission.COMPANY_CREATE,),
    body=CompanyCreateSchema,
    response=CompanySchema,
    status=201,
)
def create_company(actor: Actor, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().companies.create(actor, body), message="شرکت با موفقیت ایجاد شد.")


@bp.get("/companies/<uuid:company_id>")
@endpoint(
    summary="جزئیات شرکت",
    tag=TAG,
    permissions=(Permission.COMPANY_VIEW,),
    response=CompanyDetailSchema,
)
def get_company(actor: Actor, company_id: uuid.UUID) -> ApiResult:
    return ApiResult(get_services().companies.get_detail(company_id))


@bp.patch("/companies/<uuid:company_id>")
@endpoint(
    summary="ویرایش، فعال‌سازی یا غیرفعال‌سازی شرکت",
    tag=TAG,
    permissions=(Permission.COMPANY_UPDATE,),
    body=CompanyUpdateSchema,
    response=CompanySchema,
)
def update_company(actor: Actor, company_id: uuid.UUID, body: dict[str, Any]) -> ApiResult:
    return ApiResult(get_services().companies.update(actor, company_id, body), message="اطلاعات شرکت به‌روزرسانی شد.")
