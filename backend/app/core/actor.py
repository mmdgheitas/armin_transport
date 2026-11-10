"""The authenticated principal of a request."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

from app.core.errors import PermissionDeniedError
from app.core.permissions import Permission
from app.models.enums import UserRole


@dataclass(frozen=True)
class Actor:
    """Immutable view of the authenticated user, derived from the database on every request.

    Role, company and permissions are never taken from client-supplied data
    (including token claims); they are loaded from the user's current database row.
    """

    user_id: uuid.UUID
    username: str
    role: UserRole
    company_id: uuid.UUID | None
    permissions: frozenset[Permission]
    token_id: uuid.UUID | None = None
    session_id: uuid.UUID | None = None
    token_expires_at: datetime | None = None

    @property
    def has_global_scope(self) -> bool:
        return Permission.GLOBAL_SCOPE in self.permissions

    def can(self, permission: Permission) -> bool:
        return permission in self.permissions

    def require(self, *permissions: Permission) -> None:
        missing = [permission for permission in permissions if permission not in self.permissions]
        if missing:
            raise PermissionDeniedError(details={"required_permissions": sorted(p.value for p in missing)})

    def can_access_company(self, company_id: uuid.UUID) -> bool:
        return self.has_global_scope or (self.company_id is not None and self.company_id == company_id)
