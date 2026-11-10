"""Authorization: every route is authenticated and permission-checked on the server."""

from __future__ import annotations

import re
import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass

import pytest
from flask import Flask
from werkzeug.routing import Rule

from app.config import Settings
from app.core.api import ENDPOINT_SPEC_ATTRIBUTE, EndpointSpec
from app.core.permissions import Permission, permissions_for_role
from app.extensions import db
from app.models import User, UserRole
from tests.support import Api, Factory

UNDOCUMENTED_ENDPOINTS = {"docs.openapi_document"}  # serves the specification itself
PUBLIC_OPERATIONS = {
    ("GET", "/api/v1/health"),
    ("GET", "/api/v1/health/ready"),
    ("GET", "/api/v1/openapi.json"),
    ("POST", "/api/v1/auth/login"),
    ("POST", "/api/v1/auth/refresh"),
    ("POST", "/api/v1/customer/lookup"),
    ("GET", "/api/v1/customer/access/<string:token>/shipment"),
    ("GET", "/api/v1/customer/access/<string:token>/documents"),
    ("GET", "/api/v1/customer/access/<string:token>/documents/<uuid:document_id>/download"),
    ("POST", "/api/v1/customer/access/<string:token>/revoke"),
}
# Operations an EMPLOYEE must never be able to perform under the default configuration.
ADMIN_ONLY_OPERATIONS = {
    ("GET", "/api/v1/companies"),
    ("POST", "/api/v1/companies"),
    ("GET", "/api/v1/companies/<uuid:company_id>"),
    ("PATCH", "/api/v1/companies/<uuid:company_id>"),
    ("GET", "/api/v1/users"),
    ("POST", "/api/v1/users"),
    ("GET", "/api/v1/users/<uuid:user_id>"),
    ("PATCH", "/api/v1/users/<uuid:user_id>"),
    ("POST", "/api/v1/users/<uuid:user_id>/reset-password"),
    ("POST", "/api/v1/product-fields"),
    ("PATCH", "/api/v1/product-fields/<uuid:field_id>"),
    ("POST", "/api/v1/shipments/<uuid:shipment_id>/unarchive"),
    ("DELETE", "/api/v1/documents/<uuid:document_id>"),
    ("GET", "/api/v1/audit-logs"),
}


@dataclass(frozen=True)
class Operation:
    method: str
    rule: str
    url: str
    spec: EndpointSpec | None
    endpoint: str


def _concrete_url(rule: Rule) -> str:
    def replace(match: re.Match[str]) -> str:
        converter = match.group(1)
        return str(uuid.uuid4()) if converter == "uuid" else "x" * 43

    return re.sub(r"<(?:([^:<>]+):)?[^<>]+>", replace, rule.rule)


def _operations(app: Flask) -> Iterator[Operation]:
    for rule in app.url_map.iter_rules():
        if not rule.rule.startswith("/api/"):
            continue
        view = app.view_functions[rule.endpoint]
        spec: EndpointSpec | None = getattr(view, ENDPOINT_SPEC_ATTRIBUTE, None)
        for method in sorted((rule.methods or set()) - {"HEAD", "OPTIONS"}):
            yield Operation(method, rule.rule, _concrete_url(rule), spec, rule.endpoint)


def _call(client: Api, operation: Operation) -> int:
    kwargs = {"json": {}} if operation.method in {"POST", "PATCH", "PUT"} else {}
    return client._open(operation.method, operation.url, **kwargs).status_code


def test_every_api_route_is_declared_through_the_endpoint_decorator(app: Flask) -> None:
    undeclared = {op.endpoint for op in _operations(app) if op.spec is None}
    assert undeclared == UNDOCUMENTED_ENDPOINTS


def test_the_set_of_public_operations_is_exactly_the_intended_one(app: Flask) -> None:
    """Adding an unauthenticated route must be a conscious decision that updates this list."""
    public = {(op.method, op.rule) for op in _operations(app) if op.spec is None or op.spec.auth != "bearer"}
    assert public == PUBLIC_OPERATIONS


def test_anonymous_requests_are_rejected_on_every_protected_route(app: Flask, api: Api) -> None:
    protected = [op for op in _operations(app) if op.spec is not None and op.spec.auth == "bearer"]
    assert len(protected) >= 30
    for operation in protected:
        response = api._open(operation.method, operation.url, json={} if operation.method != "GET" else None)
        assert response.status_code == 401, f"{operation.method} {operation.rule}"
        assert response.get_json()["errors"]["code"] == "authentication_required"


