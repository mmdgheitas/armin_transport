"""The OpenAPI document is valid, complete, and matches what the API really returns."""

from __future__ import annotations

import copy
import json
import re
from typing import Any

import pytest
from flask import Flask
from openapi_schema_validator import OAS30Validator, oas30_format_checker
from openapi_spec_validator import validate
from werkzeug.test import TestResponse

from app.core.api import ENDPOINT_SPEC_ATTRIBUTE, EndpointSpec
from app.core.openapi import build_openapi_document
from tests.support import DEFAULT_PASSWORD, PDF_BYTES, PNG_BYTES, Api, Factory, upload_file

_PATH_PARAMETER = re.compile(r"<(?:[^:<>]+:)?([^<>]+)>")
_REF_PREFIX = "#/components/schemas/"


def _template(rule: str) -> str:
    return _PATH_PARAMETER.sub(r"{\1}", rule)


@pytest.fixture(scope="module")
def document(app: Flask) -> dict[str, Any]:
    response = app.test_client().get("/api/v1/openapi.json")
    assert response.status_code == 200
    result: dict[str, Any] = response.get_json()
    return result


def _declared_operations(app: Flask) -> dict[tuple[str, str], EndpointSpec]:
    operations: dict[tuple[str, str], EndpointSpec] = {}
    for rule in app.url_map.iter_rules():
        spec: EndpointSpec | None = getattr(app.view_functions[rule.endpoint], ENDPOINT_SPEC_ATTRIBUTE, None)
        if spec is None:
            continue
        for method in (rule.methods or set()) - {"HEAD", "OPTIONS"}:
            operations[method.lower(), _template(rule.rule)] = spec
    return operations


# --------------------------------------------------------------------------- the document itself
def test_document_is_a_valid_openapi_3_specification(document: dict[str, Any]) -> None:
    validate(document)
    assert document["openapi"].startswith("3.0")
    assert document["info"]["title"] == "Armin Transport API"
    assert document["components"]["securitySchemes"]["bearerAuth"] == {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "JWT",
    }


def test_document_is_public_and_cacheable_as_json(app: Flask) -> None:
    response = app.test_client().get("/api/v1/openapi.json")
    assert response.mimetype == "application/json"
    assert "ورود" in response.get_data(as_text=True)  # Persian text is emitted as UTF-8, not \\u escapes


def test_every_route_is_documented_and_nothing_else(app: Flask, document: dict[str, Any]) -> None:
    documented = {(method, path) for path, operations in document["paths"].items() for method in operations}
    assert documented == set(_declared_operations(app))
    assert len(documented) == 43


def test_security_requirements_mirror_the_enforced_authentication(app: Flask, document: dict[str, Any]) -> None:
    for (method, path), spec in _declared_operations(app).items():
        operation = document["paths"][path][method]
        expected = [{"bearerAuth": []}] if spec.auth == "bearer" else []
        assert operation["security"] == expected, f"{method} {path}"
        for permission in spec.permissions:
            assert f"`{permission.value}`" in operation["description"], f"{method} {path}"
        if spec.auth == "bearer":
            assert {"401", "403"} <= set(operation["responses"]), f"{method} {path}"


def test_operations_are_uniquely_identified_and_described(document: dict[str, Any]) -> None:
    tags = {tag["name"] for tag in document["tags"]}
    identifiers: list[str] = []
    for path, operations in document["paths"].items():
        for method, operation in operations.items():
            identifiers.append(operation["operationId"])
            assert operation["summary"], f"{method} {path}"
            assert set(operation["tags"]) <= tags, f"{method} {path}"
            success = [status for status in operation["responses"] if status.startswith("2")]
            assert len(success) == 1, f"{method} {path}"
            declared = {parameter["name"] for parameter in operation.get("parameters", []) if parameter["in"] == "path"}
            assert declared == set(re.findall(r"{([^}]+)}", path)), f"{method} {path}"
    assert len(identifiers) == len(set(identifiers))


def test_upload_is_documented_as_multipart(document: dict[str, Any]) -> None:
    body = document["paths"]["/api/v1/shipments/{shipment_id}/documents"]["post"]["requestBody"]
    schema = body["content"]["multipart/form-data"]["schema"]
    assert schema["required"] == ["files"]
    assert schema["properties"]["files"] == {
        "type": "array",
        "items": {"type": "string", "format": "binary"},
        "description": schema["properties"]["files"]["description"],
    }
    assert "customer_visible" in schema["properties"]


