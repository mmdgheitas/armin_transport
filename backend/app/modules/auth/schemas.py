"""Authentication request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema
from app.modules.users.schemas import UserSchema


class LoginSchema(InputSchema):
    username = fields.String(required=True, validate=fields.length(min=1, max=100))
    password = fields.String(required=True, strip=False, validate=fields.length(min=1, max=128))


class RefreshSchema(InputSchema):
    refresh_token = fields.String(required=True, validate=fields.length(min=20, max=512))


class ChangePasswordSchema(InputSchema):
    current_password = fields.String(required=True, strip=False, validate=fields.length(min=1, max=128))
    new_password = fields.String(required=True, strip=False, validate=fields.length(min=1, max=128))


class UploadSettingsSchema(OutputSchema):
    max_file_size_bytes = fields.Integer()
    max_files_per_upload = fields.Integer()
    allowed_extensions = fields.List(fields.String())
    customer_visible_default = fields.Boolean()


class TrackingCodeSettingsSchema(OutputSchema):
    min_length = fields.Integer()
    max_length = fields.Integer()
    pattern = fields.String()


class PasswordSettingsSchema(OutputSchema):
    min_length = fields.Integer()


class PaginationSettingsSchema(OutputSchema):
    default_page_size = fields.Integer()
    max_page_size = fields.Integer()


class ClientSettingsSchema(OutputSchema):
    upload = fields.Nested(UploadSettingsSchema)
    tracking_code = fields.Nested(TrackingCodeSettingsSchema)
    password = fields.Nested(PasswordSettingsSchema)
    pagination = fields.Nested(PaginationSettingsSchema)


class ProfileSchema(OutputSchema):
    user = fields.Nested(UserSchema)
    permissions = fields.List(fields.String())
    app_settings = fields.Nested(ClientSettingsSchema)


class AuthSessionSchema(ProfileSchema):
    access_token = fields.String()
    refresh_token = fields.String()
    token_type = fields.String()
    expires_in = fields.Integer()
    refresh_expires_in = fields.Integer()
