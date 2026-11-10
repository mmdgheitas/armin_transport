"""Customer portal request/response schemas (customer-safe fields only)."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema
from app.models.enums import ProductFieldType, ShipmentStatus


class CustomerLookupSchema(InputSchema):
    tracking_code = fields.String(required=True, validate=fields.length(min=1, max=200))


class CustomerAccessGrantSchema(OutputSchema):
    access_token = fields.String()
    expires_at = fields.DateTime()
    expires_in = fields.Integer()


class CustomerProductDetailSchema(OutputSchema):
    label = fields.String()
    data_type = fields.Enum(ProductFieldType, by_value=True)
    value = fields.Raw(allow_none=True)


class CustomerShipmentSchema(OutputSchema):
    tracking_code = fields.String()
    status = fields.Enum(ShipmentStatus, by_value=True)
    company_name = fields.String(allow_none=True)
    description = fields.String(allow_none=True)
    registered_at = fields.DateTime()
    document_count = fields.Integer()
    product_details = fields.List(fields.Nested(CustomerProductDetailSchema))
    session_expires_at = fields.DateTime()


class CustomerDocumentSchema(OutputSchema):
    """Document as seen by a customer: only what is needed to list and download it."""

    id = fields.UUID()
    name = fields.String(attribute="original_name")
    mime_type = fields.String()
    extension = fields.String()
    file_size = fields.Integer()
    uploaded_at = fields.DateTime(attribute="created_at")
