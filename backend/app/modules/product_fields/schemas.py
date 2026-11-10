"""Product field request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import InputSchema, OutputSchema, PaginationQuerySchema
from app.models.enums import ProductFieldType

FIELD_KEY_PATTERN = r"^[a-z][a-z0-9_]{1,99}$"
_FIELD_KEY_MESSAGE = (
    "کلید فیلد باید با حرف کوچک انگلیسی شروع شود و فقط شامل حروف کوچک، رقم و زیرخط باشد (۲ تا ۱۰۰ نویسه)."
)


class ProductFieldCreateSchema(InputSchema):
    field_key = fields.String(required=True, validate=fields.regexp(FIELD_KEY_PATTERN, _FIELD_KEY_MESSAGE))
    label = fields.String(required=True, validate=fields.length(min=1, max=200))
    data_type = fields.Enum(ProductFieldType, by_value=True, required=True)
    is_required = fields.Boolean(load_default=False)
    is_active = fields.Boolean(load_default=True)
    is_customer_visible = fields.Boolean(load_default=False)
    display_order = fields.Integer(load_default=0, validate=fields.number_range(min=0, max=100000))
    validation_rules = fields.Dict(keys=fields.String(), allow_none=True, load_default=None)
    options = fields.List(fields.Dict(keys=fields.String()), allow_none=True, load_default=None)


class ProductFieldUpdateSchema(InputSchema):
    # ``field_key`` and ``data_type`` are accepted only to return a precise error:
    # they are immutable so the meaning of stored values can never change silently.
    field_key = fields.String()
    data_type = fields.String()
    label = fields.String(validate=fields.length(min=1, max=200))
    is_required = fields.Boolean()
    is_active = fields.Boolean()
    is_customer_visible = fields.Boolean()
    display_order = fields.Integer(validate=fields.number_range(min=0, max=100000))
    validation_rules = fields.Dict(keys=fields.String(), allow_none=True)
    options = fields.List(fields.Dict(keys=fields.String()), allow_none=True)


class ProductFieldQuerySchema(PaginationQuerySchema):
    q = fields.String(validate=fields.length(max=100))
    include_inactive = fields.Boolean(load_default=False)


class ProductFieldOptionSchema(OutputSchema):
    value = fields.String()
    label = fields.String()


class ProductFieldSchema(OutputSchema):
    id = fields.UUID()
    field_key = fields.String()
    label = fields.String()
    data_type = fields.Enum(ProductFieldType, by_value=True)
    is_required = fields.Boolean()
    is_active = fields.Boolean()
    is_customer_visible = fields.Boolean()
    display_order = fields.Integer()
    validation_rules = fields.Dict(allow_none=True)
    options = fields.List(fields.Nested(ProductFieldOptionSchema), allow_none=True)
    version = fields.Integer()
    created_at = fields.DateTime()
    updated_at = fields.DateTime()


class ProductValuesUpdateSchema(InputSchema):
    values = fields.Dict(keys=fields.String(), values=fields.Raw(allow_none=True), required=True)


class ProductValueItemSchema(OutputSchema):
    field = fields.Nested(ProductFieldSchema)
    value = fields.Raw(allow_none=True)
    display_value = fields.Raw(allow_none=True)
    field_version = fields.Integer(allow_none=True)
    is_outdated = fields.Boolean()
    updated_at = fields.DateTime(allow_none=True)


class ProductValuesSchema(OutputSchema):
    items = fields.List(fields.Nested(ProductValueItemSchema))
