"""Flask extension instances (initialized in the application factory)."""

from __future__ import annotations

from typing import cast

from flask_migrate import Migrate
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase, Session, scoped_session

# Deterministic constraint names keep Alembic migrations stable and reviewable.
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Declarative base shared by every model."""

    metadata = MetaData(naming_convention=NAMING_CONVENTION)


# Sessions are request-scoped and short-lived, so objects stay usable after commit
# (no re-SELECT of every row when a response is serialized after the commit).
db = SQLAlchemy(model_class=Base, session_options={"expire_on_commit": False})
migrate = Migrate()


def scoped_db_session() -> scoped_session[Session]:
    """The request-scoped session, typed with the plain SQLAlchemy ``Session`` interface."""
    return cast("scoped_session[Session]", db.session)
