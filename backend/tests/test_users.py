"""Employee account management (SUPER_ADMIN only)."""

from __future__ import annotations

import uuid

import pytest
from flask import Flask

from app.extensions import db
from app.models import User
from tests.support import DEFAULT_PASSWORD, Api, Factory

NEW_PASSWORD = "An0ther-Valid-Passw0rd"


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


def _payload(company: uuid.UUID, /, **overrides: object) -> dict[str, object]:
    return {
        "username": "new.employee",
        "full_name": "کارمند تازه",
        "password": NEW_PASSWORD,
        "company_id": str(company),
        **overrides,
    }


def test_create_employee(admin_api: Api, api: Api, factory: Factory, app: Flask) -> None:
    company = factory.company()
    response = admin_api.post("/users", json=_payload(company.id, username="New.Employee"))
    assert response.status_code == 201, response.get_json()
    data = response.get_json()["data"]
    assert data["username"] == "new.employee"
    assert data["role"] == "EMPLOYEE"
    assert data["company"]["id"] == str(company.id)
    assert data["is_active"] is True
    assert set(data) == {
        "id",
        "username",
        "full_name",
        "role",
        "is_active",
        "company_id",
        "company",
        "last_login_at",
        "created_at",
        "updated_at",
    }
    with app.app_context():
        stored = db.session.get(User, uuid.UUID(data["id"]))
        assert stored is not None
        assert stored.password_hash.startswith("$argon2id$")
        assert NEW_PASSWORD not in stored.password_hash
        db.session.remove()
    assert api.login("new.employee", NEW_PASSWORD).status_code == 200
    assert "USER_CREATED" in factory.audit_actions()


