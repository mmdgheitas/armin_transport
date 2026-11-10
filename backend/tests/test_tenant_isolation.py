"""Tenant isolation: an employee can never read or change another company's data."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from typing import Any

import pytest
from flask import Flask

from app.extensions import db
from app.models import AuditLog, Company, Document, Shipment, ShipmentProductValue, TrackingCodeHistory, User
from tests.support import PDF_BYTES, Api, Factory, upload_file


class Tenant:
    def __init__(self, factory: Factory, name: str) -> None:
        self.company: Company = factory.company(name=name)
        self.employee: User = factory.employee(self.company)
        self.shipment: Shipment = factory.shipment(self.company, self.employee, description=f"محرمانهٔ {name}")
        self.document: Document = factory.document(self.shipment, self.employee, original_name=f"{name}.pdf")
        self.api: Api = factory.login(self.employee)


@pytest.fixture
def alpha(factory: Factory) -> Tenant:
    return Tenant(factory, "آلفا")


@pytest.fixture
def beta(factory: Factory) -> Tenant:
    return Tenant(factory, "بتا")


def _snapshot(app: Flask, tenant: Tenant) -> dict[str, Any]:
    with app.app_context():
        shipment = db.session.get(Shipment, tenant.shipment.id)
        document = db.session.get(Document, tenant.document.id)
        assert shipment is not None and document is not None
        result = {
            "tracking_code": shipment.tracking_code,
            "status": shipment.status,
            "description": shipment.description,
            "updated_at": shipment.updated_at,
            "document_visible": document.is_customer_visible,
            "document_deleted": document.deleted_at,
            "documents": db.session.scalar(
                db.select(db.func.count()).select_from(Document).where(Document.shipment_id == shipment.id)
            ),
            "history": db.session.scalar(
                db.select(db.func.count())
                .select_from(TrackingCodeHistory)
                .where(TrackingCodeHistory.shipment_id == shipment.id)
            ),
            "values": db.session.scalar(
                db.select(db.func.count())
                .select_from(ShipmentProductValue)
                .where(ShipmentProductValue.shipment_id == shipment.id)
            ),
        }
        db.session.remove()
        return result


def _attempts(intruder: Api, victim: Tenant) -> dict[str, Any]:
    shipment, document = victim.shipment.id, victim.document.id
    return {
        "read shipment": intruder.get(f"/shipments/{shipment}"),
        "read shipment with a company hint": intruder.get(f"/shipments/{shipment}?company_id={victim.company.id}"),
        "update shipment": intruder.patch(f"/shipments/{shipment}", json={"description": "دستکاری"}),
        "archive shipment": intruder.post(f"/shipments/{shipment}/archive"),
        "regenerate code": intruder.post(f"/shipments/{shipment}/tracking-code", json={"generate": True}),
        "read code history": intruder.get(f"/shipments/{shipment}/tracking-history"),
        "list documents": intruder.get(f"/shipments/{shipment}/documents"),
        "upload document": intruder.upload(shipment, [upload_file("x.pdf", PDF_BYTES)]),
        "read product values": intruder.get(f"/shipments/{shipment}/product-values"),
        "write product values": intruder.put(f"/shipments/{shipment}/product-values", json={"values": {"note": "x"}}),
        "revoke customer sessions": intruder.post(f"/shipments/{shipment}/customer-sessions/revoke"),
        "download document": intruder.get(f"/documents/{document}/download"),
        "change document visibility": intruder.patch(f"/documents/{document}", json={"is_customer_visible": False}),
    }


def test_foreign_resources_are_indistinguishable_from_missing_ones(
    alpha: Tenant, beta: Tenant, factory: Factory, app: Flask
) -> None:
    factory.field(field_key="note")
    before = _snapshot(app, beta)

    for label, response in _attempts(alpha.api, beta).items():
        assert response.status_code == 404, f"{label}: {response.status_code}"
        body = response.get_json()
        assert body["errors"]["code"] == "not_found", label
        raw = response.get_data(as_text=True)
        assert PDF_BYTES not in response.data, label
        for secret in (beta.shipment.tracking_code, "محرمانهٔ بتا", beta.company.name, beta.document.original_name):
            assert secret not in raw, f"{label} leaked {secret!r}"

    assert _snapshot(app, beta) == before

    # The same requests against ids that do not exist produce the very same answers.
    ghost = Tenant.__new__(Tenant)
    ghost.company = beta.company
    ghost.shipment = Shipment(id=uuid.uuid4())
    ghost.document = Document(id=uuid.uuid4())
    for label, response in _attempts(alpha.api, ghost).items():
        assert response.status_code == 404, label
        assert response.get_json()["errors"]["code"] == "not_found", label


def test_cross_tenant_attempts_leave_no_business_audit_entries(alpha: Tenant, beta: Tenant, app: Flask) -> None:
    _attempts(alpha.api, beta)
    with app.app_context():
        entries = db.session.scalars(db.select(AuditLog).where(AuditLog.user_id == alpha.employee.id)).all()
        actions = {entry.action for entry in entries}
        touched = {entry.entity_id for entry in entries}
        db.session.remove()
    assert actions <= {"LOGIN_SUCCESS", "DOCUMENT_UPLOAD_REJECTED"}
    assert str(beta.shipment.id) not in touched and str(beta.document.id) not in touched


def test_delete_stays_scoped_even_when_employees_may_delete(
    alpha: Tenant, beta: Tenant, factory: Factory, make_app: Callable[..., Flask]
) -> None:
    assert alpha.api.delete(f"/documents/{beta.document.id}").status_code == 403  # default: no delete permission
    permissive = make_app(employee_can_delete_documents=True)
    intruder = factory.login(alpha.employee, app=permissive)
    assert intruder.delete(f"/documents/{beta.document.id}").status_code == 404
    assert factory.get(Document, beta.document.id).deleted_at is None
    assert intruder.delete(f"/documents/{alpha.document.id}").status_code == 200


def test_lists_and_counters_only_contain_own_data(alpha: Tenant, beta: Tenant, factory: Factory) -> None:
    for _ in range(3):
        factory.shipment(beta.company, beta.employee)

    listing = alpha.api.get("/shipments?per_page=100").get_json()["data"]
    assert [item["id"] for item in listing["items"]] == [str(alpha.shipment.id)]
    assert listing["pagination"]["total"] == 1

    for query in (
        f"q={beta.shipment.tracking_code}",
        f"tracking_code={beta.shipment.tracking_code}",
        "q=بتا",
        f"created_by={beta.employee.id}",
    ):
        assert alpha.api.get(f"/shipments?{query}").get_json()["data"]["items"] == [], query

    dashboard = alpha.api.get("/dashboard/summary").get_json()["data"]
    assert dashboard["scope"] == "COMPANY"
    assert dashboard["company"]["id"] == str(alpha.company.id)
    assert dashboard["shipments"] == {"total": 1, "active": 1, "archived": 0}
    assert dashboard["documents"] == 1
    assert dashboard["companies"] is None and dashboard["employees"] is None
    assert [item["id"] for item in dashboard["recent_shipments"]] == [str(alpha.shipment.id)]


def test_company_filter_cannot_be_used_to_cross_tenants(alpha: Tenant, beta: Tenant, factory: Factory) -> None:
    listing = alpha.api.get(f"/shipments?company_id={beta.company.id}")
    assert listing.status_code == 403
    assert listing.get_json()["errors"]["code"] == "company_scope_violation"

    created = alpha.api.post("/shipments", json={"company_id": str(beta.company.id), "description": "نفوذ"})
    assert created.status_code == 403
    assert factory.count(Shipment, Shipment.company_id == beta.company.id) == 1


@pytest.mark.parametrize("header", ["X-Company-Id", "X-Tenant-Id", "X-User-Id", "X-Role"])
def test_client_supplied_identity_headers_are_ignored(alpha: Tenant, beta: Tenant, header: str) -> None:
    value = "SUPER_ADMIN" if header == "X-Role" else str(beta.company.id)
    response = alpha.api.get(f"/shipments/{beta.shipment.id}", headers={header: value})
    assert response.status_code == 404
    assert alpha.api.get("/companies", headers={header: value}).status_code == 403


def test_employee_moved_to_another_company_loses_the_old_scope(alpha: Tenant, beta: Tenant, factory: Factory) -> None:
    admin_api = factory.login(factory.admin())
    assert admin_api.patch(f"/users/{alpha.employee.id}", json={"company_id": str(beta.company.id)}).status_code == 200
    assert alpha.api.get(f"/shipments/{alpha.shipment.id}").status_code == 401  # old session is gone

    moved = factory.login(alpha.employee)
    assert moved.get(f"/shipments/{alpha.shipment.id}").status_code == 404
    assert moved.get(f"/shipments/{beta.shipment.id}").status_code == 200


def test_admin_has_global_scope(alpha: Tenant, beta: Tenant, factory: Factory) -> None:
    admin_api = factory.login(factory.admin())
    for tenant in (alpha, beta):
        assert admin_api.get(f"/shipments/{tenant.shipment.id}").status_code == 200
        assert admin_api.get(f"/documents/{tenant.document.id}/download").status_code == 200
    dashboard = admin_api.get("/dashboard/summary").get_json()["data"]
    assert dashboard["scope"] == "GLOBAL"
    assert dashboard["company"] is None
    assert dashboard["companies"] == {"total": 2, "active": 2}
    assert dashboard["employees"] == {"total": 2, "active": 2}
    assert dashboard["shipments"]["total"] == 2
    assert dashboard["documents"] == 2
