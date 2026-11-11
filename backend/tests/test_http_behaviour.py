"""Cross-cutting HTTP behaviour: error envelope, security headers, CORS, proxies, static web hosting."""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from flask import Flask
from werkzeug.test import TestResponse

from app.core.http import mask_sensitive_path
from app.extensions import db
from app.models import AuditLog, Company, User, UserRole
from tests.support import API_PREFIX, Api, Factory


def _assert_error_envelope(response: TestResponse, status: int, code: str) -> dict[str, Any]:
    assert response.status_code == status, response.get_data(as_text=True)
    assert response.mimetype == "application/json"
    body: dict[str, Any] = response.get_json()
    assert set(body) == {"success", "message", "data", "errors"}
    assert body["success"] is False and body["data"] is None
    assert isinstance(body["message"], str) and body["message"]
    assert body["errors"]["code"] == code
    assert body["errors"]["request_id"] == response.headers["X-Request-ID"]
    return body


# --------------------------------------------------------------------------- error envelope
def test_unknown_routes_and_methods_use_the_json_envelope(api: Api) -> None:
    _assert_error_envelope(api.get("/no-such-resource"), 404, "not_found")
    _assert_error_envelope(api.get("/shipments/not-a-uuid"), 404, "not_found")
    _assert_error_envelope(api.delete("/auth/login"), 405, "method_not_allowed")
    _assert_error_envelope(api._client.get("/"), 404, "not_found")  # the web client is not hosted by default


def test_unexpected_errors_return_500_without_internal_details(
    make_app: Callable[..., Flask], factory: Factory, caplog: pytest.LogCaptureFixture
) -> None:
    application = make_app()

    @application.get(f"{API_PREFIX}/_test/crash")
    def crash() -> str:
        db.session.add(Company(name="نیمه‌کاره", company_code="HALFDONE"))
        db.session.flush()
        raise RuntimeError("secret internal detail: db password is hunter2 at /srv/app/config.py")

    client = Api(application)
    with caplog.at_level(logging.ERROR):
        response = client.get("/_test/crash")
    body = _assert_error_envelope(response, 500, "internal_error")
    raw = response.get_data(as_text=True)
    for leak in ("hunter2", "secret internal detail", "RuntimeError", "Traceback", "config.py", "sqlalchemy"):
        assert leak not in raw
    assert set(body["errors"]) == {"code", "request_id"}

    # The operator still gets the full story, correlated by the request id.
    assert "Unhandled exception" in caplog.text
    assert "RuntimeError: secret internal detail" in caplog.text

    # The failed transaction was rolled back and the application keeps working.
    assert factory.count(Company) == 0
    assert client.get("/health/ready").status_code == 200
    assert client.login(factory.admin().username).status_code == 200


@pytest.mark.mysql
def test_database_constraint_violations_are_conflicts_not_crashes(make_app: Callable[..., Flask]) -> None:
    application = make_app()

    @application.get(f"{API_PREFIX}/_test/orphan-employee")
    def orphan_employee() -> str:
        db.session.add(User(username="orphan", full_name="x", password_hash="x", role=UserRole.EMPLOYEE))
        db.session.commit()
        return "unreachable"

    @application.get(f"{API_PREFIX}/_test/duplicate-company")
    def duplicate_company() -> str:
        db.session.add_all([Company(name="a", company_code="SAME"), Company(name="b", company_code="SAME")])
        db.session.commit()
        return "unreachable"

    client = Api(application)
    for path in ("/_test/orphan-employee", "/_test/duplicate-company"):
        response = client.get(path)
        _assert_error_envelope(response, 409, "conflict")
        assert "SAME" not in response.get_data(as_text=True) and "ck_users" not in response.get_data(as_text=True)


@pytest.mark.parametrize(
    ("data", "content_type", "status", "code"),
    [
        ("{broken", "application/json", 400, "invalid_json"),
        ("[1, 2]", "application/json", 400, "invalid_json"),
        ('"text"', "application/json", 400, "invalid_json"),
        ("null", "application/json", 400, "invalid_json"),
        ("", "application/json", 400, "invalid_json"),
        ('{"username": "a", "password": "b"}', "text/plain", 415, "unsupported_media_type"),
        ("username=a&password=b", "application/x-www-form-urlencoded", 415, "unsupported_media_type"),
        ('{"username": "a", "password": "b"}', None, 415, "unsupported_media_type"),
        ('{"username": "a", "password": "b", "role": "SUPER_ADMIN"}', "application/json", 422, "validation_error"),
        ('{"username": "a", "password": "' + "x" * (1024 * 1024) + '"}', "application/json", 413, "payload_too_large"),
    ],
)
def test_malformed_request_bodies(api: Api, data: str, content_type: str | None, status: int, code: str) -> None:
    response = api.post("/auth/login", data=data, content_type=content_type)
    _assert_error_envelope(response, status, code)


