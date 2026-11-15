"""Company request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema, PaginationQuerySchema
from app.modules.audit_logs.schemas import CompanyActivitySchema

COMPANY_CODE_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9_-]{1,49}$"
_CODE_MESSAGE = "کد شرکت باید ۲ تا ۵۰ نویسه و فقط شامل حروف انگلیسی، رقم، خط تیره و زیرخط باشد."
_PHONE_PATTERN = r"^[0-9+()\-\s]{3,30}$"
_PHONE_MESSAGE = "شمارهٔ تلفن فقط می‌تواند شامل رقم، فاصله و نشانه‌های + - ( ) باشد."


class CompanyCreateSchema(InputSchema):
    username = fields.String(
        required=True, validate=fields.regexp(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$", "نام کاربری معتبر وارد کنید.")
    )
    password = fields.String(required=True, strip=False, validate=fields.length(min=1, max=128))
    name = fields.String(required=True, validate=fields.length(min=2, max=200))
    company_code = fields.String(required=True, validate=fields.regexp(COMPANY_CODE_PATTERN, _CODE_MESSAGE))
    phone = fields.String(allow_none=True, validate=fields.regexp(_PHONE_PATTERN, _PHONE_MESSAGE))
    address = fields.String(allow_none=True, validate=fields.length(max=2000))
    is_active = fields.Boolean(load_default=True)


class CompanyUpdateSchema(InputSchema):
    name = fields.String(validate=fields.length(min=2, max=200))
    company_code = fields.String(validate=fields.regexp(COMPANY_CODE_PATTERN, _CODE_MESSAGE))
    phone = fields.String(allow_none=True, validate=fields.regexp(_PHONE_PATTERN, _PHONE_MESSAGE))
    address = fields.String(allow_none=True, validate=fields.length(max=2000))
    is_active = fields.Boolean()


class CompanyQuerySchema(PaginationQuerySchema):
    q = fields.String(validate=fields.length(max=100))
    is_active = fields.Boolean()


class CompanySchema(OutputSchema):
    last_activity = fields.Nested(CompanyActivitySchema, allow_none=True)
    id = fields.UUID()
    name = fields.String()
    company_code = fields.String()
    phone = fields.String(allow_none=True)
    address = fields.String(allow_none=True)
    is_active = fields.Boolean()
    created_at = fields.DateTime()
    updated_at = fields.DateTime()


class CompanyDetailSchema(CompanySchema):
    employee_count = fields.Integer()
    shipment_count = fields.Integer()


class CompanyRefSchema(OutputSchema):
    last_activity = fields.Nested(CompanyActivitySchema, allow_none=True)
    """Compact company reference embedded in other resources."""

    id = fields.UUID()
    name = fields.String()
    company_code = fields.String()
    is_active = fields.Boolean()
