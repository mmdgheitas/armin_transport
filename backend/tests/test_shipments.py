"""Shipments: creation, listing, updates, archive and tracking codes."""

from __future__ import annotations

import re
import threading
import uuid
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from flask import Flask

from app.core.datetime_utils import utcnow
from app.extensions import db
from app.models import AuditLog, Shipment, TrackingCodeHistory
from app.modules.shipments.repository import ShipmentRepository
from app.modules.shipments.tracking_codes import TrackingCodeGenerator
from tests.support import Api, Factory

AUTO_CODE = r"^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$"


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


def _code(response: Any) -> str:
    result: str = response.get_json()["errors"]["code"]
    return result


# --------------------------------------------------------------------------- create
def test_employee_creates_a_shipment_for_their_own_company(factory: Factory, app: Flask) -> None:

    employee = factory.employee()
    client = factory.login(employee)
    response = client.post("/shipments", json={"description": "  ۲۰ کارتن لوازم یدکی  "})
    assert response.status_code == 201, response.get_json()
    data = response.get_json()["data"]
    assert re.fullmatch(AUTO_CODE, data["tracking_code"])
    assert data["tracking_code_type"] == "AUTO"
    assert data["status"] == "ACTIVE"
    assert data["description"] == "۲۰ کارتن لوازم یدکی"
    assert data["company_id"] == str(employee.company_id)
    assert data["created_by"] == {"id": str(employee.id), "full_name": employee.full_name}
    assert data["document_count"] == 0

    with app.app_context():
        history = db.session.scalars(db.select(TrackingCodeHistory)).all()
        assert [(row.old_code, row.new_code, row.changed_by) for row in history] == [
            (None, data["tracking_code"], employee.id)
        ]
        audit = db.session.scalars(db.select(AuditLog).where(AuditLog.action == "SHIPMENT_CREATED")).one()
        assert audit.user_id == employee.id
        assert audit.entity_id == data["id"]
        assert audit.meta["tracking_code_type"] == "AUTO"
        db.session.remove()


def test_generated_codes_are_unique_per_shipment(factory: Factory) -> None:
    client = factory.login(factory.employee())
    codes = {client.post("/shipments", json={}).get_json()["data"]["tracking_code"] for _ in range(25)}
    assert len(codes) == 25


def test_employee_cannot_create_a_shipment_for_another_company(factory: Factory) -> None:
    employee = factory.employee()
    other_company = factory.company()
    client = factory.login(employee)
    response = client.post("/shipments", json={"company_id": str(other_company.id)})
    assert response.status_code == 403
    assert _code(response) == "company_scope_violation"
    assert factory.count(Shipment) == 0
    assert factory.audit_actions()[-1] == "ACCESS_DENIED"


def test_employee_may_state_their_own_company_explicitly(factory: Factory) -> None:
    employee = factory.employee()
    response = factory.login(employee).post("/shipments", json={"company_id": str(employee.company_id)})
    assert response.status_code == 201


def test_admin_must_choose_an_existing_active_company(admin_api: Api, factory: Factory) -> None:
    missing = admin_api.post("/shipments", json={})
    assert missing.status_code == 422
    assert "company_id" in missing.get_json()["errors"]["fields"]

    unknown = admin_api.post("/shipments", json={"company_id": str(uuid.uuid4())})
    assert unknown.status_code == 422

    inactive_company = factory.company(is_active=False)
    inactive = admin_api.post("/shipments", json={"company_id": str(inactive_company.id)})
    assert inactive.status_code == 422
    assert _code(inactive) == "company_inactive"

    company = factory.company()
    created = admin_api.post("/shipments", json={"company_id": str(company.id)})
    assert created.status_code == 201
    assert created.get_json()["data"]["company"]["id"] == str(company.id)