def test_vendor_json_media_types_are_accepted(api: Api) -> None:
    response = api.post(
        "/auth/login", data=json.dumps({"username": "nobody", "password": "x"}), content_type="application/vnd.api+json"
    )
    assert response.status_code == 401


def test_validation_errors_list_every_offending_field(api: Api) -> None:
    body = _assert_error_envelope(api.post("/auth/login", json={"user": "a"}), 422, "validation_error")
    assert set(body["errors"]["fields"]) == {"username", "password", "user"}
    assert all(isinstance(messages, list) and messages for messages in body["errors"]["fields"].values())


def test_messages_are_persian_and_utf8(api: Api) -> None:
    response = api.get("/no-such-resource")
    assert "یافت نشد" in response.get_data(as_text=True)  # real UTF-8, not \\uXXXX escapes
    assert response.headers["Content-Type"] == "application/json"


# --------------------------------------------------------------------------- headers
def test_api_responses_carry_security_headers(api: Api, factory: Factory) -> None:
    client = factory.login(factory.admin())
    for response in (api.get("/health"), api.get("/no-such-resource"), client.get("/auth/me"), api.get("/auth/me")):
        headers = response.headers
        assert headers["X-Content-Type-Options"] == "nosniff"
        assert headers["Cache-Control"] == "no-store"
        assert headers["Referrer-Policy"] == "no-referrer"
        assert headers["X-Frame-Options"] == "DENY"
        assert headers["Content-Security-Policy"] == "default-src 'none'; frame-ancestors 'none'"
        assert "camera=()" in headers["Permissions-Policy"]
        assert "Strict-Transport-Security" not in headers  # plain HTTP in tests
        assert "Server" not in headers or "Werkzeug" not in headers.get("Server", "")
        assert "Set-Cookie" not in headers  # the API is stateless: no cookies, hence no CSRF surface


def test_request_ids_are_generated_echoed_and_sanitized(api: Api) -> None:
    generated = api.get("/health").headers["X-Request-ID"]
    assert len(generated) == 32 and generated != api.get("/health").headers["X-Request-ID"]
    assert (
        api.get("/health", headers={"X-Request-ID": "client-trace-0001"}).headers["X-Request-ID"] == "client-trace-0001"
    )
    for hostile in ("short", "x" * 65, "bad id with spaces", "<script>alert(1)</script>", "line\tbreak-0001"):
        echoed = api.get("/health", headers={"X-Request-ID": hostile}).headers["X-Request-ID"]
        assert echoed != hostile and len(echoed) == 32


def test_hsts_is_sent_only_over_https_when_enabled(make_app: Callable[..., Flask], api: Api) -> None:
    secure = Api(make_app(hsts_enabled=True))
    assert "Strict-Transport-Security" not in secure.get("/health").headers
    over_tls = secure.get("/health", base_url="https://api.example.com")
    assert over_tls.headers["Strict-Transport-Security"] == "max-age=31536000; includeSubDomains"
    assert "Strict-Transport-Security" not in api.get("/health", base_url="https://api.example.com").headers


def test_head_and_options_requests(api: Api) -> None:
    head = api._open("HEAD", "/health")
    assert head.status_code == 200 and head.data == b""
    options = api._open("OPTIONS", "/auth/login")
    assert options.status_code == 200
    assert set(options.headers["Allow"].split(", ")) == {"POST", "OPTIONS"}


# --------------------------------------------------------------------------- CORS
def test_cross_origin_requests_are_not_enabled_by_default(api: Api) -> None:
    response = api.get("/health", headers={"Origin": "https://evil.example"})
    assert response.status_code == 200
    assert "Access-Control-Allow-Origin" not in response.headers