def test_the_api_cannot_create_or_promote_super_admins(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    response = admin_api.post("/users", json=_payload(company.id, role="SUPER_ADMIN"))
    assert response.status_code == 422
    assert "role" in response.get_json()["errors"]["fields"]

    employee = factory.employee(company)
    response = admin_api.patch(f"/users/{employee.id}", json={"role": "SUPER_ADMIN"})
    assert response.status_code == 422
    assert factory.get(User, employee.id).role.value == "EMPLOYEE"


def test_username_must_be_unique_case_insensitively(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    factory.employee(company, username="taken.name")
    response = admin_api.post("/users", json=_payload(company.id, username="Taken.Name"))
    assert response.status_code == 409
    errors = response.get_json()["errors"]
    assert errors["code"] == "username_taken"
    assert "username" in errors["fields"]


@pytest.mark.parametrize(
    ("overrides", "field"),
    [
        ({"username": "ab"}, "username"),
        ({"username": "has space"}, "username"),
        ({"username": "کاربر"}, "username"),
        ({"username": "a" * 101}, "username"),
        ({"full_name": "x"}, "full_name"),
        ({"password": "short"}, "password"),
        ({"password": "x" * 129}, "password"),
        ({"password": "new.employee"}, "password"),
        ({"company_id": "not-a-uuid"}, "company_id"),
        ({"company_id": str(uuid.uuid4())}, "company_id"),
        ({"company_id": None}, "company_id"),
        ({"password_hash": "$argon2id$..."}, "password_hash"),
    ],
)
def test_create_employee_validation(admin_api: Api, factory: Factory, overrides: dict[str, object], field: str) -> None:
    company = factory.company()
    response = admin_api.post("/users", json=_payload(company.id, **overrides))
    assert response.status_code == 422, response.get_json()
    assert field in response.get_json()["errors"]["fields"]


def test_list_users_with_filters(admin_api: Api, factory: Factory) -> None:
    first, second = factory.company(), factory.company()
    factory.employee(first, username="alpha.one", full_name="علی رضایی")
    factory.employee(first, username="alpha.two", is_active=False)
    factory.employee(second, username="beta.one")

    everyone = admin_api.get("/users").get_json()["data"]
    assert everyone["pagination"]["total"] == 4  # three employees and the administrator

    by_company = admin_api.get(f"/users?company_id={first.id}").get_json()["data"]["items"]
    assert {item["username"] for item in by_company} == {"alpha.one", "alpha.two"}
    active = admin_api.get(f"/users?company_id={first.id}&is_active=true").get_json()["data"]["items"]
    assert [item["username"] for item in active] == ["alpha.one"]
    admins = admin_api.get("/users?role=SUPER_ADMIN").get_json()["data"]["items"]
    assert len(admins) == 1
    by_name = admin_api.get("/users?q=رضایی").get_json()["data"]["items"]
    assert [item["username"] for item in by_name] == ["alpha.one"]
    assert admin_api.get("/users?role=CUSTOMER").status_code == 422


def test_get_user_and_unknown_user(admin_api: Api, factory: Factory) -> None:
    employee = factory.employee()
    assert admin_api.get(f"/users/{employee.id}").get_json()["data"]["username"] == employee.username
    assert admin_api.get(f"/users/{uuid.uuid4()}").status_code == 404


def test_update_employee_profile(admin_api: Api, factory: Factory) -> None:
    employee = factory.employee()
    response = admin_api.patch(f"/users/{employee.id}", json={"full_name": "نام تازه", "username": "Renamed.User"})
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert data["full_name"] == "نام تازه"
    assert data["username"] == "renamed.user"
    assert factory.audit_actions()[-1] == "USER_UPDATED"


def test_password_cannot_be_changed_through_the_update_endpoint(admin_api: Api, factory: Factory) -> None:
    employee = factory.employee()
    response = admin_api.patch(f"/users/{employee.id}", json={"password": NEW_PASSWORD})
    assert response.status_code == 422


def test_moving_an_employee_to_another_company_ends_their_sessions(admin_api: Api, factory: Factory) -> None:
    old_company, new_company = factory.company(), factory.company()
    employee = factory.employee(old_company)
    session = factory.login(employee)

    response = admin_api.patch(f"/users/{employee.id}", json={"company_id": str(new_company.id)})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["company"]["id"] == str(new_company.id)
    assert session.get("/auth/me").status_code == 401

    fresh = factory.login(employee)
    assert fresh.get("/auth/me").get_json()["data"]["user"]["company"]["id"] == str(new_company.id)


def test_deactivating_an_employee_ends_their_sessions_and_blocks_login(
    admin_api: Api, api: Api, factory: Factory
) -> None:
    employee = factory.employee()
    tokens = factory.tokens(employee)

    response = admin_api.patch(f"/users/{employee.id}", json={"is_active": False})
    assert response.status_code == 200
    assert response.get_json()["data"]["is_active"] is False
    assert factory.audit_actions()[-1] == "USER_DEACTIVATED"

    assert Api(api._app, tokens.access_token).get("/auth/me").status_code == 401
    assert api.post("/auth/refresh", json={"refresh_token": tokens.refresh_token}).status_code == 401
    assert api.login(employee.username).status_code == 403

    # Re-activation restores login, but the sessions that were revoked stay revoked.
    admin_api.patch(f"/users/{employee.id}", json={"is_active": True})
    assert api.login(employee.username).status_code == 200
    assert Api(api._app, tokens.access_token).get("/auth/me").status_code == 401


def test_admin_password_reset_revokes_sessions(admin_api: Api, api: Api, factory: Factory) -> None:
    employee = factory.employee()
    session = factory.login(employee)
    response = admin_api.post(f"/users/{employee.id}/reset-password", json={"new_password": NEW_PASSWORD})
    assert response.status_code == 200, response.get_json()
    assert NEW_PASSWORD not in response.get_data(as_text=True)
    assert session.get("/auth/me").status_code == 401
    assert api.login(employee.username, DEFAULT_PASSWORD).status_code == 401
    assert api.login(employee.username, NEW_PASSWORD).status_code == 200
    assert "USER_PASSWORD_RESET" in factory.audit_actions()


def test_password_reset_enforces_the_policy(admin_api: Api, factory: Factory) -> None:
    employee = factory.employee()
    response = admin_api.post(f"/users/{employee.id}/reset-password", json={"new_password": "short"})
    assert response.status_code == 422
    assert "new_password" in response.get_json()["errors"]["fields"]


def test_super_admin_accounts_are_not_manageable_through_the_api(admin_api: Api, factory: Factory) -> None:
    other_admin = factory.admin()
    for response in (
        admin_api.patch(f"/users/{other_admin.id}", json={"is_active": False}),
        admin_api.post(f"/users/{other_admin.id}/reset-password", json={"new_password": NEW_PASSWORD}),
    ):
        assert response.status_code == 403
        assert response.get_json()["errors"]["code"] == "admin_account_protected"
    assert factory.get(User, other_admin.id).is_active is True


def test_users_cannot_be_deleted(admin_api: Api, factory: Factory) -> None:
    employee = factory.employee()
    assert admin_api.delete(f"/users/{employee.id}").status_code == 405
