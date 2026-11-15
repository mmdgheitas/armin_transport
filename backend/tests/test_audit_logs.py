"""Audit trail: what is recorded, what is never recorded, and who may read it."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import quote

import pytest
from flask import Flask

from app.extensions import db
from app.models import AuditLog, RefreshToken, User
from app.modules.audit_logs.service import _sanitize
from tests.support import DEFAULT_PASSWORD, PDF_BYTES, Api, Factory, upload_file


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


def _items(client: Api, query: str = "") -> list[dict[str, Any]]:
    response = client.get(f"/audit-logs{query}")
    assert response.status_code == 200, response.get_json()
    items: list[dict[str, Any]] = response.get_json()["data"]["items"]
    return items


def _all_rows(app: Flask) -> list[AuditLog]:
    with app.app_context():
        rows = list(db.session.scalars(db.select(AuditLog).order_by(AuditLog.created_at)))
        db.session.remove()
        return rows


def test_business_scenario_leaves_a_complete_trail(factory: Factory, app: Flask) -> None:
    admin = factory.admin()
    admin_api = factory.login(admin)
    company_id = admin_api.post(
        "/companies",
        json={"name": "شرکت ممیزی", "company_code": "AUD", "username": "audit-company", "password": DEFAULT_PASSWORD},
    ).get_json()["data"]["id"]
    employee_id = admin_api.post(
        "/users",
        json={"username": "audited", "full_name": "کارمند", "password": DEFAULT_PASSWORD, "company_id": company_id},
    ).get_json()["data"]["id"]
    field_id = admin_api.post(
        "/product-fields", json={"field_key": "note", "label": "یادداشت", "data_type": "TEXT"}
    ).get_json()["data"]["id"]

    employee_api = Api(app)
    assert employee_api.login("audited", "wrong-password").status_code == 401
    login = employee_api.login("audited")
    employee_api.token = login.get_json()["data"]["access_token"]

    shipment = employee_api.post("/shipments", json={"description": "محموله", "company_id": company_id}).get_json()[
        "data"
    ]
    shipment_id, first_code = shipment["id"], shipment["tracking_code"]
    employee_api.patch(f"/shipments/{shipment_id}", json={"description": "ویرایش‌شده"})
    employee_api.put(f"/shipments/{shipment_id}/product-values", json={"values": {"note": "متن"}})
    document_id = employee_api.upload(shipment_id, [upload_file("bill.pdf", PDF_BYTES)]).get_json()["data"][0]["id"]
    employee_api.get(f"/documents/{document_id}/download")
    employee_api.patch(f"/documents/{document_id}", json={"is_customer_visible": False})
    employee_api.post(f"/shipments/{shipment_id}/tracking-code", json={"generate": True})
    employee_api.post(f"/shipments/{shipment_id}/archive")
    assert employee_api.get("/users").status_code == 403
    admin_api.post(f"/shipments/{shipment_id}/unarchive")
    admin_api.delete(f"/documents/{document_id}")
    admin_api.patch(f"/product-fields/{field_id}", json={"label": "توضیح"})
    admin_api.patch(f"/companies/{company_id}", json={"phone": "021"})
    admin_api.post(f"/users/{employee_id}/reset-password", json={"new_password": "An0ther-Str0ng-Pass"})
    admin_api.patch(f"/users/{employee_id}", json={"is_active": False})
    admin_api.post("/auth/logout")

    rows = _all_rows(app)
    trail = [(row.action, row.entity_type, row.entity_id) for row in rows]
    expected = [
        ("LOGIN_SUCCESS", "user", str(admin.id)),
        ("COMPANY_CREATED", "company", company_id),
        ("USER_CREATED", "user", employee_id),
        ("PRODUCT_FIELD_CREATED", "product_field_definition", field_id),
        ("LOGIN_FAILED", "user", employee_id),
        ("LOGIN_SUCCESS", "user", employee_id),
        ("SHIPMENT_CREATED", "shipment", shipment_id),
        ("SHIPMENT_UPDATED", "shipment", shipment_id),
        ("PRODUCT_VALUES_UPDATED", "shipment", shipment_id),
        ("DOCUMENT_UPLOADED", "document", document_id),
        ("DOCUMENT_DOWNLOADED", "document", document_id),
        ("TRACKING_CODE_CHANGED", "shipment", shipment_id),
        ("SHIPMENT_ARCHIVED", "shipment", shipment_id),
        ("ACCESS_DENIED", "http_request", None),
        ("SHIPMENT_UNARCHIVED", "shipment", shipment_id),
        ("DOCUMENT_DELETED", "document", document_id),
        ("PRODUCT_FIELD_UPDATED", "product_field_definition", field_id),
        ("COMPANY_UPDATED", "company", company_id),
        ("USER_PASSWORD_RESET", "user", employee_id),
        ("USER_DEACTIVATED", "user", employee_id),
        ("LOGOUT", "user", str(admin.id)),
    ]
    assert trail == expected

    by_action = {row.action: row for row in rows}
    assert by_action["SHIPMENT_CREATED"].user_id == uuid.UUID(employee_id)
    assert by_action["SHIPMENT_UNARCHIVED"].user_id == admin.id
    assert by_action["LOGIN_FAILED"].user_id is None or by_action["LOGIN_FAILED"].user_id == uuid.UUID(employee_id)
    change = by_action["TRACKING_CODE_CHANGED"].meta
    assert change is not None and change["old_code"] == first_code and change["new_code"] != first_code
    assert all(row.ip_address == "127.0.0.1" and row.request_id for row in rows)


def test_trail_never_contains_credentials(factory: Factory, app: Flask) -> None:
    company = factory.company()
    employee = factory.employee(company)
    shipment = factory.shipment(company, employee)
    factory.document(shipment, employee)

    anonymous = Api(app)
    anonymous.login(employee.username, "Wr0ng-Secret-Guess!")
    login = anonymous.login(employee.username).get_json()["data"]
    client = Api(app, login["access_token"])
    rotated = anonymous.post("/auth/refresh", json={"refresh_token": login["refresh_token"]}).get_json()["data"]
    anonymous.post("/auth/refresh", json={"refresh_token": login["refresh_token"]})  # reuse → detected
    client = factory.login(employee)
    client.post(
        "/auth/change-password", json={"current_password": "Wr0ng-Current-Pass!", "new_password": "Brand-New-Passw0rd!"}
    )
    client.post(
        "/auth/change-password", json={"current_password": DEFAULT_PASSWORD, "new_password": "Brand-New-Passw0rd!"}
    )
    portal = factory.login(factory.admin())
    customer = portal.post("/customer/lookup", json={"tracking_code": shipment.tracking_code}).get_json()["data"]
    portal.get(f"/customer/access/{customer['access_token']}/shipment")
    documents = portal.get(f"/customer/access/{customer['access_token']}/documents").get_json()["data"]["items"]
    portal.get(f"/customer/access/{customer['access_token']}/documents/{documents[0]['id']}/download")
    portal.post("/customer/lookup", json={"tracking_code": "GUESSED-CODE-123"})

    rows = _all_rows(app)
    assert {"LOGIN_FAILED", "REFRESH_TOKEN_REUSE_DETECTED", "PASSWORD_CHANGE_FAILED", "PASSWORD_CHANGED"} <= {
        row.action for row in rows
    }
    dump = json.dumps(
        [[row.action, row.entity_type, row.entity_id, row.meta] for row in rows], ensure_ascii=False, default=str
    )
    secrets = [
        DEFAULT_PASSWORD,
        "Wr0ng-Secret-Guess!",
        "Wr0ng-Current-Pass!",
        "Brand-New-Passw0rd!",
        login["access_token"],
        login["refresh_token"],
        rotated["access_token"],
        rotated["refresh_token"],
        customer["access_token"],
        "GUESSED-CODE-123",  # a failed guess may be a typo of a real code: it is not stored in clear text
        "argon2",
    ]
    for secret in secrets:
        assert secret not in dump


def test_metadata_sanitizer_drops_credential_like_keys_and_bounds_strings() -> None:
    cleaned = _sanitize(
        {
            "username": "sara",
            "Password": "x",
            "new_password": "x",
            "access_token": "x",
            "Authorization": "Bearer x",
            "client_secret": "x",
            "nested": {"refresh_token": "x", "kept": [1, "two", {"api_token": "x", "ok": True}]},
            "long": "ا" * 2000,
            "when": datetime(2026, 1, 1, tzinfo=UTC),
            "identifier": uuid.UUID(int=1),
            "tags": {"b"},
        }
    )
    assert cleaned == {
        "username": "sara",
        "nested": {"kept": [1, "two", {"ok": True}]},
        "long": "ا" * 500,
        "when": "2026-01-01 00:00:00+00:00",
        "identifier": "00000000-0000-0000-0000-000000000001",
        "tags": ["b"],
    }
    json.dumps(cleaned)  # always JSON-serializable


def test_entry_shape(admin_api: Api, factory: Factory) -> None:
    admin_api.post(
        "/companies",
        json={"name": "شرکت", "company_code": "SHAPE", "username": "shape-company", "password": DEFAULT_PASSWORD},
        headers={"X-Request-ID": "trace-12345678"},
    )
    entry = _items(admin_api, "?action=COMPANY_CREATED")[0]
    assert set(entry) == {
        "id", "company_id", "action", "entity_type", "entity_id", "metadata", "ip_address", "request_id", "user", "created_at",
    }  # fmt: skip
    assert entry["entity_type"] == "company"
    assert entry["request_id"] == "trace-12345678"
    assert entry["ip_address"] == "127.0.0.1"
    assert set(entry["user"]) == {"id", "username", "full_name"}
    assert entry["metadata"]["company_code"] == "SHAPE"
    assert entry["created_at"].endswith("Z")


def test_entries_of_anonymous_events_have_no_user(admin_api: Api, api: Api) -> None:
    api.login("nobody-here", "whatever-password")
    failed = _items(admin_api, "?action=LOGIN_FAILED")
    assert len(failed) == 1
    assert failed[0]["user"] is None
    assert failed[0]["entity_id"] is None


def test_filters_and_ordering(factory: Factory, app: Flask) -> None:
    admin = factory.admin()
    admin_api = factory.login(admin)
    company = factory.company()
    employee = factory.employee(company)
    employee_api = factory.login(employee)
    first = employee_api.post("/shipments", json={"company_id": str(company.id)}).get_json()["data"]["id"]
    second = employee_api.post("/shipments", json={"company_id": str(company.id)}).get_json()["data"]["id"]
    employee_api.post(f"/shipments/{first}/archive")

    everything = _items(admin_api, "?per_page=100")
    stamps = [item["created_at"] for item in everything]
    assert stamps == sorted(stamps, reverse=True)  # newest first

    assert [item["entity_id"] for item in _items(admin_api, "?action=SHIPMENT_CREATED")] == [second, first]
    assert {item["action"] for item in _items(admin_api, f"?entity_type=shipment&entity_id={first}")} == {
        "SHIPMENT_CREATED",
        "SHIPMENT_ARCHIVED",
    }
    assert {item["user"]["id"] for item in _items(admin_api, f"?user_id={employee.id}")} == {str(employee.id)}
    assert {item["action"] for item in _items(admin_api, f"?user_id={admin.id}")} == {"LOGIN_SUCCESS"}
    assert _items(admin_api, "?action=NO_SUCH_ACTION") == []

    # Time window: move one entry into the past and select it by range.
    old = datetime(2025, 3, 1, 12, 0, tzinfo=UTC)
    with app.app_context():
        db.session.execute(db.update(AuditLog).where(AuditLog.action == "SHIPMENT_ARCHIVED").values(created_at=old))
        db.session.commit()
        db.session.remove()
    window_end = quote((old + timedelta(hours=1)).isoformat())
    window_start = quote((old - timedelta(hours=1)).isoformat())
    assert [item["action"] for item in _items(admin_api, f"?created_to={window_end}")] == ["SHIPMENT_ARCHIVED"]
    assert [item["action"] for item in _items(admin_api, f"?created_from={window_start}&created_to={window_end}")] == [
        "SHIPMENT_ARCHIVED"
    ]
    recent = _items(admin_api, f"?created_from={window_end}&per_page=100")
    assert "SHIPMENT_ARCHIVED" not in {item["action"] for item in recent}
    assert len(recent) == len(everything) - 1


def test_pagination(admin_api: Api, api: Api) -> None:
    for index in range(5):
        api.login(f"ghost-{index}", "some-password")
    page = admin_api.get("/audit-logs?action=LOGIN_FAILED&per_page=2&page=3").get_json()["data"]
    assert len(page["items"]) == 1
    assert page["pagination"] == {
        "page": 3, "per_page": 2, "total": 5, "total_pages": 3, "has_next": False, "has_prev": True,
    }  # fmt: skip


@pytest.mark.parametrize(
    "query",
    [
        "user_id=not-a-uuid",
        "created_from=yesterday",
        "created_from=2026-01-01T00:00:00",  # naive datetimes are ambiguous and therefore rejected
        "per_page=0",
        "per_page=101",
        "page=0",
        "action=" + "A" * 101,
    ],
)
def test_invalid_filters_are_rejected(admin_api: Api, query: str) -> None:
    response = admin_api.get(f"/audit-logs?{query}")
    assert response.status_code == 422
    assert query.split("=", maxsplit=1)[0] in response.get_json()["errors"]["fields"]


def test_trail_is_read_only_and_admin_only(admin_api: Api, factory: Factory) -> None:
    for method in ("post", "put", "patch", "delete"):
        assert getattr(admin_api, method)("/audit-logs").status_code == 405
    entry_id = _items(admin_api)[0]["id"]
    assert admin_api.delete(f"/audit-logs/{entry_id}").status_code == 404  # no such route at all

    employee_api = factory.login(factory.employee())
    denied = employee_api.get("/audit-logs")
    assert denied.status_code == 403
    assert denied.get_json()["errors"]["required_permissions"] == ["audit_log:view"]


def test_failed_operations_do_not_leave_success_entries(factory: Factory) -> None:
    """The entry is written in the same transaction as the change it describes."""
    admin_api = factory.login(factory.admin())
    factory.company(company_code="TAKEN")
    assert (
        admin_api.post(
            "/companies",
            json={
                "name": "تکراری",
                "company_code": "TAKEN",
                "username": "duplicate-company",
                "password": DEFAULT_PASSWORD,
            },
        ).status_code
        == 409
    )
    assert admin_api.post("/companies", json={"name": "", "company_code": "NEW"}).status_code == 422
    assert "COMPANY_CREATED" not in factory.audit_actions()


def test_deleting_a_user_row_keeps_its_audit_entries(factory: Factory, app: Flask) -> None:
    """The application never deletes users; if an operator does, history survives (ON DELETE SET NULL)."""

    admin = factory.admin()
    factory.login(admin)
    with app.app_context():
        db.session.execute(db.delete(RefreshToken).where(RefreshToken.user_id == admin.id))
        db.session.execute(db.delete(User).where(User.id == admin.id))
        db.session.commit()
        entries = db.session.scalars(db.select(AuditLog).where(AuditLog.action == "LOGIN_SUCCESS")).all()
        assert len(entries) == 1
        assert entries[0].user_id is None
        assert entries[0].entity_id == str(admin.id)
        db.session.remove()
