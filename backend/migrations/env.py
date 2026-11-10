"""Alembic environment (driven by Flask-Migrate: ``flask db upgrade`` and friends).

The application factory has already loaded the configuration and set up logging
when this module runs, so it neither reads ``DATABASE_URL`` itself nor
reconfigures logging.
"""

from __future__ import annotations

import logging
from typing import Any

from alembic import context
from alembic.autogenerate.api import AutogenContext
from alembic.operations.ops import MigrationScript
from alembic.runtime.migration import MigrationContext
from flask import current_app
from sqlalchemy import MetaData
from sqlalchemy.engine import Engine

from app.core.db_types import UTCDateTime

config = context.config
logger = logging.getLogger("alembic.env")
logging.getLogger("alembic").setLevel(logging.INFO)


def _engine() -> Engine:
    engine: Engine = current_app.extensions["migrate"].db.engine
    return engine


def _metadata() -> MetaData:
    metadata: MetaData = current_app.extensions["migrate"].db.metadata
    return metadata


def render_item(type_: str, obj: Any, autogen_context: AutogenContext) -> str | bool:
    """Render application column types with plain SQLAlchemy constructs.

    Migrations are historical records: they must keep working when application
    code changes, so they never import from the ``app`` package.
    """
    if type_ == "type" and isinstance(obj, UTCDateTime):
        autogen_context.imports.add("from sqlalchemy.dialects import mysql")
        return "sa.DateTime().with_variant(mysql.DATETIME(fsp=6), 'mysql')"
    return False


def _skip_empty_revision(_context: MigrationContext, _revision: Any, directives: list[MigrationScript]) -> None:
    """Do not create a migration file when autogenerate finds no schema change."""
    if getattr(config.cmd_opts, "autogenerate", False) and directives[0].upgrade_ops.is_empty():
        directives[:] = []
        logger.info("No changes in schema detected.")


def _configure_args() -> dict[str, Any]:
    arguments: dict[str, Any] = dict(current_app.extensions["migrate"].configure_args)
    arguments.setdefault("process_revision_directives", _skip_empty_revision)
    arguments.setdefault("render_item", render_item)
    return arguments


def run_migrations_offline() -> None:
    """Emit SQL to stdout instead of executing it (``flask db upgrade --sql``)."""
    url = _engine().url.render_as_string(hide_password=False)
    context.configure(url=url, target_metadata=_metadata(), literal_binds=True, **_configure_args())
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    with _engine().connect() as connection:
        context.configure(connection=connection, target_metadata=_metadata(), **_configure_args())
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
