"""Employee management application service (SUPER_ADMIN only).

The HTTP API manages EMPLOYEE accounts only. SUPER_ADMIN accounts are created
with the ``flask create-admin`` command and are read-only through this service,
which rules out privilege escalation and accidental administrator lock-out.
"""

from __future__ import annotations

import re
import uuid
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, scoped_session

from app.config import Settings
from app.core.actor import Actor
from app.core.errors import ConflictError, NotFoundError, PermissionDeniedError, ValidationFailedError
from app.core.pagination import Page
from app.core.permissions import Permission
from app.core.security import PasswordService
from app.core.transactions import unit_of_work
from app.models import Company, User, UserRole
from app.modules.audit_logs.service import AuditService
from app.modules.auth.service import AuthService
from app.modules.companies.repository import CompanyRepository
from app.modules.users.password_policy import validate_password
from app.modules.users.repository import UserRepository, normalize_username
from app.modules.users.schemas import USERNAME_PATTERN


class UserService:
    def __init__(
        self,
        session: scoped_session[Session],
        settings: Settings,
        passwords: PasswordService,
        audit: AuditService,
        auth: AuthService,
        users: UserRepository,
        companies: CompanyRepository,
    ) -> None:
        self._session = session
        self._settings = settings
        self._passwords = passwords
        self._audit = audit
        self._auth = auth
        self._users = users
        self._companies = companies

    @staticmethod
    def _username_conflict() -> ConflictError:
        return ConflictError(
            "این نام کاربری قبلاً ثبت شده است.",
            code="username_taken",
            details={"fields": {"username": ["این نام کاربری قبلاً استفاده شده است."]}},
        )

    def _require_company(self, company_id: uuid.UUID) -> Company:
        company = self._companies.get(company_id)
        if company is None:
            raise ValidationFailedError.single("company_id", "شرکت انتخاب‌شده وجود ندارد.")
        return company

    def _get_employee(self, user_id: uuid.UUID) -> User:
        user = self.get(user_id)
        if user.role is not UserRole.EMPLOYEE:
            raise PermissionDeniedError(
                "حساب مدیر مرکزی از طریق این سرویس قابل تغییر نیست.", code="admin_account_protected"
            )
        return user

    def list_users(self, **filters: Any) -> Page[User]:
        return self._users.search(**filters)

    def get(self, user_id: uuid.UUID) -> User:
        user = self._users.get(user_id)
        if user is None:
            raise NotFoundError("کاربر موردنظر یافت نشد.")
        return user

    def create_employee(self, actor: Actor, data: dict[str, Any]) -> User:
        username = normalize_username(data["username"])
        validate_password(data["password"], username, self._settings)
        company = self._require_company(data["company_id"])
        if self._users.username_exists(username):
            raise self._username_conflict()
        user = User(
            username=username,
            full_name=data["full_name"],
            password_hash=self._passwords.hash(data["password"]),
            role=UserRole.EMPLOYEE,
            company_id=company.id,
            is_active=data.get("is_active", True),
        )
        try:
            with unit_of_work(self._session):
                self._session.add(user)
                self._session.flush()
                self._audit.record(
                    "USER_CREATED",
                    "user",
                    user.id,
                    actor_id=actor.user_id,
                    metadata={"username": user.username, "company_id": str(company.id), "role": user.role.value},
                )
        except IntegrityError as exc:
            raise self._username_conflict() from exc
        return user

    def create_super_admin(self, username: str, full_name: str, password: str) -> User:
        """Create a central administrator (operator action through the CLI, not the HTTP API)."""
        username = normalize_username(username)
        errors: dict[str, list[str]] = {}
        if re.fullmatch(USERNAME_PATTERN, username) is None:
            errors["username"] = ["نام کاربری معتبر نیست."]
        if not 2 <= len(full_name.strip()) <= 200:
            errors["full_name"] = ["نام کامل باید بین ۲ تا ۲۰۰ نویسه باشد."]
        if errors:
            raise ValidationFailedError(errors)
        validate_password(password, username, self._settings)
        if self._users.username_exists(username):
            raise self._username_conflict()
        user = User(
            username=username,
            full_name=full_name.strip(),
            password_hash=self._passwords.hash(password),
            role=UserRole.SUPER_ADMIN,
            company_id=None,
            is_active=True,
        )
        try:
            with unit_of_work(self._session):
                self._session.add(user)
                self._session.flush()
                self._audit.record(
                    "ADMIN_CREATED", "user", user.id, metadata={"username": user.username, "source": "cli"}
                )
        except IntegrityError as exc:
            raise self._username_conflict() from exc
        return user

    def update_employee(self, actor: Actor, user_id: uuid.UUID, data: dict[str, Any]) -> User:
        user = self._get_employee(user_id)
        changes: dict[str, Any] = {}
        must_invalidate_tokens = False

        if "username" in data:
            username = normalize_username(data["username"])
            if username != user.username:
                if self._users.username_exists(username, exclude_id=user.id):
                    raise self._username_conflict()
                changes["username"] = {"from": user.username, "to": username}
        if "company_id" in data and data["company_id"] != user.company_id:
            self._require_company(data["company_id"])
        if "is_active" in data and data["is_active"] != user.is_active:
            actor.require(Permission.USER_SET_ACTIVE)

        try:
            with unit_of_work(self._session):
                if "username" in changes:
                    user.username = changes["username"]["to"]
                if "full_name" in data and data["full_name"] != user.full_name:
                    changes["full_name"] = {"from": user.full_name, "to": data["full_name"]}
                    user.full_name = data["full_name"]
                if "company_id" in data and data["company_id"] != user.company_id:
                    changes["company_id"] = {"from": str(user.company_id), "to": str(data["company_id"])}
                    user.company_id = data["company_id"]
                    must_invalidate_tokens = True  # the tenant scope changed
                if changes:
                    self._audit.record(
                        "USER_UPDATED", "user", user.id, actor_id=actor.user_id, metadata={"changes": changes}
                    )
                if "is_active" in data and data["is_active"] != user.is_active:
                    user.is_active = data["is_active"]
                    must_invalidate_tokens = must_invalidate_tokens or not user.is_active
                    self._audit.record(
                        "USER_ACTIVATED" if user.is_active else "USER_DEACTIVATED",
                        "user",
                        user.id,
                        actor_id=actor.user_id,
                    )
                if must_invalidate_tokens:
                    self._auth.invalidate_user_tokens(user)
        except IntegrityError as exc:
            raise self._username_conflict() from exc
        self._session.refresh(user)
        return user

    def reset_password(self, actor: Actor, user_id: uuid.UUID, new_password: str) -> User:
        user = self._get_employee(user_id)
        validate_password(new_password, user.username, self._settings, field="new_password")
        with unit_of_work(self._session):
            user.password_hash = self._passwords.hash(new_password)
            self._auth.invalidate_user_tokens(user)
            self._audit.record("USER_PASSWORD_RESET", "user", user.id, actor_id=actor.user_id)
        return user
