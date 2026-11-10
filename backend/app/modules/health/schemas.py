"""Health response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import OutputSchema


class HealthSchema(OutputSchema):
    status = fields.String()
    version = fields.String()
    time = fields.DateTime()


class ReadinessChecksSchema(OutputSchema):
    database = fields.String()
    storage = fields.String()


class ReadinessSchema(OutputSchema):
    status = fields.String()
    checks = fields.Nested(ReadinessChecksSchema)
