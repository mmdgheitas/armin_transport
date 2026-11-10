"""Operational CLI commands (``flask create-admin`` and friends)."""

from __future__ import annotations

import json
import os
import time
from datetime import timedelta
from pathlib import Path

import pytest
from click.testing import Result
from flask import Flask
from openapi_spec_validator import validate

from app.config import Settings
from app.core.datetime_utils import utcnow
from app.core.security import hash_token
from app.extensions import db
from app.models import (
    AuditLog,
    Company,
    CustomerAccessSession,
    ProductFieldDefinition,
    RateLimitCounter,
    RefreshToken,
    Shipment,
    ShipmentProductValue,
    User,
    UserRole,
)
from app.modules.documents.storage import TEMP_DIRECTORY_NAME
from tests.support import DEFAULT_PASSWORD, Api, Factory

STRONG_PASSWORD = "Cli-Created-Passw0rd"


def _run(app: Flask, *args: str, env: dict[str, str] | None = None, stdin: str | None = None) -> Result:
    result = app.test_cli_runner().invoke(args=list(args), env=env, input=stdin)
    with app.app_context():
        db.session.remove()
    return result


# --------------------------------------------------------------------------- create-admin
def test_create_admin_with_password_from_the_environment(app: Flask, factory: Factory) -> None:
    result = _run(
        app,
        "create-admin",
        "--username",
        "Root.Admin",
        "--full-name",
        "مدیر ارشد",
        env={"ADMIN_PASSWORD": STRONG_PASSWORD},
    )
    assert result.exit_code == 0, result.output
    assert "root.admin" in result.output  # normalized to lower case
    assert STRONG_PASSWORD not in result.output

    with app.app_context():
        user = db.session.scalar(db.select(User).where(User.username == "root.admin"))
        assert user is not None
        assert user.role is UserRole.SUPER_ADMIN and user.company_id is None and user.is_active
        assert user.password_hash.startswith("$argon2id$")
        entry = db.session.scalar(db.select(AuditLog).where(AuditLog.action == "ADMIN_CREATED"))
        assert entry is not None and entry.meta == {"username": "root.admin", "source": "cli"}
        assert entry.user_id is None and entry.ip_address is None
        db.session.remove()

    login = Api(app).login("root.admin", STRONG_PASSWORD)
    assert login.status_code == 200
    assert login.get_json()["data"]["user"]["role"] == "SUPER_ADMIN"


def test_create_admin_prompts_for_the_password_without_echoing_it(app: Flask) -> None:
    result = _run(
        app,
        "create-admin",
        "--username",
        "prompted",
        "--full-name",
        "مدیر",
        stdin=f"{STRONG_PASSWORD}\n{STRONG_PASSWORD}\n",
    )
    assert result.exit_code == 0, result.output
    assert STRONG_PASSWORD not in result.output
    assert Api(app).login("prompted", STRONG_PASSWORD).status_code == 200


def test_create_admin_accepts_the_password_option(app: Flask) -> None:
    result = _run(app, "create-admin", "--username", "optioned", "--full-name", "مدیر", "--password", STRONG_PASSWORD)
    assert result.exit_code == 0, result.output
    assert Api(app).login("optioned", STRONG_PASSWORD).status_code == 200


@pytest.mark.parametrize(
    ("username", "full_name", "password", "fragment"),
    [
        ("weakling", "مدیر", "short", "password"),
        ("weakling", "مدیر", "weakling-weakling", "password"),  # contains the username
        ("bad name!", "مدیر", STRONG_PASSWORD, "username"),
        ("validname", "م", STRONG_PASSWORD, "full_name"),
    ],
)
def test_create_admin_applies_the_same_validation_as_the_api(
    app: Flask, factory: Factory, username: str, full_name: str, password: str, fragment: str
) -> None:
    result = _run(
        app, "create-admin", "--username", username, "--full-name", full_name, env={"ADMIN_PASSWORD": password}
    )
    assert result.exit_code == 1
    assert result.output.startswith("Error: ")
    assert fragment in result.output
    assert "Traceback" not in result.output
    assert factory.count(User) == 0


def test_create_admin_refuses_a_taken_username(app: Flask, factory: Factory) -> None:
    factory.employee(username="taken")
    result = _run(
        app, "create-admin", "--username", "TAKEN", "--full-name", "مدیر", env={"ADMIN_PASSWORD": STRONG_PASSWORD}
    )
    assert result.exit_code == 1
    assert factory.count(User) == 1


def test_create_admin_requires_its_options(app: Flask) -> None:
    assert _run(app, "create-admin").exit_code == 2
    assert _run(app, "create-admin", "--username", "only").exit_code == 2


# --------------------------------------------------------------------------- seed-demo
def test_seed_demo_creates_a_usable_data_set(app: Flask, factory: Factory) -> None:
    result = _run(app, "seed-demo", env={"DEMO_PASSWORD": DEFAULT_PASSWORD})
    assert result.exit_code == 0, result.output
    assert "Seeded 2 companies, 7 product fields, 5 shipments." in result.output
    assert "Administrator: admin" in result.output
    assert "armin.operator" in result.output and "pars.operator" in result.output
    assert DEFAULT_PASSWORD not in result.output  # a supplied password is never echoed

    assert factory.count(Company) == 2
    assert factory.count(User) == 4
    assert factory.count(ProductFieldDefinition) == 7
    assert factory.count(Shipment) == 5
    assert factory.count(ShipmentProductValue) == 5 * 7

    # The seeded accounts work and tenant isolation applies to them.
    admin_api, armin_api, pars_api = (Api(app) for _ in range(3))
    for client, username in ((admin_api, "admin"), (armin_api, "armin.operator"), (pars_api, "pars.operator")):
        login = client.login(username)
        assert login.status_code == 200, login.get_json()
        client.token = login.get_json()["data"]["access_token"]
    assert admin_api.get("/shipments").get_json()["data"]["pagination"]["total"] == 5
    assert armin_api.get("/shipments").get_json()["data"]["pagination"]["total"] == 3
    assert pars_api.get("/shipments").get_json()["data"]["pagination"]["total"] == 2

    # A printed sample tracking code opens the customer portal.
    code = result.output.split("Sample tracking codes: ")[1].splitlines()[0].split(", ")[0]
    assert Api(app).post("/customer/lookup", json={"tracking_code": code}).status_code == 200