def test_admin_can_set_a_manual_tracking_code_which_is_normalized(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    response = admin_api.post("/shipments", json={"company_id": str(company.id), "tracking_code": "  arm-۱۴۰۵ 0007 "})
    assert response.status_code == 201, response.get_json()
    data = response.get_json()["data"]
    assert data["tracking_code"] == "ARM-14050007"
    assert data["tracking_code_type"] == "MANUAL"


def test_employee_manual_code_is_a_configurable_business_rule(factory: Factory, make_app: Callable[..., Flask]) -> None:
    employee = factory.employee()
    denied = factory.login(employee).post("/shipments", json={"tracking_code": "MANUAL-0001"})
    assert denied.status_code == 403
    assert _code(denied) == "manual_tracking_code_not_allowed"
    assert denied.get_json()["errors"]["required_permissions"] == ["tracking_code:manual"]
    assert factory.count(Shipment) == 0

    permissive = make_app(employee_can_use_manual_tracking_code=True)
    allowed = factory.login(employee, app=permissive).post("/shipments", json={"tracking_code": "MANUAL-0001"})
    assert allowed.status_code == 201, allowed.get_json()
    assert allowed.get_json()["data"]["tracking_code_type"] == "MANUAL"


@pytest.mark.parametrize(
    "code",
    ["abc", "A" * 65, "-ABC1234", "ABC1234-", "ABC_1234", "کد-۱۲۳۴۵۶", "ABC/12345", "ABC12345'--", "<b>ABC123</b>"],
)
def test_invalid_manual_codes_are_rejected(admin_api: Api, factory: Factory, code: str) -> None:
    company = factory.company()
    response = admin_api.post("/shipments", json={"company_id": str(company.id), "tracking_code": code})
    assert response.status_code == 422, response.get_json()
    assert "tracking_code" in response.get_json()["errors"]["fields"]
    assert factory.count(Shipment) == 0


def test_duplicate_manual_code_is_rejected_in_any_spelling(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    first = admin_api.post("/shipments", json={"company_id": str(company.id), "tracking_code": "DUP-CODE-01"})
    assert first.status_code == 201
    for spelling in ("DUP-CODE-01", "dup-code-01", " Dup-Code-۰۱ "):
        response = admin_api.post("/shipments", json={"company_id": str(company.id), "tracking_code": spelling})
        assert response.status_code == 409
        assert _code(response) == "tracking_code_taken"
        assert "tracking_code" in response.get_json()["errors"]["fields"]
    assert factory.count(Shipment) == 1


def test_codes_are_unique_across_companies(admin_api: Api, factory: Factory) -> None:
    first, second = factory.company(), factory.company()
    assert (
        admin_api.post("/shipments", json={"company_id": str(first.id), "tracking_code": "GLOBAL-0001"}).status_code
        == 201
    )
    response = admin_api.post("/shipments", json={"company_id": str(second.id), "tracking_code": "GLOBAL-0001"})
    assert response.status_code == 409


def test_create_is_atomic_when_product_values_are_invalid(factory: Factory) -> None:
    factory.field(field_key="weight", data_type="NUMBER", is_required=True)
    client = factory.login(factory.employee())
    response = client.post("/shipments", json={"product_values": {"weight": "heavy"}})
    assert response.status_code == 422
    assert "values.weight" in response.get_json()["errors"]["fields"]
    assert factory.count(Shipment) == 0
    assert factory.count(TrackingCodeHistory) == 0
    assert "SHIPMENT_CREATED" not in factory.audit_actions()


@pytest.mark.parametrize(
    "payload",
    [
        {"description": "x" * 5001},
        {"status": "ARCHIVED"},
        {"created_by": str(uuid.uuid4())},
        {"tracking_code_type": "MANUAL"},
        {"company_id": "nope"},
        {"product_values": ["a"]},
    ],
)
def test_create_validation(factory: Factory, payload: dict[str, Any]) -> None:
    response = factory.login(factory.employee()).post("/shipments", json=payload)
    assert response.status_code == 422


# --------------------------------------------------------------------------- read
def test_employee_only_lists_shipments_of_their_company(factory: Factory, admin_api: Api) -> None:
    company_a, company_b = factory.company(), factory.company()
    employee_a, employee_b = factory.employee(company_a), factory.employee(company_b)
    own = [factory.shipment(company_a, employee_a) for _ in range(3)]
    foreign = [factory.shipment(company_b, employee_b) for _ in range(2)]

    data = factory.login(employee_a).get("/shipments").get_json()["data"]
    assert {item["id"] for item in data["items"]} == {str(item.id) for item in own}
    assert data["pagination"]["total"] == 3

    everything = admin_api.get("/shipments").get_json()["data"]
    assert everything["pagination"]["total"] == 5
    filtered = admin_api.get(f"/shipments?company_id={company_b.id}").get_json()["data"]
    assert {item["id"] for item in filtered["items"]} == {str(item.id) for item in foreign}


def test_employee_cannot_widen_the_list_scope_with_a_filter(factory: Factory) -> None:
    employee = factory.employee()
    other_company = factory.company()
    factory.shipment(other_company, factory.employee(other_company))
    client = factory.login(employee)
    response = client.get(f"/shipments?company_id={other_company.id}")
    assert response.status_code == 403
    assert _code(response) == "company_scope_violation"
    assert client.get(f"/shipments?company_id={employee.company_id}").status_code == 200


def test_get_shipment_detail(factory: Factory) -> None:
    employee = factory.employee()
    company = factory.company_of(employee)
    shipment = factory.shipment(company, employee, description="توضیح")
    factory.document(shipment, employee)
    factory.document(shipment, employee, deleted_at=utcnow(), deleted_by=employee.id)
    data = factory.login(employee).get(f"/shipments/{shipment.id}").get_json()["data"]
    assert data["id"] == str(shipment.id)
    assert data["tracking_code"] == shipment.tracking_code
    assert data["document_count"] == 1  # deleted documents are not counted
    assert data["company"]["name"] == company.name


def test_shipment_of_another_company_looks_like_a_missing_one(factory: Factory) -> None:
    employee = factory.employee()
    other_company = factory.company()
    foreign = factory.shipment(other_company, factory.employee(other_company))
    client = factory.login(employee)
    hidden = client.get(f"/shipments/{foreign.id}")
    missing = client.get(f"/shipments/{uuid.uuid4()}")
    assert hidden.status_code == missing.status_code == 404
    assert hidden.get_json()["message"] == missing.get_json()["message"]
    assert _code(hidden) == _code(missing) == "not_found"


def test_list_filters_and_sorting(factory: Factory, app: Flask) -> None:
    employee = factory.employee()
    colleague = factory.employee(factory.company_of(employee))
    company = factory.company_of(employee)
    now = utcnow()
    oldest = factory.shipment(
        company, employee, tracking_code="AAA-000001", description="فرش دستباف", created_at=now - timedelta(days=10)
    )
    middle = factory.shipment(
        company,
        colleague,
        tracking_code="BBB-000002",
        description="قطعات خودرو",
        created_at=now - timedelta(days=5),
        status="ARCHIVED",
    )
    newest = factory.shipment(
        company,
        employee,
        tracking_code="CCC-000003",
        description="100% پنبه",
        created_at=now - timedelta(days=1),
        tracking_code_type="AUTO",
    )
    client = factory.login(employee)

    def ids(query: str) -> list[str]:
        response = client.get(f"/shipments?{query}")
        assert response.status_code == 200, response.get_json()
        return [item["id"] for item in response.get_json()["data"]["items"]]

    assert ids("") == [str(newest.id), str(middle.id), str(oldest.id)]  # newest first by default
    assert ids("sort=created_at") == [str(oldest.id), str(middle.id), str(newest.id)]
    assert ids("sort=-tracking_code") == [str(newest.id), str(middle.id), str(oldest.id)]
    assert ids("status=ARCHIVED") == [str(middle.id)]
    assert ids("status=ACTIVE") == [str(newest.id), str(oldest.id)]
    assert ids("tracking_code_type=AUTO") == [str(newest.id)]
    assert ids("tracking_code=bbb-۰۰۰۰۰۲") == [str(middle.id)]  # exact match after normalization
    assert ids("tracking_code=BBB") == []
    assert ids("q=bbb") == [str(middle.id)]  # partial match on the code
    assert ids("q=۰۰۰۰۰۲") == [str(middle.id)]  # a code typed with Persian digits
    assert ids("q=bbb+-+۰۰۰") == [str(middle.id)]  # lower case, Persian digits and stray spaces together
    assert ids("q=خودرو") == [str(middle.id)]  # partial match on the description
    assert ids("q=100%25") == [str(newest.id)]  # LIKE wildcards are literal
    assert ids(f"created_by={colleague.id}") == [str(middle.id)]
    week_ago = (now - timedelta(days=7)).isoformat().replace("+00:00", "Z")
    assert ids(f"created_from={week_ago}") == [str(newest.id), str(middle.id)]
    assert ids(f"created_to={week_ago}") == [str(oldest.id)]
    assert ids("per_page=1&page=2") == [str(middle.id)]

    for bad in ("status=DELETED", "sort=password_hash", "created_from=yesterday", "created_from=2026-01-01T00:00:00"):
        assert client.get(f"/shipments?{bad}").status_code == 422, bad


# --------------------------------------------------------------------------- update
def test_update_description(factory: Factory) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    client = factory.login(employee)
    response = client.patch(f"/shipments/{shipment.id}", json={"description": "توضیح تازه"})
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert data["description"] == "توضیح تازه"
    assert data["tracking_code"] == shipment.tracking_code
    assert factory.audit_actions()[-1] == "SHIPMENT_UPDATED"

    cleared = client.patch(f"/shipments/{shipment.id}", json={"description": None})
    assert cleared.get_json()["data"]["description"] is None


def test_update_cannot_move_a_shipment_or_change_protected_fields(factory: Factory) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    client = factory.login(employee)
    for payload in (
        {"company_id": str(factory.company().id)},
        {"status": "ARCHIVED"},
        {"created_by": str(uuid.uuid4())},
        {"tracking_code_type": "AUTO"},
        {"id": str(uuid.uuid4())},
    ):
        assert client.patch(f"/shipments/{shipment.id}", json=payload).status_code == 422
    unchanged = factory.get(Shipment, shipment.id)
    assert unchanged.company_id == shipment.company_id
    assert unchanged.status.value == "ACTIVE"


def test_shipments_cannot_be_deleted(factory: Factory, admin_api: Api) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    assert admin_api.delete(f"/shipments/{shipment.id}").status_code == 405
    assert factory.count(Shipment) == 1


# --------------------------------------------------------------------------- archive
def test_archive_and_unarchive(factory: Factory, admin_api: Api) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    client = factory.login(employee)

    archived = client.post(f"/shipments/{shipment.id}/archive")
    assert archived.status_code == 200, archived.get_json()
    assert archived.get_json()["data"]["status"] == "ARCHIVED"
    assert factory.audit_actions()[-1] == "SHIPMENT_ARCHIVED"

    again = client.post(f"/shipments/{shipment.id}/archive")
    assert again.status_code == 409
    assert _code(again) == "shipment_archived"

    # Archived shipments are read-only but still visible.
    assert client.get(f"/shipments/{shipment.id}").status_code == 200
    blocked = client.patch(f"/shipments/{shipment.id}", json={"description": "تغییر"})
    assert blocked.status_code == 409
    assert _code(blocked) == "shipment_archived"
    assert client.post(f"/shipments/{shipment.id}/tracking-code", json={"generate": True}).status_code == 409

    # Restoring is reserved for the central administrator.
    assert client.post(f"/shipments/{shipment.id}/unarchive").status_code == 403
    restored = admin_api.post(f"/shipments/{shipment.id}/unarchive")
    assert restored.status_code == 200
    assert restored.get_json()["data"]["status"] == "ACTIVE"
    assert _code(admin_api.post(f"/shipments/{shipment.id}/unarchive")) == "shipment_not_archived"
    assert factory.audit_actions().count("SHIPMENT_UNARCHIVED") == 1


def test_employee_archive_permission_is_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    restricted = make_app(employee_can_archive_shipments=False)
    response = factory.login(employee, app=restricted).post(f"/shipments/{shipment.id}/archive")
    assert response.status_code == 403
    assert response.get_json()["errors"]["required_permissions"] == ["shipment:archive"]
    assert factory.get(Shipment, shipment.id).status.value == "ACTIVE"


# --------------------------------------------------------------------------- tracking code changes
def test_regenerating_the_code_retires_the_old_one(factory: Factory, api: Api) -> None:

    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    old_code = shipment.tracking_code
    client = factory.login(employee)

    response = client.post(f"/shipments/{shipment.id}/tracking-code", json={"generate": True})
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    new_code = data["tracking_code"]
    assert new_code != old_code
    assert re.fullmatch(AUTO_CODE, new_code)
    assert data["tracking_code_type"] == "AUTO"

    assert api.post("/customer/lookup", json={"tracking_code": old_code}).status_code == 404
    assert api.post("/customer/lookup", json={"tracking_code": new_code}).status_code == 200

    history = client.get(f"/shipments/{shipment.id}/tracking-history").get_json()["data"]
    assert [(row["old_code"], row["new_code"]) for row in history["items"]] == [(old_code, new_code), (None, old_code)]
    assert history["items"][0]["changed_by"]["id"] == str(employee.id)
    assert "TRACKING_CODE_CHANGED" in factory.audit_actions()


def test_admin_sets_a_manual_code_through_both_endpoints(factory: Factory, admin_api: Api) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)

    response = admin_api.post(f"/shipments/{shipment.id}/tracking-code", json={"tracking_code": "new-code-0001"})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["tracking_code"] == "NEW-CODE-0001"
    assert response.get_json()["data"]["tracking_code_type"] == "MANUAL"

    patched = admin_api.patch(f"/shipments/{shipment.id}", json={"tracking_code": "NEW-CODE-0002", "description": "x"})
    assert patched.status_code == 200, patched.get_json()
    assert patched.get_json()["data"]["tracking_code"] == "NEW-CODE-0002"
    assert factory.count(TrackingCodeHistory, TrackingCodeHistory.shipment_id == shipment.id) == 3


def test_patch_with_the_current_code_is_a_no_op(factory: Factory, admin_api: Api) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    response = admin_api.patch(f"/shipments/{shipment.id}", json={"tracking_code": shipment.tracking_code.lower()})
    assert response.status_code == 200
    assert factory.count(TrackingCodeHistory, TrackingCodeHistory.shipment_id == shipment.id) == 1


def test_a_retired_code_can_never_be_assigned_again(factory: Factory, admin_api: Api) -> None:
    company = factory.company()
    employee = factory.employee(company)
    shipment = factory.shipment(company, employee, tracking_code="RETIRED-0001")
    other = factory.shipment(company, employee)
    assert admin_api.post(f"/shipments/{shipment.id}/tracking-code", json={"generate": True}).status_code == 200

    for target in (shipment, other):
        response = admin_api.post(f"/shipments/{target.id}/tracking-code", json={"tracking_code": "RETIRED-0001"})
        assert response.status_code == 409
        assert _code(response) == "tracking_code_taken"
    created = admin_api.post("/shipments", json={"company_id": str(company.id), "tracking_code": "retired-0001"})
    assert created.status_code == 409


@pytest.mark.parametrize(
    "payload",
    [{}, {"generate": False}, {"tracking_code": "ABCDEF-1", "generate": True}, {"tracking_code": None}],
)
def test_tracking_code_change_needs_exactly_one_mode(factory: Factory, admin_api: Api, payload: dict[str, Any]) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    response = admin_api.post(f"/shipments/{shipment.id}/tracking-code", json=payload)
    assert response.status_code == 422


def test_changing_to_the_same_code_is_rejected(factory: Factory, admin_api: Api) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    response = admin_api.post(f"/shipments/{shipment.id}/tracking-code", json={"tracking_code": shipment.tracking_code})
    assert response.status_code == 422


def test_employee_code_change_permission_is_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    restricted = make_app(employee_can_change_tracking_code=False)
    response = factory.login(employee, app=restricted).post(
        f"/shipments/{shipment.id}/tracking-code", json={"generate": True}
    )
    assert response.status_code == 403
    assert factory.get(Shipment, shipment.id).tracking_code == shipment.tracking_code


def test_employee_cannot_set_a_manual_code_on_change_by_default(factory: Factory) -> None:
    employee = factory.employee()
    shipment = factory.shipment(factory.company_of(employee), employee)
    client = factory.login(employee)
    for response in (
        client.post(f"/shipments/{shipment.id}/tracking-code", json={"tracking_code": "MY-OWN-CODE-1"}),
        client.patch(f"/shipments/{shipment.id}", json={"tracking_code": "MY-OWN-CODE-1"}),
    ):
        assert response.status_code == 403
        assert _code(response) == "manual_tracking_code_not_allowed"
    assert factory.get(Shipment, shipment.id).tracking_code == shipment.tracking_code


def test_generation_retries_after_a_collision(factory: Factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """A generated code that turns out to be taken at INSERT time is replaced transparently."""
    employee = factory.employee()
    existing = factory.shipment(factory.company_of(employee), employee)
    generated = iter([existing.tracking_code, "FRSH-0000-0000-0001"])
    monkeypatch.setattr(TrackingCodeGenerator, "generate", lambda self: next(generated))

    real_check = ShipmentRepository.code_ever_used
    calls = {"count": 0}

    def racing_check(self: ShipmentRepository, code: str) -> bool:
        calls["count"] += 1
        if calls["count"] == 1:
            return False  # simulate the race window: the pre-check passes, the INSERT collides
        return real_check(self, code)

    monkeypatch.setattr(ShipmentRepository, "code_ever_used", racing_check)

    response = factory.login(employee).post("/shipments", json={"description": "پس از برخورد"})
    assert response.status_code == 201, response.get_json()
    assert response.get_json()["data"]["tracking_code"] == "FRSH-0000-0000-0001"
    assert factory.count(Shipment) == 2
    assert factory.count(TrackingCodeHistory) == 2


def test_generation_gives_up_after_bounded_attempts(factory: Factory, monkeypatch: pytest.MonkeyPatch) -> None:
    employee = factory.employee()
    existing = factory.shipment(factory.company_of(employee), employee)
    monkeypatch.setattr(TrackingCodeGenerator, "generate", lambda self: existing.tracking_code)
    response = factory.login(employee).post("/shipments", json={})
    assert response.status_code == 503
    assert _code(response) == "tracking_code_generation_failed"
    assert factory.count(Shipment) == 1


@pytest.mark.mysql
def test_concurrent_requests_cannot_claim_the_same_code(factory: Factory, app: Flask) -> None:
    company = factory.company()
    admin = factory.admin()
    token = factory.tokens(admin).access_token
    workers = 8
    barrier = threading.Barrier(workers)
    statuses: list[int] = []
    lock = threading.Lock()

    def worker() -> None:
        client = Api(app, token)
        barrier.wait()
        response = client.post("/shipments", json={"company_id": str(company.id), "tracking_code": "RACE-CODE-0001"})
        with lock:
            statuses.append(response.status_code)

    threads = [threading.Thread(target=worker) for _ in range(workers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert sorted(statuses) == [201] + [409] * (workers - 1)
    assert factory.count(Shipment) == 1
    assert factory.count(TrackingCodeHistory) == 1
