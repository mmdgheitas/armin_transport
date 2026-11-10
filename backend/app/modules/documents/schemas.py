"""Document request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema
from app.modules.users.schemas import PersonRefSchema


class DocumentUploadFormSchema(InputSchema):
    """Non-file fields of the multipart upload request."""

    customer_visible = fields.Boolean(
        load_default=None,
        allow_none=True,
        metadata={"description": "آیا مشتری با کد رهگیری این سندها را ببیند؟ (پیش‌فرض: تنظیم سامانه)"},
    )


class DocumentUpdateSchema(InputSchema):
    is_customer_visible = fields.Boolean(required=True)


class DocumentSchema(OutputSchema):
    """Document metadata. Storage names and paths are internal and never serialized."""

    id = fields.UUID()
    shipment_id = fields.UUID()
    original_name = fields.String()
    mime_type = fields.String()
    extension = fields.String()
    file_size = fields.Integer()
    checksum = fields.String()
    is_customer_visible = fields.Boolean()
    uploaded_by = fields.Nested(PersonRefSchema, attribute="uploader")
    created_at = fields.DateTime()
