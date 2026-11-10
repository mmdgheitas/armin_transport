"""Shipment request/response schemas."""

from __future__ import annotations

from typing import Any

from marshmallow import ValidationError, validates_schema

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema, PaginationQuerySchema
from app.models.enums import ShipmentStatus, TrackingCodeType
from app.modules.companies.schemas import CompanyRefSchema
from app.modules.shipments.repository import DEFAULT_SORT, SORT_OPTIONS
from app.modules.users.schemas import PersonRefSchema

_DESCRIPTION_LENGTH = fields.length(max=5000)
# Generous raw limit: the code is normalized (whitespace removed) and validated in the service.
_RAW_CODE_LENGTH = fields.length(min=1, max=200)


class ShipmentCreateSchema(InputSchema):
    company_id = fields.UUID(allow_none=True)
    tracking_code = fields.String(allow_none=True, validate=_RAW_CODE_LENGTH)
    description = fields.String(allow_none=True, validate=_DESCRIPTION_LENGTH)
    product_values = fields.Dict(keys=fields.String(), values=fields.Raw(allow_none=True), allow_none=True)


class ShipmentUpdateSchema(InputSchema):
    tracking_code = fields.String(validate=_RAW_CODE_LENGTH)
    description = fields.String(allow_none=True, validate=_DESCRIPTION_LENGTH)
    product_values = fields.Dict(keys=fields.String(), values=fields.Raw(allow_none=True))


class TrackingCodeChangeSchema(InputSchema):
    tracking_code = fields.String(allow_none=True, validate=_RAW_CODE_LENGTH)
    generate = fields.Boolean(load_default=False)

    @validates_schema
    def _exactly_one_mode(self, data: dict[str, Any], **_: Any) -> None:
        has_code = data.get("tracking_code") is not None
        if has_code == bool(data.get("generate")):
            raise ValidationError(
                {"tracking_code": ["یا کد رهگیری دستی را وارد کنید یا تولید خودکار (generate) را انتخاب کنید."]}
            )


class ShipmentQuerySchema(PaginationQuerySchema):
    q = fields.String(validate=fields.length(max=100))
    tracking_code = fields.String(validate=fields.length(max=200))
    status = fields.Enum(ShipmentStatus, by_value=True)
    tracking_code_type = fields.Enum(TrackingCodeType, by_value=True)
    company_id = fields.UUID()
    created_by = fields.UUID()
    created_from = fields.AwareDateTime()
    created_to = fields.AwareDateTime()
    sort = fields.String(load_default=DEFAULT_SORT, validate=fields.one_of(sorted(SORT_OPTIONS)))


class ShipmentSchema(OutputSchema):
    id = fields.UUID()
    tracking_code = fields.String()
    tracking_code_type = fields.Enum(TrackingCodeType, by_value=True)
    status = fields.Enum(ShipmentStatus, by_value=True)
    description = fields.String(allow_none=True)
    company_id = fields.UUID()
    company = fields.Nested(CompanyRefSchema)
    created_by = fields.Nested(PersonRefSchema, attribute="creator")
    document_count = fields.Integer()
    created_at = fields.DateTime()
    updated_at = fields.DateTime()


class TrackingHistorySchema(OutputSchema):
    id = fields.UUID()
    old_code = fields.String(allow_none=True)
    new_code = fields.String()
    changed_by = fields.Nested(PersonRefSchema, attribute="changer")
    changed_at = fields.DateTime()


class RevokedSessionsSchema(OutputSchema):
    revoked = fields.Integer()
