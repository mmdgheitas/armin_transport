"""Dashboard response schemas."""

from __future__ import annotations

from app.core import fields
from app.core.schemas import OutputSchema
from app.modules.companies.schemas import CompanyRefSchema
from app.modules.shipments.schemas import ShipmentSchema


class ActiveCountSchema(OutputSchema):
    total = fields.Integer()
    active = fields.Integer()


class ShipmentCountSchema(OutputSchema):
    total = fields.Integer()
    active = fields.Integer()
    archived = fields.Integer()


class DashboardSummarySchema(OutputSchema):
    scope = fields.String(metadata={"enum": ["GLOBAL", "COMPANY"]})
    company = fields.Nested(CompanyRefSchema, allow_none=True)
    companies = fields.Nested(ActiveCountSchema, allow_none=True)
    employees = fields.Nested(ActiveCountSchema, allow_none=True)
    shipments = fields.Nested(ShipmentCountSchema)
    documents = fields.Integer()
    recent_shipments = fields.List(fields.Nested(ShipmentSchema))
