"""Customer portal: tracking-code lookup and token-scoped access to one shipment."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from flask import Flask

from app.config import RateLimitRule
from app.core.datetime_utils import utcnow
from app.core.http import mask_sensitive_path
from app.core.security import hash_token
from app.extensions import db
from app.models import AuditLog, Company, CustomerAccessSession, Document, Shipment, User
from tests.support import PDF_BYTES, Api, Factory

NOT_FOUND = "tracking_code_not_found"
SESSION_INVALID = "customer_session_invalid"


class Portal:
    """A shipment with documents plus helpers to act as its customer."""

    def __init__(self, factory: Factory, app: Flask, code: str = "CUST-2026-0001") -> None:
        self.factory = factory
        self.company: Company = factory.company(name="حمل‌ونقل مشتری‌مدار")
        self.employee: User = factory.employee(self.company)
        self.shipment: Shipment = factory.shipment(
            self.company, self.employee, tracking_code=code, description="یادداشت داخلی کارمند"
        )
        self.visible: Document = factory.document(self.shipment, self.employee, original_name="بارنامه.pdf")
        self.hidden: Document = factory.document(
            self.shipment, self.employee, original_name="internal.pdf", is_customer_visible=False
        )
        self.deleted: Document = factory.document(
            self.shipment,
            self.employee,
            original_name="deleted.pdf",
            deleted_at=utcnow(),
            deleted_by=self.employee.id,
        )
        self.public = Api(app)

    def token(self, client: Api | None = None) -> str:
        response = (client or self.public).post("/customer/lookup", json={"tracking_code": self.shipment.tracking_code})
        assert response.status_code == 200, response.get_json()
        result: str = response.get_json()["data"]["access_token"]
        return result


@pytest.fixture
def portal(factory: Factory, app: Flask) -> Portal:
    return Portal(factory, app)


def _code(response: Any) -> str:
    result: str = response.get_json()["errors"]["code"]
    return result


# --------------------------------------------------------------------------- lookup
def test_lookup_issues_a_short_lived_token(portal: Portal, app: Flask) -> None:
    response = portal.public.post("/customer/lookup", json={"tracking_code": "CUST-2026-0001"})
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert set(data) == {"access_token", "expires_at", "expires_in"}
    assert data["expires_in"] == 1800
    assert len(data["access_token"]) >= 43
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Referrer-Policy"] == "no-referrer"

    with app.app_context():
        session = db.session.scalars(db.select(CustomerAccessSession)).one()
        assert session.token_hash == hash_token(data["access_token"])
        assert data["access_token"] not in (session.token_hash, session.tracking_code)
        assert session.shipment_id == portal.shipment.id
        assert session.tracking_code == "CUST-2026-0001"
        assert session.revoked_at is None and session.last_used_at is None
        db.session.remove()


@pytest.mark.parametrize(
    "typed",
    [
        "cust-2026-0001",
        "  CUST-2026-0001  ",
        "Cust 2026 0001".replace(" ", "-"),
        "CUST-۲۰۲۶-۰۰۰۱",
        "cust-2026-\u200c0001",
        "CUST–2026–0001",
    ],
)
def test_lookup_normalizes_what_the_customer_typed(portal: Portal, typed: str) -> None:
    assert portal.public.post("/customer/lookup", json={"tracking_code": typed}).status_code == 200


@pytest.mark.parametrize(
    "guess",
    [
        "CUST-2026-0002",
        "CUST-2026-000",
        "CUST20260001",  # separators are significant
        "UNKNOWN-CODE-1",
        "x",
        "A" * 64,
        "A" * 200,
        "' OR '1'='1",
        "CUST-2026-0001' --",
        "CUST-2026-0001%",
        "CUST-2026-000_",
        "%",
        "../../etc/passwd",
        "<script>alert(1)</script>",
        "CUST-2026-0001\x00",
        "😀😀😀😀😀😀",
    ],
)
def test_wrong_codes_get_one_generic_answer(portal: Portal, guess: str) -> None:
    response = portal.public.post("/customer/lookup", json={"tracking_code": guess})
    assert response.status_code == 404, response.get_json()
    body = response.get_json()
    assert body["success"] is False and body["data"] is None
    assert body["errors"]["code"] == NOT_FOUND
    assert guess not in response.get_data(as_text=True)  # the input is never echoed back


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"tracking_code": ""},
        {"tracking_code": "   "},
        {"tracking_code": None},
        {"tracking_code": 12345},
        {"tracking_code": "A" * 201},
        {"code": "CUST-2026-0001"},
    ],
)
def test_lookup_validation(portal: Portal, payload: dict[str, Any]) -> None:
    response = portal.public.post("/customer/lookup", json=payload)
    assert response.status_code == 422
    assert response.get_json()["errors"]["code"] == "validation_error"


def test_lookup_only_accepts_post_with_json(portal: Portal) -> None:
    assert portal.public.get("/customer/lookup?tracking_code=CUST-2026-0001").status_code == 405
    form = portal.public.post("/customer/lookup", data={"tracking_code": "CUST-2026-0001"})
    assert form.status_code == 415


def test_every_unavailable_shipment_looks_exactly_like_an_unknown_code(
    portal: Portal, factory: Factory, app: Flask
) -> None:
    """Archived, retired and inactive-company codes must be indistinguishable from random guesses."""
    employee = portal.employee
    archived = factory.shipment(portal.company, employee, tracking_code="ARCHIVED-0001", status="ARCHIVED")
    inactive_company = factory.company(is_active=False)
    factory.shipment(inactive_company, factory.employee(inactive_company), tracking_code="INACTIVE-0001")
    retired = factory.shipment(portal.company, employee, tracking_code="RETIRED-0001")
    admin_api = factory.login(factory.admin())
    assert admin_api.post(f"/shipments/{retired.id}/tracking-code", json={"generate": True}).status_code == 200

    def answer(code: str) -> tuple[int, dict[str, Any]]:
        response = portal.public.post("/customer/lookup", json={"tracking_code": code})
        body = response.get_json()
        body["errors"].pop("request_id", None)
        return response.status_code, body

    baseline = answer("NEVER-EXISTED-1")
    assert baseline[0] == 404
    for code in (archived.tracking_code, "INACTIVE-0001", "RETIRED-0001"):
        assert answer(code) == baseline, code


def test_archived_shipments_can_be_opened_to_customers_by_configuration(
    factory: Factory, make_app: Callable[..., Flask]
) -> None:
    permissive = make_app(customer_allow_archived_shipments=True)
    portal = Portal(factory, permissive)
    factory.login(portal.employee, app=permissive).post(f"/shipments/{portal.shipment.id}/archive")
    token = portal.token()
    summary = portal.public.get(f"/customer/access/{token}/shipment")
    assert summary.status_code == 200
    assert summary.get_json()["data"]["status"] == "ARCHIVED"


def test_lookup_attempts_are_audited_without_storing_guessed_codes(portal: Portal, app: Flask) -> None:
    portal.public.post("/customer/lookup", json={"tracking_code": "SECRET-GUESS-9"})
    portal.token()
    with app.app_context():
        failed, succeeded = db.session.scalars(
            db.select(AuditLog).where(AuditLog.action.like("CUSTOMER_LOOKUP%")).order_by(AuditLog.created_at)
        ).all()
        assert failed.action == "CUSTOMER_LOOKUP_FAILED"
        assert failed.user_id is None and failed.entity_id is None
        assert set(failed.meta) == {"code_fingerprint"}
        assert "SECRET-GUESS-9" not in str(failed.meta)
        assert failed.ip_address == "127.0.0.1"
        assert succeeded.action == "CUSTOMER_LOOKUP_SUCCESS"
        assert succeeded.entity_id == str(portal.shipment.id)
        db.session.remove()


# --------------------------------------------------------------------------- shipment summary
def test_summary_shows_only_customer_safe_information(portal: Portal, factory: Factory) -> None:
    weight = factory.field(
        field_key="weight", label="وزن", data_type="DECIMAL", is_customer_visible=True, display_order=1
    )
    factory.field(field_key="cost", label="هزینهٔ داخلی", data_type="NUMBER", is_customer_visible=False, display_order=2)
    factory.field(field_key="empty", label="بدون مقدار", is_customer_visible=True, display_order=3)
    employee_api = factory.login(portal.employee)
    saved = employee_api.put(
        f"/shipments/{portal.shipment.id}/product-values", json={"values": {"weight": "12.500", "cost": 990000}}
    )
    assert saved.status_code == 200, saved.get_json()

    response = portal.public.get(f"/customer/access/{portal.token()}/shipment")
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert data == {
        "tracking_code": "CUST-2026-0001",
        "status": "ACTIVE",
        "company_name": "حمل‌ونقل مشتری‌مدار",
        "description": None,  # internal notes are hidden unless explicitly enabled
        "registered_at": data["registered_at"],
        "document_count": 1,
        "product_details": [{"label": "وزن", "data_type": "DECIMAL", "value": "12.5"}],
        "session_expires_at": data["session_expires_at"],
    }
    raw = response.get_data(as_text=True)
    for internal in (
        str(portal.shipment.id),
        str(portal.company.id),
        str(portal.employee.id),
        portal.employee.username,
        portal.employee.full_name,
        str(weight.id),
        "یادداشت داخلی",
        "990000",
        "هزینهٔ داخلی",
    ):
        assert internal not in raw


def test_summary_details_are_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    configured = make_app(customer_show_company_name=False, customer_show_description=True)
    portal = Portal(factory, configured)
    data = portal.public.get(f"/customer/access/{portal.token()}/shipment").get_json()["data"]
    assert data["company_name"] is None
    assert data["description"] == "یادداشت داخلی کارمند"


def test_session_use_is_recorded(portal: Portal, app: Flask) -> None:
    token = portal.token()
    portal.public.get(f"/customer/access/{token}/shipment")
    with app.app_context():
        session = db.session.scalars(db.select(CustomerAccessSession)).one()
        assert session.last_used_at is not None
        db.session.remove()


# --------------------------------------------------------------------------- documents
def test_customer_sees_only_visible_documents_of_the_shipment(portal: Portal, factory: Factory) -> None:
    sibling = factory.shipment(portal.company, portal.employee)
    factory.document(sibling, portal.employee, original_name="other-shipment.pdf")

    response = portal.public.get(f"/customer/access/{portal.token()}/documents")
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert data["pagination"]["total"] == 1
    (item,) = data["items"]
    assert item == {
        "id": str(portal.visible.id),
        "name": "بارنامه.pdf",
        "mime_type": "application/pdf",
        "extension": "pdf",
        "file_size": len(PDF_BYTES),
        "uploaded_at": item["uploaded_at"],
    }
    raw = response.get_data(as_text=True)
    assert portal.visible.storage_name not in raw
    assert portal.visible.checksum not in raw
    assert "internal.pdf" not in raw and "deleted.pdf" not in raw and "other-shipment.pdf" not in raw


def test_customer_downloads_a_visible_document(portal: Portal, factory: Factory) -> None:
    response = portal.public.get(f"/customer/access/{portal.token()}/documents/{portal.visible.id}/download")
    assert response.status_code == 200
    assert response.data == PDF_BYTES
    assert response.headers["Content-Disposition"].startswith("attachment;")
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Cache-Control"] == "private, no-store"
    assert factory.audit_actions()[-1] == "CUSTOMER_DOCUMENT_DOWNLOADED"


def test_customer_cannot_download_anything_else(portal: Portal, factory: Factory, app: Flask) -> None:
    """Knowing (or guessing) a document id is never enough: it must belong to the session's shipment."""
    sibling = factory.shipment(portal.company, portal.employee, tracking_code="SIBLING-0001")
    sibling_document = factory.document(sibling, portal.employee)
    stranger = Portal(factory, app, code="STRANGER-0001")
    token = portal.token()

    targets = {
        "hidden": portal.hidden.id,
        "deleted": portal.deleted.id,
        "same company, other shipment": sibling_document.id,
        "other company": stranger.visible.id,
        "unknown": uuid.uuid4(),
    }
    for label, document_id in targets.items():
        response = portal.public.get(f"/customer/access/{token}/documents/{document_id}/download")
        assert response.status_code == 404, label
        assert _code(response) == "document_not_found", label
        assert PDF_BYTES not in response.data, label
    assert "CUSTOMER_DOCUMENT_DOWNLOADED" not in factory.audit_actions()

    # The reverse direction is closed as well.
    stranger_token = stranger.token()
    assert (
        stranger.public.get(f"/customer/access/{stranger_token}/documents/{portal.visible.id}/download").status_code
        == 404
    )


