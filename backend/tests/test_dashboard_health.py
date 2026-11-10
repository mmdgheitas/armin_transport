"""Dashboard counters and the liveness/readiness probes."""

from __future__ import annotations

import os
import shutil
from collections.abc import Callable
from pathlib import Path

import pytest
from flask import Flask

from app.config import Settings
from app.models import ShipmentStatus
from tests.support import Api, Factory


# --------------------------------------------------------------------------- dashboard
def test_admin_dashboard_counts_the_whole_system(factory: Factory) -> None:
    admin = factory.admin()
    factory.admin(is_active=False)  # administrators are not "employees"
    alpha, beta = factory.company(), factory.company(is_active=False)
    sara, reza = factory.employee(alpha), factory.employee(alpha, is_active=False)
    omid = factory.employee(beta)
    first = factory.shipment(alpha, sara)
    factory.shipment(alpha, reza, status=ShipmentStatus.ARCHIVED)
    third = factory.shipment(beta, omid)
    factory.document(first, sara)
    factory.document(first, sara, deleted_at=first.created_at, deleted_by=sara.id)  # soft-deleted: not counted
    factory.document(third, omid)

    data = factory.login(admin).get("/dashboard/summary").get_json()["data"]
    assert data["scope"] == "GLOBAL"
    assert data["company"] is None
    assert data["companies"] == {"total": 2, "active": 1}
    assert data["employees"] == {"total": 3, "active": 2}
    assert data["shipments"] == {"total": 3, "active": 2, "archived": 1}
    assert data["documents"] == 2
    assert len(data["recent_shipments"]) == 3


def test_employee_dashboard_is_limited_to_the_own_company(factory: Factory) -> None:
    company, other = factory.company(name="شرکت من"), factory.company()
    employee, colleague, stranger = factory.employee(company), factory.employee(company), factory.employee(other)
    mine = factory.shipment(company, employee)
    factory.shipment(company, colleague, status=ShipmentStatus.ARCHIVED)
    foreign = factory.shipment(other, stranger)
    factory.document(mine, employee)
    factory.document(foreign, stranger)
    factory.document(foreign, stranger)

    data = factory.login(employee).get("/dashboard/summary").get_json()["data"]
    assert data["scope"] == "COMPANY"
    assert data["company"] == {
        "id": str(company.id),
        "name": "شرکت من",
        "company_code": company.company_code,
        "is_active": True,
    }
    assert data["companies"] is None
    assert data["employees"] is None
    assert data["shipments"] == {"total": 2, "active": 1, "archived": 1}  # colleagues' shipments are shared
    assert data["documents"] == 1
    assert str(foreign.id) not in {item["id"] for item in data["recent_shipments"]}


def test_recent_shipments_are_the_newest_five(factory: Factory) -> None:
    company = factory.company()
    employee = factory.employee(company)
    client = factory.login(employee)
    created = [
        client.post("/shipments", json={"description": f"شماره {index}"}).get_json()["data"]["id"] for index in range(7)
    ]
    recent = client.get("/dashboard/summary").get_json()["data"]["recent_shipments"]
    assert [item["id"] for item in recent] == list(reversed(created))[:5]
    assert {"tracking_code", "status", "company", "created_by", "document_count"} <= set(recent[0])


def test_empty_system_dashboard(factory: Factory) -> None:
    data = factory.login(factory.admin()).get("/dashboard/summary").get_json()["data"]
    assert data["companies"] == {"total": 0, "active": 0}
    assert data["employees"] == {"total": 0, "active": 0}
    assert data["shipments"] == {"total": 0, "active": 0, "archived": 0}
    assert data["documents"] == 0
    assert data["recent_shipments"] == []


# --------------------------------------------------------------------------- health
def test_liveness_probe(api: Api, settings: Settings) -> None:
    response = api.get("/health")
    assert response.status_code == 200
    body = response.get_json()
    assert body["success"] is True
    assert body["data"]["status"] == "ok"
    assert body["data"]["version"] == settings.app_version
    assert body["data"]["time"].endswith("Z")
    assert response.headers["Cache-Control"] == "no-store"


def test_readiness_probe_reports_ready(api: Api) -> None:
    response = api.get("/health/ready")
    assert response.status_code == 200
    assert response.get_json()["data"] == {"status": "ready", "checks": {"database": "ok", "storage": "ok"}}


def _unreachable_database_url(settings: Settings, tmp_path: Path) -> str:
    if settings.database_dialect == "mysql":
        return "mysql+pymysql://probe-user:Pr0be-Secret-Value@127.0.0.1:9/armin_unreachable?charset=utf8mb4"
    return f"sqlite:///{tmp_path / 'missing-directory' / 'Pr0be-Secret-Value.sqlite3'}"


def test_readiness_fails_without_the_database_and_reveals_nothing(
    make_app: Callable[..., Flask], settings: Settings, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    broken = make_app(database_url=_unreachable_database_url(settings, tmp_path))
    client = Api(broken)

    assert client.get("/health").status_code == 200  # liveness does not depend on the database

    response = client.get("/health/ready")
    assert response.status_code == 503
    body = response.get_json()
    assert body["success"] is False
    assert body["errors"]["code"] == "not_ready"
    assert body["errors"]["checks"] == {"database": "unavailable", "storage": "ok"}
    raw = response.get_data(as_text=True)
    for secret in ("Pr0be-Secret-Value", "probe-user", "pymysql", "sqlite", "Traceback", "127.0.0.1"):
        assert secret not in raw
    assert "Readiness probe: database check failed" in caplog.text


def test_api_fails_closed_when_the_database_is_down(
    make_app: Callable[..., Flask], settings: Settings, tmp_path: Path
) -> None:
    broken = make_app(database_url=_unreachable_database_url(settings, tmp_path))
    response = Api(broken).login("anyone", "some-password-1")
    assert response.status_code == 503
    body = response.get_json()
    assert body["errors"]["code"] == "service_unavailable"
    assert "Pr0be-Secret-Value" not in response.get_data(as_text=True)


@pytest.mark.skipif(os.geteuid() == 0, reason="root ignores directory permissions")
def test_readiness_fails_when_storage_is_not_writable(make_app: Callable[..., Flask], tmp_path: Path) -> None:
    storage = tmp_path / "storage"
    application = make_app(storage_root=storage)
    client = Api(application)
    assert client.get("/health/ready").status_code == 200

    for directory in (storage, *[path for path in storage.rglob("*") if path.is_dir()]):
        directory.chmod(0o500)
    try:
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert response.get_json()["errors"]["checks"] == {"database": "ok", "storage": "unavailable"}
    finally:
        for directory in (storage, *[path for path in storage.rglob("*") if path.is_dir()]):
            directory.chmod(0o700)

    # A storage directory that disappeared is re-created on demand (first start, cleaned temp dir).
    shutil.rmtree(storage)
    assert client.get("/health/ready").status_code == 200
    assert storage.is_dir()


def test_health_endpoints_are_public_but_read_only(api: Api) -> None:
    assert api.post("/health").status_code == 405
    assert api.delete("/health/ready").status_code == 405
