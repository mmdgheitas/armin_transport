"""User request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema, PaginationQuerySchema
from app.models.enums import UserRole
from app.modules.companies.schemas import CompanyRefSchema

USERNAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$"
_USERNAME_MESSAGE = "نام کاربری باید ۳ تا ۱۰۰ نویسه و فقط شامل حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط باشد."
_PASSWORD_LENGTH = fields.length(min=1, max=128)


class UserCreateSchema(InputSchema):
    role = fields.Enum(
        UserRole,
        by_value=True,
        load_default=UserRole.EMPLOYEE,
        validate=fields.one_of([UserRole.EMPLOYEE, UserRole.CUSTOMER]),
    )
    username = fields.String(required=True, validate=fields.regexp(USERNAME_PATTERN, _USERNAME_MESSAGE))
    full_name = fields.String(required=True, validate=fields.length(min=2, max=200))
    password = fields.String(required=True, strip=False, validate=_PASSWORD_LENGTH)
    company_id = fields.UUID(required=True)
    is_active = fields.Boolean(load_default=True)


class UserUpdateSchema(InputSchema):
    username = fields.String(validate=fields.regexp(USERNAME_PATTERN, _USERNAME_MESSAGE))
    full_name = fields.String(validate=fields.length(min=2, max=200))
    company_id = fields.UUID()
    is_active = fields.Boolean()


class PasswordResetSchema(InputSchema):
    new_password = fields.String(required=True, strip=False, validate=_PASSWORD_LENGTH)


class UserQuerySchema(PaginationQuerySchema):
    q = fields.String(validate=fields.length(max=100))
    company_id = fields.UUID()
    role = fields.Enum(UserRole, by_value=True)
    is_active = fields.Boolean()


class UserSchema(OutputSchema):
    """Public representation of a user. The password hash is never serialized."""

    id = fields.UUID()
    username = fields.String()
    full_name = fields.String()
    role = fields.Enum(UserRole, by_value=True)
    is_active = fields.Boolean()
    company_id = fields.UUID(allow_none=True)
    company = fields.Nested(CompanyRefSchema, allow_none=True)
    last_login_at = fields.DateTime(allow_none=True)
    created_at = fields.DateTime()
    updated_at = fields.DateTime()


class PersonRefSchema(OutputSchema):
    """Minimal user reference embedded in other resources (login names are not exposed)."""

    id = fields.UUID()
    full_name = fields.String()
