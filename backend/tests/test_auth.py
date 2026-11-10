"""Authentication: login, token validation, refresh rotation, logout, password change."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from flask import Flask

from app.config import RateLimitRule, Settings
from app.core.datetime_utils import utcnow
from app.core.security import TokenService, hash_token
from app.extensions import db
from app.models import AuditLog, Company, RefreshToken, User
from tests.support import DEFAULT_PASSWORD, Api, Factory


def _error_code(response: Any) -> str:
    code: str = response.get_json()["errors"]["code"]
    return code


# --------------------------------------------------------------------------- login
def test_login_returns_tokens_profile_and_permissions(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    response = api.login(employee.username)
    assert response.status_code == 200
    body = response.get_json()
    assert body["success"] is True
    assert body["errors"] is None
    data = body["data"]
    assert data["token_type"] == "Bearer"
    assert data["expires_in"] == 900
    assert data["access_token"].count(".") == 2
    assert len(data["refresh_token"]) >= 43
    assert data["user"]["id"] == str(employee.id)
    assert data["user"]["role"] == "EMPLOYEE"
    assert data["user"]["company"]["id"] == str(employee.company_id)
    assert "shipment:create" in data["permissions"]
    assert "company:create" not in data["permissions"]
    assert data["app_settings"]["upload"]["max_file_size_bytes"] > 0
    assert response.headers["Cache-Control"] == "no-store"


def test_login_response_never_contains_password_material(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    raw = api.login(employee.username).get_data(as_text=True)
    assert "password" not in raw.replace('"password":{"min_length"', "")
    assert "argon2" not in raw
    assert "token_version" not in raw


def test_username_is_case_insensitive_and_trimmed(api: Api, factory: Factory) -> None:
    factory.employee(username="sara.ahmadi")
    assert api.login("  Sara.Ahmadi ").status_code == 200


def test_password_is_case_sensitive_and_not_trimmed(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    assert api.login(employee.username, DEFAULT_PASSWORD.lower()).status_code == 401
    assert api.login(employee.username, DEFAULT_PASSWORD + " ").status_code == 401


def test_unknown_user_and_wrong_password_are_indistinguishable(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    wrong_password = api.login(employee.username, "wrong-password-123")
    unknown_user = api.login("no.such.user", "wrong-password-123")
    assert wrong_password.status_code == unknown_user.status_code == 401
    assert wrong_password.get_json() | {"errors": None} == unknown_user.get_json() | {"errors": None}
    assert _error_code(wrong_password) == _error_code(unknown_user) == "invalid_credentials"


def test_disabled_account_is_only_revealed_to_the_password_holder(api: Api, factory: Factory) -> None:
    employee = factory.employee(is_active=False)
    with_password = api.login(employee.username)
    assert with_password.status_code == 403
    assert _error_code(with_password) == "account_disabled"
    without_password = api.login(employee.username, "wrong-password-123")
    assert without_password.status_code == 401
    assert _error_code(without_password) == "invalid_credentials"


def test_employee_of_inactive_company_cannot_log_in(api: Api, factory: Factory) -> None:
    company = factory.company(is_active=False)
    employee = factory.employee(company)
    response = api.login(employee.username)
    assert response.status_code == 403
    assert _error_code(response) == "company_inactive"


@pytest.mark.parametrize(
    "payload",
    [{}, {"username": "someone"}, {"password": "secret-secret"}, {"username": "", "password": ""}],
)
def test_login_validation_errors(api: Api, payload: dict[str, str]) -> None:
    response = api.post("/auth/login", json=payload)
    assert response.status_code == 422
    assert _error_code(response) == "validation_error"
    assert response.get_json()["errors"]["fields"]


def test_login_rejects_unknown_fields(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    response = api.post(
        "/auth/login", json={"username": employee.username, "password": DEFAULT_PASSWORD, "role": "SUPER_ADMIN"}
    )
    assert response.status_code == 422
    assert "role" in response.get_json()["errors"]["fields"]


def test_login_requires_json(api: Api) -> None:
    response = api.post("/auth/login", data="username=a&password=b", content_type="application/x-www-form-urlencoded")
    assert response.status_code == 415
    malformed = api.post("/auth/login", data="{not json", content_type="application/json")
    assert malformed.status_code == 400
    assert _error_code(malformed) == "invalid_json"
    array = api.post("/auth/login", json=["a", "b"])
    assert array.status_code == 400


def test_login_attempts_are_audited_without_secrets(api: Api, factory: Factory, app: Flask) -> None:
    employee = factory.employee()
    api.login(employee.username, "super-secret-wrong-password")
    api.login(employee.username)
    with app.app_context():
        entries = db.session.scalars(db.select(AuditLog).order_by(AuditLog.created_at)).all()
        assert [entry.action for entry in entries] == ["LOGIN_FAILED", "LOGIN_SUCCESS"]
        assert entries[0].meta == {"username": employee.username, "reason": "wrong_password"}
        assert entries[0].ip_address == "127.0.0.1"
        assert entries[0].request_id
        assert all("super-secret-wrong-password" not in str(entry.meta) for entry in entries)
        db.session.remove()


def test_successful_login_records_last_login(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    assert employee.last_login_at is None
    api.login(employee.username)
    refreshed = factory.get(User, employee.id)
    assert refreshed.last_login_at is not None
    assert utcnow() - refreshed.last_login_at < timedelta(seconds=30)


# --------------------------------------------------------------------------- access tokens
def test_protected_endpoint_requires_a_token(api: Api) -> None:
    response = api.get("/auth/me")
    assert response.status_code == 401
    assert _error_code(response) == "authentication_required"
    assert response.headers["WWW-Authenticate"].startswith("Bearer")
    assert response.get_json()["success"] is False


@pytest.mark.parametrize(
    "header",
    ["", "Bearer", "Bearer ", "Basic dXNlcjpwYXNz", "Token abc", "bearer not.a.jwt", "Bearer a.b.c"],
)
def test_malformed_authorization_headers_are_rejected(api: Api, header: str) -> None:
    response = api.get("/auth/me", headers={"Authorization": header})
    assert response.status_code == 401


def test_me_returns_current_profile(factory: Factory) -> None:
    admin = factory.admin()
    response = factory.login(admin).get("/auth/me")
    assert response.status_code == 200
    data = response.get_json()["data"]
    assert data["user"]["role"] == "SUPER_ADMIN"
    assert data["user"]["company"] is None
    assert "scope:global" in data["permissions"]
    assert "access_token" not in data


def test_expired_access_token_is_rejected(api: Api, factory: Factory, settings: Settings) -> None:
    employee = factory.employee()
    tokens = factory.tokens(employee)
    session_id = TokenService(settings).decode_access_token(tokens.access_token).session_id
    past = utcnow() - timedelta(seconds=settings.access_token_ttl_seconds + 10)
    expired = TokenService(settings).issue_access_token(employee.id, session_id, 0, now=past)
    response = api.get("/auth/me", headers={"Authorization": f"Bearer {expired.token}"})
    assert response.status_code == 401
    assert _error_code(response) == "token_expired"


def test_token_for_unknown_session_is_rejected(api: Api, factory: Factory, settings: Settings) -> None:
    """A correctly signed token is still refused when its session does not exist server-side."""

    employee = factory.employee()
    forged = TokenService(settings).issue_access_token(employee.id, uuid.uuid4(), 0)
    response = api.get("/auth/me", headers={"Authorization": f"Bearer {forged.token}"})
    assert response.status_code == 401
    assert _error_code(response) == "token_revoked"


def test_refresh_token_cannot_be_used_as_access_token(api: Api, factory: Factory) -> None:
    tokens = factory.tokens(factory.employee())
    response = api.get("/auth/me", headers={"Authorization": f"Bearer {tokens.refresh_token}"})
    assert response.status_code == 401


def test_deactivating_a_user_invalidates_existing_tokens_immediately(factory: Factory, app: Flask) -> None:
    employee = factory.employee()
    client = factory.login(employee)
    assert client.get("/auth/me").status_code == 200
    with app.app_context():
        db.session.execute(db.update(User).where(User.id == employee.id).values(is_active=False))
        db.session.commit()
        db.session.remove()
    response = client.get("/auth/me")
    assert response.status_code == 401
    assert _error_code(response) == "account_disabled"


def test_deactivating_a_company_blocks_its_employees_immediately(factory: Factory, app: Flask) -> None:
    company = factory.company()
    employee = factory.employee(company)
    tokens = factory.tokens(employee)
    with app.app_context():
        db.session.execute(db.update(Company).where(Company.id == company.id).values(is_active=False))
        db.session.commit()
        db.session.remove()
    response = Api(app, tokens.access_token).get("/shipments")
    assert response.status_code == 401
    assert _error_code(response) == "company_inactive"
    refresh = Api(app).post("/auth/refresh", json={"refresh_token": tokens.refresh_token})
    assert refresh.status_code == 401


def test_bumping_token_version_invalidates_access_tokens(factory: Factory, app: Flask) -> None:
    employee = factory.employee()
    client = factory.login(employee)
    with app.app_context():
        db.session.execute(db.update(User).where(User.id == employee.id).values(token_version=User.token_version + 1))
        db.session.commit()
        db.session.remove()
    response = client.get("/auth/me")
    assert response.status_code == 401
    assert _error_code(response) == "token_revoked"


# --------------------------------------------------------------------------- refresh
def test_refresh_rotates_the_refresh_token(api: Api, factory: Factory) -> None:
    tokens = factory.tokens(factory.employee())
    response = api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token})
    assert response.status_code == 200
    data = response.get_json()["data"]
    assert data["refresh_token"] != tokens.refresh_token
    assert data["access_token"] != tokens.access_token
    assert Api(api._app, data["access_token"]).get("/auth/me").status_code == 200
    # The access token issued before the rotation belongs to the same session and stays valid.
    assert Api(api._app, tokens.access_token).get("/auth/me").status_code == 200


def test_reusing_a_rotated_refresh_token_revokes_the_whole_session(api: Api, factory: Factory) -> None:
    tokens = factory.tokens(factory.employee())
    rotated = api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token}).get_json()["data"]

    replay = api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token})
    assert replay.status_code == 401
    assert _error_code(replay) == "refresh_token_invalid"

    # The legitimate holder of the newest token is logged out as well (theft response).
    assert api.post("/auth/refresh", json={"refresh_token": rotated["refresh_token"]}).status_code == 401
    assert Api(api._app, rotated["access_token"]).get("/auth/me").status_code == 401
    assert "REFRESH_TOKEN_REUSE_DETECTED" in factory.audit_actions()


@pytest.mark.parametrize("token", ["x" * 43, "a" * 20, "../../etc/passwd-----------"])
def test_unknown_refresh_token_is_rejected(api: Api, token: str) -> None:
    response = api.post("/auth/refresh", json={"refresh_token": token})
    assert response.status_code == 401
    assert _error_code(response) == "refresh_token_invalid"


def test_access_token_is_not_accepted_as_refresh_token(api: Api, factory: Factory) -> None:
    tokens = factory.tokens(factory.employee())
    assert api.post("/auth/refresh", json={"refresh_token": tokens.access_token}).status_code == 401


def test_expired_refresh_token_is_rejected(api: Api, factory: Factory) -> None:
    tokens = factory.tokens(factory.employee())
    factory.expire_all(RefreshToken, "expires_at")
    assert api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token}).status_code == 401
    # With no live refresh token the session is over for access tokens too.
    assert Api(api._app, tokens.access_token).get("/auth/me").status_code == 401


def test_refresh_fails_for_a_deactivated_user(api: Api, factory: Factory, app: Flask) -> None:
    employee = factory.employee()
    tokens = factory.tokens(employee)
    with app.app_context():
        db.session.execute(db.update(User).where(User.id == employee.id).values(is_active=False))
        db.session.commit()
        db.session.remove()
    assert api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token}).status_code == 401


def test_refresh_tokens_are_stored_only_as_hashes(factory: Factory, app: Flask) -> None:
    tokens = factory.tokens(factory.employee())
    with app.app_context():
        stored = db.session.scalars(db.select(RefreshToken.token_hash)).all()
        db.session.remove()
    assert stored == [hash_token(tokens.refresh_token)]
    assert tokens.refresh_token not in stored


# --------------------------------------------------------------------------- logout
def test_logout_revokes_access_and_refresh_tokens(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    tokens = factory.tokens(employee)
    client = Api(api._app, tokens.access_token)
    assert client.post("/auth/logout").status_code == 200
    after = client.get("/auth/me")
    assert after.status_code == 401
    assert _error_code(after) == "token_revoked"
    assert api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token}).status_code == 401
    assert factory.audit_actions()[-1] == "LOGOUT"


def test_logout_only_ends_the_current_session(factory: Factory) -> None:
    employee = factory.employee()
    phone = factory.login(employee)
    desktop = factory.login(employee)
    assert phone.post("/auth/logout").status_code == 200
    assert phone.get("/auth/me").status_code == 401
    assert desktop.get("/auth/me").status_code == 200


def test_logout_requires_authentication(api: Api) -> None:
    assert api.post("/auth/logout").status_code == 401


# --------------------------------------------------------------------------- password change
def test_change_password_revokes_other_sessions_and_issues_new_tokens(api: Api, factory: Factory) -> None:
    employee = factory.employee()
    other_device = factory.login(employee)
    current = factory.login(employee)
    new_password = "Brand-New-Passw0rd!"
    response = current.post(
        "/auth/change-password", json={"current_password": DEFAULT_PASSWORD, "new_password": new_password}
    )
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert Api(api._app, data["access_token"]).get("/auth/me").status_code == 200
    assert other_device.get("/auth/me").status_code == 401
    assert current.get("/auth/me").status_code == 401  # the old access token of this device too
    assert api.login(employee.username, DEFAULT_PASSWORD).status_code == 401
    assert api.login(employee.username, new_password).status_code == 200
    assert "PASSWORD_CHANGED" in factory.audit_actions()


def test_change_password_requires_the_current_password(factory: Factory) -> None:
    client = factory.login(factory.employee())
    response = client.post(
        "/auth/change-password", json={"current_password": "not-my-password", "new_password": "Brand-New-Passw0rd!"}
    )
    assert response.status_code == 422
    assert _error_code(response) == "invalid_current_password"
    assert "current_password" in response.get_json()["errors"]["fields"]
    assert client.get("/auth/me").status_code == 200


@pytest.mark.parametrize(
    "new_password",
    ["short", "         ", "x" * 129, DEFAULT_PASSWORD],
)
def test_change_password_enforces_the_password_policy(factory: Factory, new_password: str) -> None:
    client = factory.login(factory.employee())
    response = client.post(
        "/auth/change-password", json={"current_password": DEFAULT_PASSWORD, "new_password": new_password}
    )
    assert response.status_code == 422
    assert "new_password" in response.get_json()["errors"]["fields"]


def test_new_password_must_not_equal_the_username(factory: Factory) -> None:
    employee = factory.employee(username="long.enough.username")
    client = factory.login(employee)
    response = client.post(
        "/auth/change-password", json={"current_password": DEFAULT_PASSWORD, "new_password": "Long.Enough.Username"}
    )
    assert response.status_code == 422


# --------------------------------------------------------------------------- rate limiting
def test_repeated_failures_lock_the_username_temporarily(make_app: Callable[..., Flask], factory: Factory) -> None:
    limited = make_app(rate_limit_login_user=RateLimitRule(limit=3, window_seconds=900))
    employee = factory.employee()
    client = Api(limited)
    for _ in range(3):
        assert client.login(employee.username, "wrong-password-123").status_code == 401
    blocked = client.login(employee.username, DEFAULT_PASSWORD)
    assert blocked.status_code == 429
    assert _error_code(blocked) == "rate_limited"
    assert int(blocked.headers["Retry-After"]) >= 1
    assert blocked.get_json()["errors"]["retry_after_seconds"] >= 1
    # Other accounts are unaffected.
    assert client.login(factory.employee().username).status_code == 200


def test_successful_login_resets_the_failure_counter(make_app: Callable[..., Flask], factory: Factory) -> None:
    limited = make_app(rate_limit_login_user=RateLimitRule(limit=3, window_seconds=900))
    employee = factory.employee()
    client = Api(limited)
    for _ in range(2):
        client.login(employee.username, "wrong-password-123")
    assert client.login(employee.username).status_code == 200
    for _ in range(2):
        assert client.login(employee.username, "wrong-password-123").status_code == 401
    assert client.login(employee.username).status_code == 200


def test_login_is_rate_limited_per_client_address(make_app: Callable[..., Flask], factory: Factory) -> None:
    limited = make_app(rate_limit_login_ip=RateLimitRule(limit=4, window_seconds=300))
    attacker = Api(limited, ip="198.51.100.7")
    for index in range(4):
        assert attacker.login(f"guess{index}", "wrong-password-123").status_code == 401
    assert attacker.login("guess-final", "wrong-password-123").status_code == 429
    # A different client address is not affected.
    employee = factory.employee()
    assert Api(limited, ip="198.51.100.8").login(employee.username).status_code == 200


def test_unknown_usernames_are_rate_limited_like_real_ones(make_app: Callable[..., Flask]) -> None:
    """Otherwise the lock-out behaviour itself would reveal which usernames exist."""
    limited = make_app(rate_limit_login_user=RateLimitRule(limit=2, window_seconds=900))
    client = Api(limited)
    for _ in range(2):
        assert client.login("ghost.user", "wrong-password-123").status_code == 401
    assert client.login("ghost.user", "wrong-password-123").status_code == 429
