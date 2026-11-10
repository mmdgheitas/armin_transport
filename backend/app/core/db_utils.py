"""Small typed helpers around SQLAlchemy Core results."""

from __future__ import annotations

from typing import Any, cast

from sqlalchemy import CursorResult, Result, Table
from sqlalchemy.exc import DBAPIError
from sqlalchemy.sql.expression import FromClause

# MySQL asks the client to simply run the transaction again after these errors.
_MYSQL_LOCK_WAIT_TIMEOUT = 1205
_MYSQL_DEADLOCK = 1213


def affected_rows(result: Result[Any]) -> int:
    """Number of rows matched by an UPDATE/DELETE statement."""
    return int(cast("CursorResult[Any]", result).rowcount)


def table_of(model: Any) -> Table:
    """The Core ``Table`` of a declarative model."""
    table: FromClause = model.__table__
    return cast("Table", table)


def driver_error_code(error: DBAPIError) -> int | None:
    """The numeric error code reported by the database driver, if any (MySQL: errno)."""
    arguments = getattr(error.orig, "args", ())
    return arguments[0] if arguments and isinstance(arguments[0], int) else None


def is_transient_lock_error(error: DBAPIError) -> bool:
    """True for deadlock victims and lock-wait timeouts, which are safe to retry."""
    return driver_error_code(error) in {_MYSQL_DEADLOCK, _MYSQL_LOCK_WAIT_TIMEOUT}