def test_every_protected_route_declares_permissions_or_is_self_service(app: Flask) -> None:
    self_service = {"auth.me", "auth.logout", "auth.change_password"}
    without_permissions = {
        op.endpoint
        for op in _operations(app)
        if op.spec is not None and op.spec.auth == "bearer" and not op.spec.permissions
    }
    assert without_permissions == self_service


def test_employee_is_denied_exactly_the_admin_only_operations(app: Flask, factory: Factory, settings: Settings) -> None:
    client = factory.login(factory.employee())
    employee_permissions = permissions_for_role(UserRole.EMPLOYEE, settings)
    denied: set[tuple[str, str]] = set()
    for operation in _operations(app):
        # Logging out would end the session this very loop depends on.
        if operation.spec is None or operation.spec.auth != "bearer" or operation.endpoint == "auth.logout":
            continue
        status = _call(client, operation)
        assert status != 401, f"{operation.method} {operation.rule}"
        expected_denial = not set(operation.spec.permissions) <= employee_permissions
        if status == 403:
            denied.add((operation.method, operation.rule))
        assert (status == 403) == expected_denial, f"{operation.method} {operation.rule} -> {status}"
    assert denied == ADMIN_ONLY_OPERATIONS


def test_denied_requests_report_the_missing_permission_and_are_audited(factory: Factory) -> None:
    employee = factory.employee()
    client = factory.login(employee)
    response = client.post("/companies", json={"name": "شرکت جعلی", "company_code": "FAKE"})
    assert response.status_code == 403
    body = response.get_json()
    assert body["success"] is False
    assert body["errors"]["code"] == "permission_denied"
    assert body["errors"]["required_permissions"] == ["company:create"]
    assert factory.audit_actions()[-1] == "ACCESS_DENIED"


def test_permission_check_happens_before_input_validation(factory: Factory) -> None:
    """A caller without permission learns nothing about the expected payload."""
    client = factory.login(factory.employee())
    assert client.post("/companies", json={"nonsense": True}).status_code == 403
    assert client.post("/users", data="{broken", content_type="application/json").status_code == 403


def test_super_admin_holds_every_permission(settings: Settings) -> None:
    assert permissions_for_role(UserRole.SUPER_ADMIN, settings) == frozenset(Permission)


def test_admin_is_never_denied(app: Flask, factory: Factory) -> None:
    client = factory.login(factory.admin())
    for operation in _operations(app):
        if operation.spec is None or operation.spec.auth != "bearer" or operation.endpoint == "auth.logout":
            continue
        assert _call(client, operation) not in {401, 403}, f"{operation.method} {operation.rule}"


def test_employee_permissions_follow_the_business_rule_settings(
    factory: Factory, make_app: Callable[..., Flask]
) -> None:
    employee = factory.employee()
    default = set(factory.login(employee).get("/auth/me").get_json()["data"]["permissions"])
    assert "tracking_code:change" in default and "shipment:archive" in default
    assert not {"tracking_code:manual", "document:delete", "shipment:unarchive", "scope:global"} & default

    flipped = make_app(
        employee_can_use_manual_tracking_code=True,
        employee_can_delete_documents=True,
        employee_can_change_tracking_code=False,
        employee_can_archive_shipments=False,
    )
    changed = set(factory.login(employee, app=flipped).get("/auth/me").get_json()["data"]["permissions"])
    assert {"tracking_code:manual", "document:delete"} <= changed
    assert not {"tracking_code:change", "shipment:archive", "scope:global", "company:create"} & changed


def test_role_is_read_from_the_database_not_from_the_token(factory: Factory, app: Flask) -> None:
    """Demoting an account takes effect on the very next request of an existing session."""

    company = factory.company()
    admin = factory.admin()
    client = factory.login(admin)
    assert client.get("/companies").status_code == 200
    with app.app_context():
        db.session.execute(
            db.update(User).where(User.id == admin.id).values(role=UserRole.EMPLOYEE, company_id=company.id)
        )
        db.session.commit()
        db.session.remove()
    assert client.get("/companies").status_code == 403
    assert client.get("/auth/me").get_json()["data"]["user"]["role"] == "EMPLOYEE"


@pytest.mark.parametrize("method", ["PUT", "DELETE", "PATCH"])
def test_unsupported_methods_return_405_in_the_common_envelope(api: Api, method: str) -> None:
    response = api._open(method, "/auth/login", json={})
    assert response.status_code == 405
    assert response.get_json() == {
        "success": False,
        "message": response.get_json()["message"],
        "data": None,
        "errors": {"code": "method_not_allowed", "request_id": response.headers["X-Request-ID"]},
    }