def test_hiding_a_document_takes_effect_immediately(portal: Portal, factory: Factory) -> None:
    token = portal.token()
    url = f"/customer/access/{token}/documents/{portal.visible.id}/download"
    assert portal.public.get(url).status_code == 200
    factory.login(portal.employee).patch(f"/documents/{portal.visible.id}", json={"is_customer_visible": False})
    assert portal.public.get(url).status_code == 404
    assert portal.public.get(f"/customer/access/{token}/documents").get_json()["data"]["items"] == []


def test_customers_have_no_listing_search_or_write_endpoints(portal: Portal) -> None:
    token = portal.token()
    assert portal.public.get("/customer/shipments").status_code == 404
    assert portal.public.get("/customer/access").status_code == 404
    assert portal.public.get(f"/customer/access/{token}").status_code == 404
    assert portal.public.delete(f"/customer/access/{token}/documents/{portal.visible.id}").status_code == 404
    assert portal.public.post(f"/customer/access/{token}/documents").status_code == 405
    assert portal.public.patch(f"/customer/access/{token}/shipment", json={}).status_code == 405


# --------------------------------------------------------------------------- session lifetime
def _all_endpoints(portal: Portal, token: str) -> list[Any]:
    return [
        portal.public.get(f"/customer/access/{token}/shipment"),
        portal.public.get(f"/customer/access/{token}/documents"),
        portal.public.get(f"/customer/access/{token}/documents/{portal.visible.id}/download"),
        portal.public.post(f"/customer/access/{token}/revoke"),
    ]