def test_downloads_are_documented_as_binary(document: dict[str, Any]) -> None:
    for path in (
        "/api/v1/documents/{document_id}/download",
        "/api/v1/customer/access/{token}/documents/{document_id}/download",
    ):
        content = document["paths"][path]["get"]["responses"]["200"]["content"]
        assert content == {"*/*": {"schema": {"type": "string", "format": "binary"}}}


def test_generated_document_is_deterministic(app: Flask) -> None:
    first = json.dumps(build_openapi_document(app), ensure_ascii=False)
    second = json.dumps(build_openapi_document(app), ensure_ascii=False)
    assert first == second


# --------------------------------------------------------------------------- contract: real responses
class Contract:
    """Validates real responses against the documented schemas and records what was exercised."""

    def __init__(self, app: Flask, document: dict[str, Any]) -> None:
        self._adapter = app.url_map.bind("localhost")
        self._document = document
        self.exercised: set[tuple[str, str]] = set()

    def _resolve(self, schema: Any, depth: int = 0) -> Any:
        """Inline ``$ref``s and make the check strict: every documented property must be present."""
        assert depth < 30, "schema reference cycle"
        if isinstance(schema, list):
            return [self._resolve(item, depth + 1) for item in schema]
        if not isinstance(schema, dict):
            return schema
        if "$ref" in schema:
            name = schema["$ref"].removeprefix(_REF_PREFIX)
            return self._resolve(copy.deepcopy(self._document["components"]["schemas"][name]), depth + 1)
        resolved = {key: self._resolve(value, depth + 1) for key, value in schema.items()}
        if "properties" in resolved and "required" not in resolved:
            resolved["required"] = sorted(resolved["properties"])
        return resolved

    def check(self, response: TestResponse, expected_status: int) -> Any:
        method = response.request.method.lower()
        rule, _ = self._adapter.match(response.request.path, method=method.upper(), return_rule=True)
        path = _template(rule.rule)
        label = f"{method.upper()} {path} -> {response.status_code}"
        assert response.status_code == expected_status, f"{label}: {response.get_data(as_text=True)[:600]}"

        operation = self._document["paths"][path][method]
        assert str(response.status_code) in operation["responses"], f"{label} is not a documented status"
        content = operation["responses"][str(response.status_code)]["content"]
        self.exercised.add((method, path))
        if "*/*" in content:  # binary download: the media type is the stored file's type
            assert response.headers["Content-Disposition"].startswith("attachment"), label
            return None
        assert response.mimetype in content, f"{label}: undocumented media type {response.mimetype}"

        body = response.get_json()
        schema = self._resolve(content["application/json"]["schema"])
        validator = OAS30Validator(schema, format_checker=oas30_format_checker)
        problems = [
            f"{'/'.join(str(part) for part in error.absolute_path)}: {error.message}"
            for error in validator.iter_errors(body)
        ]
        assert not problems, f"{label} violates the documented schema:\n" + "\n".join(problems[:15])
        return body["data"] if response.status_code < 400 else body["errors"]