def test_seed_demo_is_idempotent(app: Flask, factory: Factory) -> None:
    assert _run(app, "seed-demo", env={"DEMO_PASSWORD": DEFAULT_PASSWORD}).exit_code == 0
    again = _run(app, "seed-demo", env={"DEMO_PASSWORD": "A-Different-Passw0rd"})
    assert again.exit_code == 0, again.output
    assert "Seeded 0 companies, 0 product fields, 0 shipments." in again.output
    assert factory.count(User) == 4 and factory.count(Shipment) == 5
    assert Api(app).login("admin", DEFAULT_PASSWORD).status_code == 200  # existing accounts are left untouched


def test_seed_demo_generates_and_prints_a_password_when_none_is_given(app: Flask) -> None:
    result = _run(app, "seed-demo")
    assert result.exit_code == 0, result.output
    password = result.output.split("Generated password for new demo accounts: ")[1].strip()
    assert len(password) >= 16
    assert Api(app).login("admin", password).status_code == 200


def test_seed_demo_rejects_a_weak_password_without_partial_data(app: Flask, factory: Factory) -> None:
    result = _run(app, "seed-demo", "--password", "weak")
    assert result.exit_code == 1
    assert factory.count(User) == 0 and factory.count(Company) == 0


def test_seed_demo_refuses_to_run_in_production(app: Flask, factory: Factory, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(Settings, "is_production", property(lambda _self: True))
    result = _run(app, "seed-demo", env={"DEMO_PASSWORD": DEFAULT_PASSWORD})
    assert result.exit_code == 1
    assert "production" in result.output
    assert factory.count(User) == 0


# --------------------------------------------------------------------------- purge-expired
def test_purge_expired_removes_only_stale_records(app: Flask, factory: Factory, storage_root: Path) -> None:
    company = factory.company()
    employee = factory.employee(company)
    shipment = factory.shipment(company, employee)
    stale_session, live_session = factory.tokens(employee), factory.tokens(employee)
    anonymous = Api(app)
    old_grant = anonymous.post("/customer/lookup", json={"tracking_code": shipment.tracking_code}).get_json()["data"]
    new_grant = anonymous.post("/customer/lookup", json={"tracking_code": shipment.tracking_code}).get_json()["data"]

    past = utcnow() - timedelta(days=40)
    with app.app_context():
        stale_hash = hash_token(stale_session.refresh_token)
        db.session.execute(db.update(RefreshToken).where(RefreshToken.token_hash == stale_hash).values(expires_at=past))
        old_hash = hash_token(old_grant["access_token"])
        db.session.execute(
            db.update(CustomerAccessSession).where(CustomerAccessSession.token_hash == old_hash).values(expires_at=past)
        )
        counters_before = db.session.scalar(db.select(db.func.count()).select_from(RateLimitCounter))
        db.session.add(RateLimitCounter(scope="test", key_hash="0" * 64, window_start=1, count=3, expires_at=past))
        db.session.commit()
        db.session.remove()

    temp_directory = storage_root / TEMP_DIRECTORY_NAME
    stale_file, fresh_file = temp_directory / "upload-stale.part", temp_directory / "upload-fresh.part"
    stale_file.write_bytes(b"x")
    fresh_file.write_bytes(b"x")
    two_hours_ago = time.time() - 7200
    os.utime(stale_file, (two_hours_ago, two_hours_ago))

    result = _run(app, "purge-expired")
    assert result.exit_code == 0, result.output
    assert result.output.strip() == (
        "Removed 1 refresh tokens, 1 customer sessions, 1 rate-limit counters, 1 temporary files."
    )
    assert not stale_file.exists() and fresh_file.exists()
    fresh_file.unlink()
    assert factory.count(RefreshToken) == 1
    assert factory.count(CustomerAccessSession) == 1
    assert factory.count(RateLimitCounter) == counters_before

    # Live sessions keep working.
    assert anonymous.post("/auth/refresh", json={"refresh_token": live_session.refresh_token}).status_code == 200
    assert anonymous.get(f"/customer/access/{new_grant['access_token']}/shipment").status_code == 200

    assert "Removed 0 refresh tokens, 0 customer sessions, 0 rate-limit counters, 0 temporary files." in (
        _run(app, "purge-expired").output
    )


# --------------------------------------------------------------------------- export-openapi
def test_export_openapi_to_stdout_and_file(app: Flask, tmp_path: Path) -> None:
    printed = _run(app, "export-openapi")
    assert printed.exit_code == 0
    document = json.loads(printed.output)
    validate(document)
    assert document == app.test_client().get("/api/v1/openapi.json").get_json()

    target = tmp_path / "nested" / "openapi.json"
    written = _run(app, "export-openapi", "--output", str(target))
    assert written.exit_code == 0
    assert json.loads(target.read_text(encoding="utf-8")) == document
    assert "ورود" in target.read_text(encoding="utf-8")


def test_database_migration_commands_are_available(app: Flask) -> None:
    result = _run(app, "db", "--help")
    assert result.exit_code == 0
    for command in ("upgrade", "downgrade", "migrate", "current"):
        assert command in result.output