def _assert_session_dead(portal: Portal, token: str) -> None:
    for response in _all_endpoints(portal, token):
        assert response.status_code == 401
        assert _code(response) == SESSION_INVALID
        assert PDF_BYTES not in response.data


def test_expired_session_is_rejected(portal: Portal, factory: Factory) -> None:
    token = portal.token()
    factory.expire_all(CustomerAccessSession, "expires_at")
    _assert_session_dead(portal, token)


def test_session_lifetime_is_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    short = make_app(customer_session_ttl_seconds=60)
    portal = Portal(factory, short)
    response = portal.public.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code})
    assert response.get_json()["data"]["expires_in"] == 60


def test_customer_can_end_the_session(portal: Portal) -> None:
    token = portal.token()
    assert portal.public.post(f"/customer/access/{token}/revoke").status_code == 200
    _assert_session_dead(portal, token)
    # Another session for the same shipment is unaffected.
    assert portal.public.get(f"/customer/access/{portal.token()}/shipment").status_code == 200


def test_changing_the_tracking_code_ends_existing_sessions(portal: Portal, factory: Factory) -> None:
    token = portal.token()
    response = factory.login(portal.employee).post(
        f"/shipments/{portal.shipment.id}/tracking-code", json={"generate": True}
    )
    assert response.status_code == 200
    _assert_session_dead(portal, token)
    assert portal.public.post("/customer/lookup", json={"tracking_code": "CUST-2026-0001"}).status_code == 404