def test_real_responses_match_the_documented_contract(app: Flask, factory: Factory, document: dict[str, Any]) -> None:
    contract = Contract(app, document)
    check = contract.check
    anonymous = Api(app)
    admin = factory.admin()

    # ---- health
    check(anonymous.get("/health"), 200)
    check(anonymous.get("/health/ready"), 200)

    # ---- authentication
    check(anonymous.login(admin.username, "wrong-password-1"), 401)
    check(anonymous.post("/auth/login", json={"username": admin.username}), 422)
    check(anonymous.post("/auth/login", data="{not json", content_type="application/json"), 400)
    check(anonymous.post("/auth/login", data="a=b", content_type="application/x-www-form-urlencoded"), 415)
    session = check(anonymous.login(admin.username), 200)
    admin_api = Api(app, session["access_token"])
    session = check(anonymous.post("/auth/refresh", json={"refresh_token": session["refresh_token"]}), 200)
    admin_api.token = session["access_token"]
    check(anonymous.post("/auth/refresh", json={"refresh_token": "x" * 43}), 401)
    check(admin_api.get("/auth/me"), 200)
    check(anonymous.get("/auth/me"), 401)

    # ---- companies
    company = check(admin_api.post("/companies", json={"name": "شرکت قرارداد", "company_code": "CONTRACT"}), 201)
    check(admin_api.post("/companies", json={"name": "تکراری", "company_code": "CONTRACT"}), 409)
    check(admin_api.post("/companies", json={"name": ""}), 422)
    check(admin_api.get("/companies?q=قرارداد&is_active=true"), 200)
    check(admin_api.get(f"/companies/{company['id']}"), 200)
    check(admin_api.get("/companies/00000000-0000-4000-8000-000000000000"), 404)
    check(admin_api.patch(f"/companies/{company['id']}", json={"phone": "021-555", "address": None}), 200)

    # ---- users
    user = check(
        admin_api.post(
            "/users",
            json={
                "username": "contract.user",
                "full_name": "کارمند قرارداد",
                "password": DEFAULT_PASSWORD,
                "company_id": company["id"],
            },
        ),
        201,
    )
    check(admin_api.get(f"/users?company_id={company['id']}"), 200)
    check(admin_api.get(f"/users/{user['id']}"), 200)
    check(admin_api.patch(f"/users/{user['id']}", json={"full_name": "نام تازه"}), 200)
    check(admin_api.post(f"/users/{user['id']}/reset-password", json={"new_password": "Res3t-Passw0rd-Value"}), 200)

    employee_session = check(anonymous.login("contract.user", "Res3t-Passw0rd-Value"), 200)
    employee_api = Api(app, employee_session["access_token"])
    check(employee_api.get("/companies"), 403)
    changed = check(
        employee_api.post(
            "/auth/change-password",
            json={"current_password": "Res3t-Passw0rd-Value", "new_password": DEFAULT_PASSWORD},
        ),
        200,
    )
    employee_api.token = changed["access_token"]

    # ---- product fields
    field = check(
        admin_api.post(
            "/product-fields",
            json={
                "field_key": "packaging",
                "label": "بسته‌بندی",
                "data_type": "SELECT",
                "is_customer_visible": True,
                "options": [{"value": "pallet", "label": "پالت"}, {"value": "bulk", "label": "فله"}],
            },
        ),
        201,
    )
    check(
        admin_api.post(
            "/product-fields",
            json={
                "field_key": "weight",
                "label": "وزن",
                "data_type": "DECIMAL",
                "is_customer_visible": True,
                "validation_rules": {"min": "0", "max_decimal_places": 2},
            },
        ),
        201,
    )
    for data_type in ("TEXT", "NUMBER", "DATE", "DATETIME", "BOOLEAN"):
        check(
            admin_api.post(
                "/product-fields",
                json={
                    "field_key": f"f_{data_type.lower()}",
                    "label": data_type,
                    "data_type": data_type,
                    "is_customer_visible": True,
                },
            ),
            201,
        )
    check(
        admin_api.post(
            "/product-fields",
            json={
                "field_key": "services",
                "label": "خدمات",
                "data_type": "MULTI_SELECT",
                "is_customer_visible": True,
                "options": [{"value": "insurance", "label": "بیمه"}, {"value": "customs", "label": "ترخیص"}],
            },
        ),
        201,
    )
    check(employee_api.get("/product-fields"), 200)
    check(admin_api.get("/product-fields?include_inactive=true"), 200)
    check(employee_api.get(f"/product-fields/{field['id']}"), 200)
    check(admin_api.patch(f"/product-fields/{field['id']}", json={"label": "نوع بسته‌بندی", "display_order": 5}), 200)

    # ---- shipments
    values = {
        "packaging": "pallet",
        "weight": "12.50",
        "f_text": "متن",
        "f_number": 3,
        "f_date": "2026-12-01",
        "f_datetime": "2026-12-01T08:00:00Z",
        "f_boolean": True,
        "services": ["insurance", "customs"],
    }
    shipment = check(
        employee_api.post("/shipments", json={"description": "محمولهٔ قرارداد", "product_values": values}), 201
    )
    shipment_url = f"/shipments/{shipment['id']}"
    check(employee_api.post("/shipments", json={"description": 5}), 422)
    check(employee_api.post("/shipments", json={"tracking_code": "MANUAL-CODE-1"}), 403)
    check(employee_api.get("/shipments?status=ACTIVE&sort=-created_at&q=قرارداد"), 200)
    check(employee_api.get("/shipments?per_page=1000"), 422)
    check(employee_api.get(shipment_url), 200)
    check(employee_api.patch(shipment_url, json={"description": None}), 200)
    check(employee_api.get(f"{shipment_url}/product-values"), 200)
    check(employee_api.put(f"{shipment_url}/product-values", json={"values": {"packaging": "bulk"}}), 200)
    check(employee_api.put(f"{shipment_url}/product-values", json={"values": {"packaging": "box"}}), 422)
    check(employee_api.put(f"{shipment_url}/product-values", json={"values": values}), 200)

    # ---- documents
    uploaded = check(
        employee_api.upload(shipment["id"], [upload_file("bill.pdf", PDF_BYTES), upload_file("photo.png", PNG_BYTES)]),
        201,
    )
    check(employee_api.upload(shipment["id"], [upload_file("run.exe", b"MZ")]), 422)
    check(employee_api.get(f"{shipment_url}/documents"), 200)
    check(employee_api.get(f"/documents/{uploaded[0]['id']}/download"), 200)
    check(employee_api.patch(f"/documents/{uploaded[1]['id']}", json={"is_customer_visible": False}), 200)
    check(employee_api.delete(f"/documents/{uploaded[1]['id']}"), 403)
    check(admin_api.delete(f"/documents/{uploaded[1]['id']}"), 200)

    # ---- customer portal
    check(anonymous.post("/customer/lookup", json={"tracking_code": "NO-SUCH-CODE-000"}), 404)
    grant = check(anonymous.post("/customer/lookup", json={"tracking_code": shipment["tracking_code"]}), 200)
    token = grant["access_token"]
    summary = check(anonymous.get(f"/customer/access/{token}/shipment"), 200)
    assert len(summary["product_details"]) == 8
    customer_documents = check(anonymous.get(f"/customer/access/{token}/documents"), 200)
    check(anonymous.get(f"/customer/access/{token}/documents/{customer_documents['items'][0]['id']}/download"), 200)
    check(anonymous.get(f"/customer/access/{token}/documents/{uploaded[1]['id']}/download"), 404)
    check(anonymous.post(f"/customer/access/{token}/revoke"), 200)
    check(anonymous.get(f"/customer/access/{token}/shipment"), 401)
    check(anonymous.get(f"/customer/access/{token}/documents"), 401)

    # ---- tracking code, history, archive
    anonymous.post("/customer/lookup", json={"tracking_code": shipment["tracking_code"]})
    check(employee_api.post(f"{shipment_url}/customer-sessions/revoke"), 200)
    check(employee_api.post(f"{shipment_url}/tracking-code", json={"generate": True}), 200)
    check(employee_api.post(f"{shipment_url}/tracking-code", json={}), 422)
    check(employee_api.get(f"{shipment_url}/tracking-history"), 200)
    check(employee_api.post(f"{shipment_url}/archive"), 200)
    check(employee_api.post(f"{shipment_url}/archive"), 409)
    check(employee_api.patch(shipment_url, json={"description": "x"}), 409)
    check(employee_api.post(f"{shipment_url}/unarchive"), 403)
    check(admin_api.post(f"{shipment_url}/unarchive"), 200)

    # ---- dashboard and audit trail
    check(admin_api.get("/dashboard/summary"), 200)
    check(employee_api.get("/dashboard/summary"), 200)
    check(admin_api.get("/audit-logs?per_page=100"), 200)
    check(admin_api.get("/audit-logs?user_id=nope"), 422)

    # ---- end of session
    check(employee_api.post("/auth/logout"), 200)
    check(employee_api.get("/auth/me"), 401)

    # Every documented operation was exercised: a new endpoint must be added to this scenario.
    documented = {(method, path) for path, operations in document["paths"].items() for method in operations}
    assert documented - contract.exercised == set()


def test_rate_limit_response_matches_the_contract(app: Flask, document: dict[str, Any], settings: Any) -> None:
    contract = Contract(app, document)
    client = Api(app, ip="198.51.100.77")
    limit = settings.rate_limit_customer_lookup_ip.limit
    for _ in range(limit):
        client.post("/customer/lookup", json={"tracking_code": "UNKNOWN-CODE-42"})
    response = client.post("/customer/lookup", json={"tracking_code": "UNKNOWN-CODE-42"})
    errors = contract.check(response, 429)
    assert errors["code"] == "rate_limited"
    assert int(response.headers["Retry-After"]) == errors["retry_after_seconds"] > 0
