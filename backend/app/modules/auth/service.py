"""Authentication application service."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, NoReturn

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session, scoped_session

from app.config import Settings
from app.core.actor import Actor
from app.core.client_settings import client_settings
from app.core.datetime_utils import utcnow
from app.core.db_utils import affected_rows
from app.core.errors import AccountDisabledError, AuthenticationError, ValidationFailedError
from app.core.permissions import permissions_for_role
from app.core.rate_limit import RateLimiter
from app.core.security import AccessTokenClaims, PasswordService, TokenService, generate_opaque_token, hash_token
from app.core.transactions import unit_of_work
from app.models import RefreshToken, User, UserRole
from app.modules.audit_logs.service import AuditService
from app.modules.users.password_policy import validate_password
from app.modules.users.repository import UserRepository, normalize_username

LOGIN_IP_SCOPE = "login_ip"
LOGIN_USER_SCOPE = "login_user"
REFRESH_IP_SCOPE = "refresh_ip"
_UNKNOWN_CLIENT = "unknown"


@dataclass(frozen=True)
class ClientContext:
    """Network metadata of the calling client (for auditing and rate limiting)."""

    ip: str | None = None
    user_agent: str | None = None

    @property
    def rate_limit_key(self) -> str:
        return self.ip or _UNKNOWN_CLIENT


@dataclass(frozen=True)
class AuthSession:
    """Result of a successful login, refresh or password change."""

    access_token: str
    refresh_token: str
    expires_in: int
    refresh_expires_in: int
    user: User
    permissions: list[str]
    app_settings: dict[str, Any]
    token_type: str = "Bearer"  # noqa: S105 - HTTP auth scheme name


@dataclass(frozen=True)
class Profile:
    user: User
    permissions: list[str]
    app_settings: dict[str, Any]


class AuthService:
    def __init__(
        self,
        session: scoped_session[Session],
        settings: Settings,
        passwords: PasswordService,
        tokens: TokenService,
        rate_limiter: RateLimiter,
        audit: AuditService,
        users: UserRepository,
    ) -> None:
        self._session = session
        self._settings = settings
        self._passwords = passwords
        self._tokens = tokens
        self._limiter = rate_limiter
        self._audit = audit
        self._users = users

    # ------------------------------------------------------------------ helpers
    def _permission_names(self, role: UserRole) -> list[str]:
        return sorted(permission.value for permission in permissions_for_role(role, self._settings))

    @staticmethod
    def _account_block_reason(user: User) -> str | None:
        if not user.is_active:
            return "account_disabled"
        if user.role is not UserRole.SUPER_ADMIN and (user.company is None or not user.company.is_active):
            return "company_inactive"
        return None

    def _issue(self, user: User, family_id: uuid.UUID, client: ClientContext, now: datetime) -> AuthSession:
        raw_refresh_token = generate_opaque_token()
        ttl = self._settings.refresh_token_ttl_seconds
        self._session.add(
            RefreshToken(
                user_id=user.id,
                family_id=family_id,
                token_hash=hash_token(raw_refresh_token),
                expires_at=now + timedelta(seconds=ttl),
                ip_address=client.ip,
                user_agent=(client.user_agent or "")[:255] or None,
            )
        )
        access = self._tokens.issue_access_token(user.id, family_id, user.token_version, now)
        return AuthSession(
            access_token=access.token,
            refresh_token=raw_refresh_token,
            expires_in=access.expires_in,
            refresh_expires_in=ttl,
            user=user,
            permissions=self._permission_names(user.role),
            app_settings=client_settings(self._settings),
        )

    def _revoke_family(self, family_id: uuid.UUID, now: datetime) -> None:
        self._session.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=now)
        )

    def _family_is_active(self, claims: AccessTokenClaims, now: datetime) -> bool:
        statement = (
            select(RefreshToken.id)
            .where(
                RefreshToken.family_id == claims.session_id,
                RefreshToken.user_id == claims.user_id,
                RefreshToken.revoked_at.is_(None),
                RefreshToken.expires_at > now,
            )
            .limit(1)
        )
        return self._session.scalar(statement) is not None

    def _reject_login(self, username: str, user: User | None, reason: str) -> NoReturn:
        self._audit.record_isolated(
            "LOGIN_FAILED",
            "user",
            user.id if user else None,
            actor_id=user.id if user else None,
            metadata={"username": username[:100], "reason": reason},
        )
        self._limiter.hit(LOGIN_USER_SCOPE, self._settings.rate_limit_login_user, username)
        # One generic message for every cause: do not reveal whether the account exists.
        raise AuthenticationError("نام کاربری یا رمز عبور نادرست است.", code="invalid_credentials")

    # ------------------------------------------------------------------ use cases
    def invalidate_user_tokens(self, user: User) -> None:
        """Invalidate every access and refresh token of ``user`` (caller commits)."""
        user.token_version += 1
        self._session.execute(
            update(RefreshToken)
            .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=utcnow())
        )

    def login(self, username: str, password: str, client: ClientContext) -> AuthSession:
        normalized = normalize_username(username)
        self._limiter.enforce(LOGIN_IP_SCOPE, self._settings.rate_limit_login_ip, client.rate_limit_key)
        self._limiter.ensure_available(LOGIN_USER_SCOPE, self._settings.rate_limit_login_user, normalized)

        user = self._users.get_by_username(normalized)
        if user is None:
            self._passwords.verify_dummy(password)
            self._reject_login(normalized, None, "unknown_user")
        if not self._passwords.verify(user.password_hash, password):
            self._reject_login(normalized, user, "wrong_password")

        # The account state is disclosed only to a caller who proved knowledge of the password.
        block_reason = self._account_block_reason(user)
        if block_reason is not None:
            self._audit.record_isolated(
                "LOGIN_BLOCKED", "user", user.id, actor_id=user.id, metadata={"reason": block_reason}
            )
            raise AccountDisabledError(code=block_reason)

        with unit_of_work(self._session):
            if self._passwords.needs_rehash(user.password_hash):
                user.password_hash = self._passwords.hash(password)
            now = utcnow()
            user.last_login_at = now
            result = self._issue(user, uuid.uuid4(), client, now)
            self._audit.record("LOGIN_SUCCESS", "user", user.id, actor_id=user.id)
        self._limiter.reset(LOGIN_USER_SCOPE, normalized)
        return result

    def refresh(self, raw_refresh_token: str, client: ClientContext) -> AuthSession:
        """Rotate a refresh token. Presenting an already-used token revokes the whole session."""
        self._limiter.enforce(REFRESH_IP_SCOPE, self._settings.rate_limit_refresh_ip, client.rate_limit_key)
        invalid = AuthenticationError("نشست شما معتبر نیست. لطفاً دوباره وارد شوید.", code="refresh_token_invalid")

        token = self._session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_token(raw_refresh_token)).with_for_update()
        )
        if token is None:
            raise invalid
        now = utcnow()
        if token.revoked_at is not None or token.rotated_at is not None:
            if token.revoked_at is None:
                with unit_of_work(self._session):
                    self._revoke_family(token.family_id, now)
                    self._audit.record(
                        "REFRESH_TOKEN_REUSE_DETECTED",
                        "user",
                        token.user_id,
                        actor_id=token.user_id,
                        metadata={"family_id": str(token.family_id)},
                    )
            raise invalid
        if token.expires_at <= now:
            raise invalid

        user = self._users.get(token.user_id)
        if user is None or self._account_block_reason(user) is not None:
            with unit_of_work(self._session):
                self._revoke_family(token.family_id, now)
            raise invalid

        with unit_of_work(self._session):
            token.rotated_at = now
            return self._issue(user, token.family_id, client, now)

    def authenticate(self, access_token: str) -> Actor:
        """Validate an access token against the current database state and build the actor."""
        claims = self._tokens.decode_access_token(access_token)
        revoked = AuthenticationError("نشست شما معتبر نیست. لطفاً دوباره وارد شوید.", code="token_revoked")
        user = self._users.get(claims.user_id)
        if user is None or user.token_version != claims.token_version:
            raise revoked
        block_reason = self._account_block_reason(user)
        if block_reason is not None:
            raise AuthenticationError("حساب کاربری شما غیرفعال است.", code=block_reason)
        if not self._family_is_active(claims, utcnow()):
            raise revoked
        return Actor(
            user_id=user.id,
            username=user.username,
            role=user.role,
            company_id=user.company_id,
            permissions=permissions_for_role(user.role, self._settings),
            token_id=claims.token_id,
            session_id=claims.session_id,
            token_expires_at=claims.expires_at,
        )

    def logout(self, actor: Actor) -> None:
        """Revoke the caller's session: its refresh tokens and all of its access tokens."""
        with unit_of_work(self._session):
            if actor.session_id is not None:
                self._revoke_family(actor.session_id, utcnow())
            self._audit.record("LOGOUT", "user", actor.user_id, actor_id=actor.user_id)

    def profile(self, actor: Actor) -> Profile:
        user = self._users.get(actor.user_id)
        if user is None:
            raise AuthenticationError()
        return Profile(
            user=user,
            permissions=self._permission_names(user.role),
            app_settings=client_settings(self._settings),
        )

    def change_password(
        self, actor: Actor, current_password: str, new_password: str, client: ClientContext
    ) -> AuthSession:
        user = self._users.get(actor.user_id)
        if user is None:
            raise AuthenticationError()
        rule = self._settings.rate_limit_login_user
        self._limiter.ensure_available(LOGIN_USER_SCOPE, rule, user.username)
        if not self._passwords.verify(user.password_hash, current_password):
            self._audit.record_isolated("PASSWORD_CHANGE_FAILED", "user", user.id, actor_id=user.id)
            self._limiter.hit(LOGIN_USER_SCOPE, rule, user.username)
            raise ValidationFailedError.single(
                "current_password", "رمز عبور فعلی نادرست است.", code="invalid_current_password"
            )
        validate_password(new_password, user.username, self._settings, field="new_password")
        if new_password == current_password:
            raise ValidationFailedError.single("new_password", "رمز عبور جدید نباید با رمز عبور فعلی یکسان باشد.")

        with unit_of_work(self._session):
            user.password_hash = self._passwords.hash(new_password)
            self.invalidate_user_tokens(user)
            result = self._issue(user, uuid.uuid4(), client, utcnow())
            self._audit.record("PASSWORD_CHANGED", "user", user.id, actor_id=user.id)
        return result

    def purge_expired(self) -> int:
        """Delete refresh tokens that expired (maintenance task)."""
        with unit_of_work(self._session):
            result = self._session.execute(delete(RefreshToken).where(RefreshToken.expires_at < utcnow()))
        return affected_rows(result)
