"""Armin Transport backend: application factory."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

from flask import Blueprint, Flask
from flask_cors import CORS
from sqlalchemy import event
from sqlalchemy.engine import Connection
from sqlalchemy.pool import ConnectionPoolEntry
from werkzeug.middleware.proxy_fix import ProxyFix

from app.cli import register_cli
from app.config import BACKEND_ROOT, Settings, flask_config, load_settings
from app.container import build_services
from app.core.error_handlers import register_error_handlers
from app.core.http import register_request_hooks
from app.core.logging import configure_logging
from app.core.openapi import build_openapi_document
from app.extensions import db, migrate
from app.modules.audit_logs.routes import bp as audit_logs_bp
from app.modules.auth.routes import bp as auth_bp
from app.modules.companies.routes import bp as companies_bp
from app.modules.customer_access.routes import bp as customer_bp
from app.modules.dashboard.routes import bp as dashboard_bp
from app.modules.documents.routes import bp as documents_bp
from app.modules.health.routes import bp as health_bp
from app.modules.product_fields.routes import bp as product_fields_bp
from app.modules.shipments.routes import bp as shipments_bp
from app.modules.users.routes import bp as users_bp
from app.web import create_web_blueprint

API_PREFIX = "/api/v1"


def _configure_sqlite(app: Flask) -> None:
    """Configure SQLite for persistent use: foreign keys, WAL and explicit transactions."""
    with app.app_context():
        engine = db.engine

    @event.listens_for(engine, "connect")
    def _on_connect(dbapi_connection: Any, _record: ConnectionPoolEntry) -> None:
        # Hand transaction control to SQLAlchemy; pysqlite's implicit BEGIN breaks SAVEPOINTs.
        dbapi_connection.isolation_level = None
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.execute("PRAGMA busy_timeout=30000")
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA synchronous=FULL")
        cursor.close()

    @event.listens_for(engine, "begin")
    def _on_begin(connection: Connection) -> None:
        connection.exec_driver_sql("BEGIN")


def _register_blueprints(app: Flask) -> None:
    docs_bp = Blueprint("docs", __name__)

    @docs_bp.get("/openapi.json")
    def openapi_document() -> Any:
        document = app.extensions.get("openapi_document")
        if document is None:
            document = build_openapi_document(app)
            app.extensions["openapi_document"] = document
        return document

    for blueprint in (
        health_bp,
        auth_bp,
        dashboard_bp,
        companies_bp,
        users_bp,
        shipments_bp,
        documents_bp,
        product_fields_bp,
        customer_bp,
        audit_logs_bp,
        docs_bp,
    ):
        app.register_blueprint(blueprint, url_prefix=API_PREFIX)


def create_app(env_name: str | None = None, overrides: Mapping[str, Any] | None = None) -> Flask:
    """Create and configure the Flask application.

    ``env_name`` defaults to ``APP_ENV`` (``development`` when unset). ``overrides``
    replaces individual :class:`~app.config.Settings` fields (used by tests).
    """
    settings: Settings = load_settings(env_name, overrides=overrides)
    configure_logging(settings)

    app = Flask(__name__, static_folder=None)
    app.config.update(flask_config(settings))
    app.json.ensure_ascii = False  # type: ignore[attr-defined]
    app.json.sort_keys = False  # type: ignore[attr-defined]
    app.extensions["settings"] = settings

    if settings.trusted_proxy_count:
        count = settings.trusted_proxy_count
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=count, x_proto=count, x_host=count)  # type: ignore[method-assign]

    # Flask resolves relative SQLite filenames under this private instance directory.
    Path(app.instance_path).mkdir(parents=True, exist_ok=True)
    db.init_app(app)
    migrate.init_app(app, db, directory=str(BACKEND_ROOT / "migrations"), compare_type=True)
    if settings.database_dialect == "sqlite":
        _configure_sqlite(app)

    services = build_services(settings)
    services.storage.ensure_ready()
    app.extensions["services"] = services

    register_request_hooks(app, settings)
    register_error_handlers(app)
    _register_blueprints(app)

    if settings.cors_allowed_origins:
        CORS(
            app,
            resources={f"{API_PREFIX}/*": {"origins": list(settings.cors_allowed_origins)}},
            supports_credentials=False,
            allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
            expose_headers=["Content-Disposition", "Content-Length", "X-Request-ID", "Retry-After"],
            max_age=600,
        )

    if settings.serve_web_app and settings.web_app_dir is not None:
        app.register_blueprint(create_web_blueprint(settings.web_app_dir))

    register_cli(app)
    return app


__all__ = ["API_PREFIX", "create_app"]