def test_cors_allows_only_the_configured_origins(make_app: Callable[..., Flask]) -> None:
    client = Api(make_app(cors_allowed_origins=("https://app.example.com",)))

    allowed = client.get("/health", headers={"Origin": "https://app.example.com"})
    assert allowed.headers["Access-Control-Allow-Origin"] == "https://app.example.com"
    assert "Access-Control-Allow-Credentials" not in allowed.headers  # bearer tokens only, never cookies
    exposed = {name.strip() for name in allowed.headers["Access-Control-Expose-Headers"].split(",")}
    assert {"Content-Disposition", "X-Request-ID", "Retry-After"} <= exposed

    for origin in ("https://evil.example", "https://app.example.com.evil.example", "http://app.example.com", "null"):
        denied = client.get("/health", headers={"Origin": origin})
        assert "Access-Control-Allow-Origin" not in denied.headers, origin

    preflight = client._open(
        "OPTIONS",
        "/shipments",
        headers={
            "Origin": "https://app.example.com",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization, content-type",
        },
    )
    assert preflight.status_code == 200
    assert preflight.headers["Access-Control-Allow-Origin"] == "https://app.example.com"
    assert "POST" in preflight.headers["Access-Control-Allow-Methods"]
    allowed_headers = preflight.headers["Access-Control-Allow-Headers"].lower()
    assert "authorization" in allowed_headers and "content-type" in allowed_headers
    assert preflight.headers["Access-Control-Max-Age"] == "600"

    # Error responses need the header as well, otherwise browsers hide the error body from the client.
    failure = client.get("/auth/me", headers={"Origin": "https://app.example.com"})
    assert failure.status_code == 401
    assert failure.headers["Access-Control-Allow-Origin"] == "https://app.example.com"


# --------------------------------------------------------------------------- reverse proxies
def _last_login_ip(application: Flask) -> str | None:
    with application.app_context():
        entry = db.session.scalars(
            db.select(AuditLog).where(AuditLog.action == "LOGIN_FAILED").order_by(AuditLog.created_at.desc())
        ).first()
        db.session.remove()
        assert entry is not None
        return entry.ip_address


def test_forwarded_headers_are_ignored_unless_a_proxy_is_trusted(app: Flask, make_app: Callable[..., Flask]) -> None:
    spoofed = {"X-Forwarded-For": "203.0.113.50", "X-Forwarded-Proto": "https", "X-Real-IP": "203.0.113.51"}

    Api(app).post("/auth/login", json={"username": "ghost", "password": "x"}, headers=spoofed)
    assert _last_login_ip(app) == "127.0.0.1"  # a client cannot choose its own address (rate limits, audit)

    behind_proxy = make_app(trusted_proxy_count=1, hsts_enabled=True)
    response = Api(behind_proxy).post(
        "/auth/login",
        json={"username": "ghost", "password": "x"},
        headers={"X-Forwarded-For": "198.51.100.9, 203.0.113.50", "X-Forwarded-Proto": "https"},
    )
    assert _last_login_ip(behind_proxy) == "203.0.113.50"  # only the hop added by the trusted proxy counts
    assert "Strict-Transport-Security" in response.headers  # TLS terminated at the proxy is recognised


# --------------------------------------------------------------------------- logging
def test_customer_tokens_never_reach_the_access_log(api: Api, caplog: pytest.LogCaptureFixture) -> None:
    token = "Zm9vYmFyLXNlY3JldC1jdXN0b21lci10b2tlbi0xMjM0NTY3OA"
    with caplog.at_level(logging.INFO):
        api.get(f"/customer/access/{token}/shipment")
        api.get(f"/customer/access/{token}/documents/00000000-0000-4000-8000-000000000000/download")
    assert token not in caplog.text
    assert "/customer/access/[redacted]/shipment" in caplog.text
    assert (
        mask_sensitive_path(f"/api/v1/customer/access/{token}/documents")
        == "/api/v1/customer/access/[redacted]/documents"
    )
    assert mask_sensitive_path("/api/v1/shipments/123") == "/api/v1/shipments/123"


def test_credentials_never_reach_the_log(app: Flask, factory: Factory, caplog: pytest.LogCaptureFixture) -> None:
    user = factory.employee()
    with caplog.at_level(logging.DEBUG):
        anonymous = Api(app)
        anonymous.login(user.username, "Wr0ng-Passw0rd-Attempt")
        session = anonymous.login(user.username).get_json()["data"]
        Api(app, session["access_token"]).get("/auth/me")
        anonymous.post("/auth/refresh", json={"refresh_token": session["refresh_token"]})
    assert caplog.records
    for secret in ("Wr0ng-Passw0rd-Attempt", "Str0ng-Test-Passw0rd", session["access_token"], session["refresh_token"]):
        assert secret not in caplog.text


# --------------------------------------------------------------------------- optional static hosting of the web client
@pytest.fixture
def web_root(tmp_path: Path) -> Path:
    root = tmp_path / "dist"
    (root / "assets").mkdir(parents=True)
    (root / "index.html").write_text(
        "<!doctype html><html lang='fa' dir='rtl'><title></title></html>", encoding="utf-8"
    )
    (root / "assets" / "app.js").write_text("export const ready = true;\n", encoding="utf-8")
    (root / "assets" / "app.css").write_text("body { direction: rtl; }\n", encoding="utf-8")
    (tmp_path / "secret.txt").write_text("outside the web root", encoding="utf-8")
    return root


