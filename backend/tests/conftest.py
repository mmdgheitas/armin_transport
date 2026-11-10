"""Shared pytest fixtures.

The suite runs against the database given by ``TEST_DATABASE_URL`` (MySQL 8 in CI
and during development). Without it, a temporary SQLite file is used so the
suite stays runnable everywhere; tests that need real MySQL semantics are marked
``@pytest.mark.mysql`` and skipped on the fallback.
"""

from __future__ import annotations

import logging
import os
import shutil
import tempfile
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest
from flask import Flask

from app import create_app
from app.config import Settings
from app.container import Services
from app.extensions import db
from tests.support import Api, Factory

os.environ.setdefault("APP_ENV", "testing")


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("TEST_DATABASE_URL", "").startswith("mysql"):
        return
    skip = pytest.mark.skip(reason="requires MySQL (set TEST_DATABASE_URL)")
    for item in items:
        if "mysql" in item.keywords:
            item.add_marker(skip)


@pytest.fixture(scope="session")
def storage_root() -> Iterator[Path]:
    root = Path(tempfile.mkdtemp(prefix="armin-test-storage-"))
    yield root
    shutil.rmtree(root, ignore_errors=True)


@pytest.fixture(scope="session")
def app(storage_root: Path) -> Iterator[Flask]:
    application = create_app("testing", overrides={"storage_root": storage_root})
    with application.app_context():
        db.drop_all()
        db.create_all()
    yield application
    with application.app_context():
        db.session.remove()
        db.drop_all()
        db.engine.dispose()
    settings: Settings = application.extensions["settings"]
    if settings.database_dialect == "sqlite":
        for suffix in ("", "-wal", "-shm"):
            Path(settings.database_url.removeprefix("sqlite:///") + suffix).unlink(missing_ok=True)


@pytest.fixture(autouse=True)
def clean_database(app: Flask) -> Iterator[None]:
    """Every test starts with empty tables (also resets the rate-limit counters)."""
    yield
    with app.app_context():
        db.session.remove()
        with db.engine.begin() as connection:
            for table in reversed(db.metadata.sorted_tables):
                connection.execute(table.delete())


@pytest.fixture
def app_context(app: Flask) -> Iterator[None]:
    with app.app_context():
        yield
        db.session.remove()


@pytest.fixture
def services(app: Flask) -> Services:
    result: Services = app.extensions["services"]
    return result


@pytest.fixture
def settings(app: Flask) -> Settings:
    result: Settings = app.extensions["settings"]
    return result


@pytest.fixture
def factory(app: Flask) -> Factory:
    return Factory(app)


@pytest.fixture
def api(app: Flask) -> Api:
    """Anonymous API client."""
    return Api(app)


@pytest.fixture
def make_app(storage_root: Path, caplog: pytest.LogCaptureFixture) -> Iterator[Callable[..., Flask]]:
    """Build additional applications with different settings on the same test database."""
    created: list[Flask] = []

    def build(**overrides: Any) -> Flask:
        application = create_app("testing", overrides={"storage_root": storage_root, **overrides})
        created.append(application)
        # create_app() reconfigures logging, which detaches pytest's capture handler: re-attach it.
        root_logger = logging.getLogger()
        if caplog.handler not in root_logger.handlers:
            root_logger.addHandler(caplog.handler)
        return application

    yield build
    for application in created:
        with application.app_context():
            db.session.remove()
            db.engine.dispose()


@pytest.fixture
def is_mysql(settings: Settings) -> bool:
    return settings.database_dialect == "mysql"
