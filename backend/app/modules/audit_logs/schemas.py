"""Audit log request/response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import OutputSchema, PaginationQuerySchema


class AuditLogQuerySchema(PaginationQuerySchema):
    action = fields.String(validate=fields.length(max=100))
    entity_type = fields.String(validate=fields.length(max=100))
    entity_id = fields.String(validate=fields.length(max=64))
    user_id = fields.UUID()
    created_from = fields.AwareDateTime()
    created_to = fields.AwareDateTime()


class AuditUserSchema(OutputSchema):
    id = fields.UUID()
    username = fields.String()
    full_name = fields.String()


class AuditLogSchema(OutputSchema):
    id = fields.UUID()
    action = fields.String()
    entity_type = fields.String()
    entity_id = fields.String(allow_none=True)
    metadata = fields.Raw(attribute="meta", allow_none=True)
    ip_address = fields.String(allow_none=True)
    request_id = fields.String(allow_none=True)
    user = fields.Nested(AuditUserSchema, allow_none=True)
    created_at = fields.DateTime()