def test_archiving_ends_existing_sessions(portal: Portal, factory: Factory) -> None:
    token = portal.token()
    factory.login(portal.employee).post(f"/shipments/{portal.shipment.id}/archive")
    _assert_session_dead(portal, token)


def test_deactivating_the_company_ends_existing_sessions(portal: Portal, factory: Factory) -> None:
    token = portal.token()
    factory.login(factory.admin()).patch(f"/companies/{portal.company.id}", json={"is_active": False})
    _assert_session_dead(portal, token)


def test_staff_can_revoke_all_customer_sessions_of_a_shipment(portal: Portal, factory: Factory) -> None:
    first, second = portal.token(), portal.token()
    response = factory.login(portal.employee).post(f"/shipments/{portal.shipment.id}/customer-sessions/revoke")
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"] == {"revoked": 2}
    _assert_session_dead(portal, first)
    _assert_session_dead(portal, second)
    assert factory.audit_actions()[-1] == "CUSTOMER_SESSIONS_REVOKED"


def test_a_stale_code_snapshot_invalidates_the_session(portal: Portal, app: Flask) -> None:
    """Even if a session row survived a code change, it stops working (defence in depth)."""
    token = portal.token()
    with app.app_context():
        db.session.execute(
            db.update(Shipment).where(Shipment.id == portal.shipment.id).values(tracking_code="CHANGED-DIRECTLY")
        )
        db.session.commit()
        db.session.remove()
    _assert_session_dead(portal, token)


