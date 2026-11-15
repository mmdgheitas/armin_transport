"""Persistent SQLite deployment and WAL concurrency regression coverage."""

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Lock

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.exc import OperationalError

from app import create_app
from app.config import load_settings
from app.core.sqlite_retry import retry_sqlite_request
from app.extensions import db
from app.models import Company, Document
from tests.support import Api, upload_file


def test_sqlite_connection_enables_integrity_wal_and_durability(app):
    with app.app_context(), db.engine.connect() as connection:
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar() == 1
        assert connection.exec_driver_sql("PRAGMA journal_mode").scalar() == "wal"
        assert connection.exec_driver_sql("PRAGMA busy_timeout").scalar() == 30000
        assert connection.exec_driver_sql("PRAGMA synchronous").scalar() == 2


def test_production_sqlite_file_survives_application_restart(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'production.sqlite3'}"
    settings = load_settings(
        "production",
        environ={
            "DATABASE_URL": url,
            "JWT_SECRET_KEY": "test-deployment-key-" * 4,
            "STORAGE_ROOT": str(tmp_path / "storage"),
        },
    )
    overrides = {
        "database_url": settings.database_url,
        "jwt_secret_key": settings.jwt_secret_key,
        "storage_root": settings.storage_root,
    }
    monkeypatch.setenv("JWT_SECRET_KEY", settings.jwt_secret_key)
    first = create_app("production", overrides=overrides)
    with first.app_context():
        db.create_all()
        db.session.add(Company(name="شرکت پایدار", company_code="PERSIST"))
        db.session.commit()
        db.session.remove()
        db.engine.dispose()
    second = create_app("production", overrides=overrides)
    with second.app_context():
        assert db.session.scalar(select(Company.name)) == "شرکت پایدار"
        db.session.remove()
        db.engine.dispose()


def test_parallel_uploads_retry_snapshot_and_preserve_employee_quota(factory, services, app, monkeypatch):
    employee = factory.employee()
    company = employee.company
    shipment = factory.shipment(company, employee)
    api = factory.login(employee)
    response = api.upload(shipment.id, [upload_file(f"initial{i}.bin", b"initial") for i in range(11)])
    assert response.status_code == 201
    barrier, lock = Barrier(2), Lock()
    staged_count = 0
    original_stage = services.documents._stage

    def stage_with_overlap(incoming):
        nonlocal staged_count
        result = original_stage(incoming)
        with lock:
            staged_count += 1
            first_attempt = staged_count <= 2
        if first_attempt:
            barrier.wait(timeout=10)
        return result

    monkeypatch.setattr(services.documents, "_stage", stage_with_overlap)

    def upload(index):
        return Api(app, api.token).upload(shipment.id, [upload_file(f"parallel{index}.bin", b"complete bytes")])

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(upload, range(2)))
    assert sorted(response.status_code for response in results) == [201, 422], [r.get_json() for r in results]
    assert staged_count >= 3  # At least one request had to restart from a fresh snapshot.
    items = api.get(f"/shipments/{shipment.id}/documents").get_json()["data"]["items"]
    assert len(items) == 12
    uploaded = next(item for item in items if item["original_name"].startswith("parallel"))
    assert api.get(f"/documents/{uploaded['id']}/download").data == b"complete bytes"
    with app.app_context():
        assert (
            db.session.scalar(select(func.count()).select_from(Document).where(Document.shipment_id == shipment.id))
            == 12
        )


def test_parallel_refresh_cannot_rotate_the_same_token_twice(factory, services, app, monkeypatch):
    employee = factory.employee()
    tokens = factory.tokens(employee)
    # Disabling the independent limiter *for this scenario* lets both requests
    # read the same old token before either has written a new token.
    monkeypatch.setattr(services.rate_limiter, "_enabled", False)
    barrier, lock = Barrier(2), Lock()
    attempts = 0
    original_issue = services.auth._issue

    def issue_with_overlap(*args, **kwargs):
        nonlocal attempts
        with lock:
            attempts += 1
            first_attempt = attempts <= 2
        if first_attempt:
            barrier.wait(timeout=10)
        return original_issue(*args, **kwargs)

    monkeypatch.setattr(services.auth, "_issue", issue_with_overlap)

    def refresh(_):
        return Api(app).post("/auth/refresh", json={"refresh_token": tokens.refresh_token})

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(refresh, range(2)))
    assert sorted(response.status_code for response in results) == [200, 401], [r.get_json() for r in results]
    # Reuse detection revokes the original family, including the winning rotation.
    assert Api(app, tokens.access_token).get("/auth/me").status_code == 401


def busy_error():
    original = sqlite3.OperationalError("database is locked")
    original.sqlite_errorcode = sqlite3.SQLITE_BUSY
    return OperationalError("statement", {}, original)


def test_retry_never_replays_a_committed_request(app):
    calls = 0
    with app.test_request_context("/test"):

        @retry_sqlite_request
        def committed_then_failed():
            nonlocal calls
            calls += 1
            db.session.execute(text("SELECT 1"))
            db.session.commit()
            raise busy_error()

        with pytest.raises(OperationalError):
            committed_then_failed()
    assert calls == 1


def test_retry_can_restart_after_a_savepoint_but_not_after_outer_commit(app):
    calls = 0
    with app.test_request_context("/test"):

        @retry_sqlite_request
        def savepoint_then_failed():
            nonlocal calls
            calls += 1
            with db.session.begin_nested():
                db.session.execute(text("SELECT 1"))
            if calls == 1:
                raise busy_error()
            db.session.commit()
            return "ok"

        assert savepoint_then_failed() == "ok"
    assert calls == 2
