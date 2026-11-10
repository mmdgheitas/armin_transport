"""Alembic migrations: the migrated schema is exactly the schema the models describe."""

from __future__ import annotations

import uuid
from collections.abc import Callable, Iterator
from pathlib import Path

import flask_migrate
import pytest
import sqlalchemy as sa
from alembic.autogenerate import compare_metadata
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from flask import Flask
from sqlalchemy.engine import make_url

from app.config import Settings
from app.extensions import db
from app.models import Company, ProductFieldDefinition, ProductFieldType, User, UserRole
from tests.support import DEFAULT_PASSWORD, Api

EXPECTED_TABLES = {
    "audit_logs",
    "companies",
    "customer_access_sessions",
    "documents",
    "product_field_definitions",
    "rate_limit_counters",
    "refresh_tokens",
    "shipment_product_values",
    "shipments",
    "tracking_code_history",
    "users",
}


@pytest.fixture
def empty_database_url(settings: Settings, tmp_path: Path) -> Iterator[str]:
    """A brand-new, empty database next to the regular test database."""
    if settings.database_dialect == "sqlite":
        yield f"sqlite:///{tmp_path / 'migrations.sqlite3'}"
        return

    base = make_url(settings.database_url)
    name = f"{base.database}_mig_{uuid.uuid4().hex[:10]}"
    admin_engine = sa.create_engine(base, isolation_level="AUTOCOMMIT")
    try:
        with admin_engine.connect() as connection:
            connection.execute(sa.text(f"CREATE DATABASE `{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"))
        yield base.set(database=name).render_as_string(hide_password=False)
    finally:
        with admin_engine.connect() as connection:
            connection.execute(sa.text(f"DROP DATABASE IF EXISTS `{name}`"))
        admin_engine.dispose()


@pytest.fixture
def migrated_app(make_app: Callable[..., Flask], empty_database_url: str) -> Flask:
    application = make_app(database_url=empty_database_url)
    with application.app_context():
        flask_migrate.upgrade()
        db.session.remove()
    return application


def _table_names(application: Flask) -> set[str]:
    with application.app_context():
        return set(sa.inspect(db.engine).get_table_names())


def test_there_is_exactly_one_migration_head(app: Flask) -> None:
    with app.app_context():
        script = ScriptDirectory.from_config(app.extensions["migrate"].migrate.get_config())
    assert len(script.get_heads()) == 1


def test_upgrade_creates_the_schema_described_by_the_models(migrated_app: Flask) -> None:
    assert _table_names(migrated_app) == EXPECTED_TABLES | {"alembic_version"}
    with migrated_app.app_context(), db.engine.connect() as connection:
        context = MigrationContext.configure(connection, opts={"compare_type": True})
        differences = compare_metadata(context, db.metadata)
    assert differences == []


def test_downgrade_removes_everything_and_upgrade_can_be_repeated(migrated_app: Flask) -> None:
    with migrated_app.app_context():
        flask_migrate.downgrade(revision="base")
    assert _table_names(migrated_app) == {"alembic_version"}
    with migrated_app.app_context():
        flask_migrate.upgrade()
    assert _table_names(migrated_app) == EXPECTED_TABLES | {"alembic_version"}


def test_application_works_on_a_migrated_database(migrated_app: Flask) -> None:
    """End to end on the migrated (not ``create_all``) schema: create an admin, log in, use the API."""
    with migrated_app.app_context():
        services = migrated_app.extensions["services"]
        db.session.add(
            User(
                username="root-admin",
                full_name="مدیر",
                role=UserRole.SUPER_ADMIN,
                password_hash=services.passwords.hash(DEFAULT_PASSWORD),
            )
        )
        db.session.commit()
        db.session.remove()

    client = Api(migrated_app)
    login = client.login("root-admin")
    assert login.status_code == 200, login.get_json()
    client.token = login.get_json()["data"]["access_token"]

    company = client.post("/companies", json={"name": "شرکت مهاجرت", "company_code": "MIG"})
    assert company.status_code == 201, company.get_json()
    shipment = client.post("/shipments", json={"company_id": company.get_json()["data"]["id"]})
    assert shipment.status_code == 201, shipment.get_json()
    assert client.get("/audit-logs").get_json()["data"]["pagination"]["total"] >= 3
    assert client.get("/health/ready").status_code == 200


def test_migrated_schema_enforces_the_data_integrity_rules(migrated_app: Flask) -> None:
    """Constraints are part of the migration, not just of the ORM models."""
    with migrated_app.app_context():
        company = Company(name="الف", company_code="DUP")
        db.session.add(company)
        db.session.commit()

        violations = [
            Company(name="ب", company_code="DUP"),  # unique company code
            User(
                username="orphan", full_name="x", password_hash="x", role=UserRole.EMPLOYEE
            ),  # employee without company
            User(username="scoped", full_name="x", password_hash="x", role=UserRole.SUPER_ADMIN, company_id=company.id),
            User(username="ghost", full_name="x", password_hash="x", role=UserRole.EMPLOYEE, company_id=uuid.uuid4()),
        ]
        for record in violations:
            db.session.add(record)
            # PyMySQL reports a violated CHECK constraint (error 3819) as OperationalError.
            with pytest.raises((sa.exc.IntegrityError, sa.exc.OperationalError)):
                db.session.commit()
            db.session.rollback()
        assert db.session.scalar(sa.select(sa.func.count()).select_from(User)) == 0

        db.session.add(ProductFieldDefinition(field_key="weight", label="وزن", data_type=ProductFieldType.NUMBER))
        db.session.commit()
        db.session.add(ProductFieldDefinition(field_key="weight", label="وزن ۲", data_type=ProductFieldType.TEXT))
        with pytest.raises(sa.exc.IntegrityError):
            db.session.commit()
        db.session.rollback()
        db.session.remove()