@pytest.mark.parametrize(
    "token",
    [
        "short",
        "a" * 31,
        "a" * 43,
        "a" * 129,
        "not.a.valid.token.with.dots.in.it.padpadpadpad",
        "../../../../etc/passwd-aaaaaaaaaaaaaaaaaaaaaaaa",
        "%2e%2e%2f%2e%2e%2f-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "' OR 1=1 -- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ],
)
def test_malformed_or_unknown_tokens_get_the_same_answer(portal: Portal, token: str) -> None:
    response = portal.public.get(f"/customer/access/{token}/shipment")
    assert response.status_code in {401, 404}  # 404 only when the path itself cannot match the route
    if response.status_code == 401:
        assert _code(response) == SESSION_INVALID


def test_staff_and_customer_credentials_are_not_interchangeable(portal: Portal, factory: Factory) -> None:
    customer_token = portal.token()
    staff = factory.tokens(portal.employee)

    as_staff = Api(portal.public._app, customer_token)
    assert as_staff.get("/shipments").status_code == 401
    assert as_staff.get(f"/documents/{portal.hidden.id}/download").status_code == 401

    for token in (staff.access_token, staff.refresh_token):
        response = portal.public.get(f"/customer/access/{token}/shipment")
        assert response.status_code == 401
        assert _code(response) == SESSION_INVALID


def test_customer_token_is_masked_in_logs_and_audit_paths() -> None:
    path = "/api/v1/customer/access/SuperSecretToken_123-abc/documents/9d1c/download"
    masked = mask_sensitive_path(path)
    assert "SuperSecretToken" not in masked
    assert masked == "/api/v1/customer/access/[redacted]/documents/9d1c/download"
    assert mask_sensitive_path("/api/v1/shipments/123") == "/api/v1/shipments/123"


def test_access_log_never_contains_the_raw_token(portal: Portal, caplog: pytest.LogCaptureFixture) -> None:
    token = portal.token()
    with caplog.at_level("INFO"):
        portal.public.get(f"/customer/access/{token}/shipment")
        portal.public.get(f"/customer/access/{token}/documents/{portal.visible.id}/download")
    assert caplog.records
    for record in caplog.records:
        assert token not in record.getMessage()
        assert token not in str(record.__dict__)


# --------------------------------------------------------------------------- rate limiting
def test_lookup_is_rate_limited_per_address(factory: Factory, make_app: Callable[..., Flask]) -> None:
    limited = make_app(rate_limit_customer_lookup_ip=RateLimitRule(limit=3, window_seconds=60))
    portal = Portal(factory, limited)
    client = Api(limited, ip="203.0.113.10")
    for _ in range(3):
        assert client.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code}).status_code == 200
    blocked = client.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code})
    assert blocked.status_code == 429
    assert _code(blocked) == "rate_limited"
    assert int(blocked.headers["Retry-After"]) >= 1
    other = Api(limited, ip="203.0.113.11")
    assert other.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code}).status_code == 200


def test_repeated_wrong_guesses_block_further_lookups(factory: Factory, make_app: Callable[..., Flask]) -> None:
    limited = make_app(rate_limit_customer_lookup_failures_ip=RateLimitRule(limit=3, window_seconds=3600))
    portal = Portal(factory, limited)
    attacker = Api(limited, ip="203.0.113.20")
    for index in range(3):
        assert attacker.post("/customer/lookup", json={"tracking_code": f"GUESS-{index:06d}"}).status_code == 404
    # Once the budget of failures is used up, even a correct code is refused for this address.
    blocked = attacker.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code})
    assert blocked.status_code == 429
    honest = Api(limited, ip="203.0.113.21")
    assert honest.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code}).status_code == 200


def test_successful_lookups_do_not_consume_the_failure_budget(factory: Factory, make_app: Callable[..., Flask]) -> None:
    limited = make_app(rate_limit_customer_lookup_failures_ip=RateLimitRule(limit=2, window_seconds=3600))
    portal = Portal(factory, limited)
    client = Api(limited, ip="203.0.113.30")
    for _ in range(5):
        assert client.post("/customer/lookup", json={"tracking_code": portal.shipment.tracking_code}).status_code == 200


def test_token_endpoints_are_rate_limited_per_address(factory: Factory, make_app: Callable[..., Flask]) -> None:
    limited = make_app(rate_limit_customer_access_ip=RateLimitRule(limit=4, window_seconds=60))
    portal = Portal(factory, limited)
    token = portal.token()
    client = Api(limited, ip="203.0.113.40")
    statuses = [client.get(f"/customer/access/{'x' * 43}/shipment").status_code for _ in range(4)]
    assert statuses == [401, 401, 401, 401]
    # Token guessing is throttled; the limit applies before the token is even examined.
    assert client.get(f"/customer/access/{token}/shipment").status_code == 429
    assert Api(limited, ip="203.0.113.41").get(f"/customer/access/{token}/shipment").status_code == 200


def test_maintenance_purge_removes_only_long_expired_sessions(portal: Portal, app: Flask) -> None:

    portal.token()
    portal.token()
    with app.app_context():
        first = db.session.scalars(db.select(CustomerAccessSession)).first()
        assert first is not None
        first.expires_at = utcnow() - timedelta(days=45)
        db.session.commit()
        removed = app.extensions["services"].customer_access.purge_expired()
        remaining = db.session.scalar(db.select(db.func.count()).select_from(CustomerAccessSession))
        db.session.remove()
    assert removed == 1
    assert remaining == 1
