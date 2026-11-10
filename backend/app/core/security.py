"""Password hashing, JWT handling and opaque-token helpers."""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from argon2.low_level import Type

from app.config import Settings
from app.core.datetime_utils import utcnow
from app.core.errors import AuthenticationError

ACCESS_TOKEN_TYPE = "access"  # noqa: S105 - token type label, not a secret


def generate_opaque_token() -> str:
    """Return a URL-safe random token with 256 bits of entropy."""
    return secrets.token_urlsafe(32)


def hash_token(raw_token: str) -> str:
    """SHA-256 hex digest used to store opaque tokens (never the raw value)."""
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


class PasswordService:
    """Argon2id password hashing."""

    def __init__(self, settings: Settings) -> None:
        self._hasher = PasswordHasher(
            time_cost=settings.argon2_time_cost,
            memory_cost=settings.argon2_memory_cost_kib,
            parallelism=settings.argon2_parallelism,
            type=Type.ID,
        )
        # Verified for unknown usernames so response timing does not reveal account existence.
        self._dummy_hash = self._hasher.hash(secrets.token_urlsafe(16))

    def hash(self, password: str) -> str:
        return self._hasher.hash(password)

    def verify(self, password_hash: str, password: str) -> bool:
        try:
            return bool(self._hasher.verify(password_hash, password))
        except (VerificationError, InvalidHashError):
            return False

    def verify_dummy(self, password: str) -> None:
        self.verify(self._dummy_hash, password)

    def needs_rehash(self, password_hash: str) -> bool:
        return bool(self._hasher.check_needs_rehash(password_hash))


@dataclass(frozen=True)
class AccessTokenClaims:
    user_id: uuid.UUID
    token_id: uuid.UUID
    session_id: uuid.UUID
    token_version: int
    expires_at: datetime


@dataclass(frozen=True)
class IssuedAccessToken:
    token: str
    token_id: uuid.UUID
    expires_at: datetime
    expires_in: int


class TokenService:
    """Issues and verifies signed JWT access tokens."""

    _REQUIRED_CLAIMS = ("exp", "iat", "sub", "jti", "sid", "ver", "typ", "iss")

    def __init__(self, settings: Settings) -> None:
        self._secret = settings.jwt_secret_key
        self._algorithm = settings.jwt_algorithm
        self._issuer = settings.jwt_issuer
        self._ttl = timedelta(seconds=settings.access_token_ttl_seconds)

    def issue_access_token(
        self, user_id: uuid.UUID, session_id: uuid.UUID, token_version: int, now: datetime | None = None
    ) -> IssuedAccessToken:
        issued_at = now or utcnow()
        expires_at = issued_at + self._ttl
        token_id = uuid.uuid4()
        payload = {
            "iss": self._issuer,
            "sub": str(user_id),
            "jti": str(token_id),
            "sid": str(session_id),
            "ver": token_version,
            "typ": ACCESS_TOKEN_TYPE,
            "iat": int(issued_at.timestamp()),
            "exp": int(expires_at.timestamp()),
        }
        token = jwt.encode(payload, self._secret, algorithm=self._algorithm)
        return IssuedAccessToken(
            token=token, token_id=token_id, expires_at=expires_at, expires_in=int(self._ttl.total_seconds())
        )

    def decode_access_token(self, token: str) -> AccessTokenClaims:
        try:
            payload = jwt.decode(
                token,
                self._secret,
                algorithms=[self._algorithm],
                issuer=self._issuer,
                options={"require": list(self._REQUIRED_CLAIMS)},
            )
            if payload["typ"] != ACCESS_TOKEN_TYPE:
                raise jwt.InvalidTokenError("unexpected token type")
            return AccessTokenClaims(
                user_id=uuid.UUID(str(payload["sub"])),
                token_id=uuid.UUID(str(payload["jti"])),
                session_id=uuid.UUID(str(payload["sid"])),
                token_version=int(payload["ver"]),
                expires_at=datetime.fromtimestamp(int(payload["exp"]), tz=UTC),
            )
        except jwt.ExpiredSignatureError as exc:
            raise AuthenticationError("نشست شما منقضی شده است. لطفاً دوباره وارد شوید.", code="token_expired") from exc
        except (jwt.InvalidTokenError, ValueError, TypeError, KeyError) as exc:
            raise AuthenticationError("توکن دسترسی نامعتبر است.", code="token_invalid") from exc