def test_web_client_is_served_with_a_strict_content_security_policy(
    make_app: Callable[..., Flask], web_root: Path
) -> None:
    client = make_app(serve_web_app=True, web_app_dir=web_root).test_client()

    index = client.get("/")
    assert index.status_code == 200
    assert index.mimetype == "text/html"
    assert "" in index.get_data(as_text=True)
    assert index.headers["Cache-Control"] == "no-cache"
    assert index.headers["X-Content-Type-Options"] == "nosniff"
    assert index.headers["X-Frame-Options"] == "DENY"
    policy = dict(part.strip().split(" ", 1) for part in index.headers["Content-Security-Policy"].split(";"))
    assert policy["default-src"] == "'self'"
    assert policy["script-src"] == "'self'" and policy["style-src"] == "'self'"  # no inline code, no eval
    assert policy["connect-src"] == "'self'"
    assert policy["object-src"] == "'none'" and policy["base-uri"] == "'self'"
    assert policy["frame-ancestors"] == "'none'"
    assert "unsafe" not in index.headers["Content-Security-Policy"]

    script = client.get("/assets/app.js")
    assert script.status_code == 200 and script.mimetype in {"text/javascript", "application/javascript"}
    assert client.get("/assets/app.css").mimetype == "text/css"

    cached = client.get("/assets/app.js", headers={"If-None-Match": script.headers["ETag"]})
    assert cached.status_code == 304


@pytest.mark.parametrize(
    "path",
    [
        "/../secret.txt",
        "/%2e%2e/secret.txt",
        "/assets/../../secret.txt",
        "/assets/%2e%2e%2f%2e%2e%2fsecret.txt",
        "/..%5csecret.txt",
        "//etc/passwd",
        "/missing.js",
        "/assets/",
    ],
)
def test_web_hosting_never_serves_files_outside_its_root(
    make_app: Callable[..., Flask], web_root: Path, path: str
) -> None:
    client = make_app(serve_web_app=True, web_app_dir=web_root).test_client()
    response = client.get(path)
    assert response.status_code == 404
    assert "outside the web root" not in response.get_data(as_text=True)


def test_web_hosting_does_not_shadow_the_api(make_app: Callable[..., Flask], web_root: Path) -> None:
    (web_root / "api").mkdir()
    (web_root / "api" / "v1").mkdir()
    (web_root / "api" / "v1" / "health").write_text("spoofed", encoding="utf-8")
    client = make_app(serve_web_app=True, web_app_dir=web_root).test_client()
    assert client.get("/api/v1/health").get_json()["data"]["status"] == "ok"
    missing = client.get("/api/v1/no-such-resource")
    assert missing.status_code == 404 and missing.mimetype == "application/json"
    assert client.get("/api/other").status_code == 404
    assert client.post("/").status_code == 405


@pytest.mark.parametrize(
    ("frame_ancestors", "x_frame_options"),
    [("'none'", "DENY"), ("'self'", "SAMEORIGIN"), ("https://portal.example.com", None), ("*", None)],
)
def test_embedding_policy_is_configurable_for_the_web_client_only(
    make_app: Callable[..., Flask], web_root: Path, frame_ancestors: str, x_frame_options: str | None
) -> None:
    client = make_app(serve_web_app=True, web_app_dir=web_root, frame_ancestors=frame_ancestors).test_client()
    index = client.get("/")
    assert index.headers["Content-Security-Policy"].endswith(f"frame-ancestors {frame_ancestors}")
    assert index.headers.get("X-Frame-Options") == x_frame_options
    api_response = client.get("/api/v1/health")  # API responses can never be framed
    assert api_response.headers["X-Frame-Options"] == "DENY"
    assert "frame-ancestors 'none'" in api_response.headers["Content-Security-Policy"]


@pytest.mark.parametrize("origins", [("https://app.example.com",), ("*",)])
def test_cors_origins_do_not_widen_the_policy_of_the_served_web_client(
    make_app: Callable[..., Flask], web_root: Path, origins: tuple[str, ...]
) -> None:
    """CORS lets pages of other origins call this API; it must not let the page served here call other origins."""
    client = make_app(serve_web_app=True, web_app_dir=web_root, cors_allowed_origins=origins).test_client()
    policy = client.get("/").headers["Content-Security-Policy"]
    assert "connect-src 'self';" in policy
    assert "example.com" not in policy
    assert "*" not in policy


def test_missing_web_build_does_not_break_the_api(make_app: Callable[..., Flask], tmp_path: Path) -> None:
    client = make_app(serve_web_app=True, web_app_dir=tmp_path / "not-built").test_client()
    assert client.get("/").status_code == 404
    assert client.get("/api/v1/health").status_code == 200
