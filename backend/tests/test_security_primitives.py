"""Unit tests for password hashing, JWT handling and opaque tokens."""

from __future__ import annotations

import base64
import json
import uuid
from datetime import timedelta

import jwt
import pytest

from app.config import Settings
from app.core.datetime_utils import utcnow
from app.core.errors import AuthenticationError
from app.core.security import PasswordService, TokenService, generate_opaque_token, hash_token


def test_passwords_are_hashed_with_argon2id_and_salted(settings: Settings) -> None:
    passwords = PasswordService(settings)
    first = passwords.hash("correct horse battery staple")
    second = passwords.hash("correct horse battery staple")
    assert first.startswith("$argon2id$")
    assert first != second  # unique salt per hash
    assert "correct horse" not in first
    assert passwords.verify(first, "correct horse battery staple") is True
    assert passwords.verify(first, "wrong password") is False


def test_verifying_a_malformed_hash_fails_closed(settings: Settings) -> None:
    passwords = PasswordService(settings)
    assert passwords.verify("not-a-hash", "anything") is False
    assert passwords.verify("", "anything") is False


def test_opaque_tokens_are_long_random_and_only_hashes_are_comparable() -> None:
    tokens = {generate_opaque_token() for _ in range(200)}
    assert len(tokens) == 200
    assert all(len(token) >= 43 for token in tokens)
    token = tokens.pop()
    assert hash_token(token) == hash_token(token)
    assert len(hash_token(token)) == 64
    assert token not in hash_token(token)


def test_access_token_round_trip(settings: Settings) -> None:
    service = TokenService(settings)
    user_id, session_id = uuid.uuid4(), uuid.uuid4()
    issued = service.issue_access_token(user_id, session_id, token_version=3)
    claims = service.decode_access_token(issued.token)
    assert claims.user_id == user_id
    assert claims.session_id == session_id
    assert claims.token_version == 3
    assert claims.token_id == issued.token_id
    assert issued.expires_in == settings.access_token_ttl_seconds


def test_access_token_contains_no_role_or_company_claims(settings: Settings) -> None:
    issued = TokenService(settings).issue_access_token(uuid.uuid4(), uuid.uuid4(), 0)
    payload = jwt.decode(issued.token, options={"verify_signature": False})
    assert set(payload) == {"iss", "sub", "jti", "sid", "ver", "typ", "iat", "exp"}


def test_expired_token_is_rejected(settings: Settings) -> None:
    service = TokenService(settings)
    past = utcnow() - timedelta(seconds=settings.access_token_ttl_seconds + 5)
    issued = service.issue_access_token(uuid.uuid4(), uuid.uuid4(), 0, now=past)
    with pytest.raises(AuthenticationError) as error:
        service.decode_access_token(issued.token)
    assert error.value.code == "token_expired"


def _forge(payload: dict[str, object], header: dict[str, object], signature: bytes = b"") -> str:
    def encode(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    return ".".join([encode(json.dumps(header).encode()), encode(json.dumps(payload).encode()), encode(signature)])


def _valid_payload(settings: Settings) -> dict[str, object]:
    now = int(utcnow().timestamp())
    return {
        "iss": settings.jwt_issuer,
        "sub": str(uuid.uuid4()),
        "jti": str(uuid.uuid4()),
        "sid": str(uuid.uuid4()),
        "ver": 0,
        "typ": "access",
        "iat": now,
        "exp": now + 600,
    }


def test_unsigned_alg_none_token_is_rejected(settings: Settings) -> None:
    token = _forge(_valid_payload(settings), {"alg": "none", "typ": "JWT"})
    with pytest.raises(AuthenticationError) as error:
        TokenService(settings).decode_access_token(token)
    assert error.value.code == "token_invalid"


def test_token_signed_with_another_key_is_rejected(settings: Settings) -> None:
    token = jwt.encode(_valid_payload(settings), "another-secret-key-that-is-long-enough-000", algorithm="HS256")
    with pytest.raises(AuthenticationError) as error:
        TokenService(settings).decode_access_token(token)
    assert error.value.code == "token_invalid"


def test_tampered_payload_is_rejected(settings: Settings) -> None:
    service = TokenService(settings)
    issued = service.issue_access_token(uuid.uuid4(), uuid.uuid4(), 0)
    header, payload, signature = issued.token.split(".")
    decoded = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    decoded["sub"] = str(uuid.uuid4())
    forged_payload = base64.urlsafe_b64encode(json.dumps(decoded).encode()).rstrip(b"=").decode()
    with pytest.raises(AuthenticationError):
        service.decode_access_token(f"{header}.{forged_payload}.{signature}")


@pytest.mark.parametrize(
    "mutation",
    [
        {"typ": "refresh"},
        {"iss": "someone-else"},
        {"sub": "not-a-uuid"},
        {"ver": "abc"},
    ],
)
def test_token_with_wrong_claims_is_rejected(settings: Settings, mutation: dict[str, object]) -> None:
    payload = {**_valid_payload(settings), **mutation}
    token = jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)
    with pytest.raises(AuthenticationError) as error:
        TokenService(settings).decode_access_token(token)
    assert error.value.code == "token_invalid"


@pytest.mark.parametrize("missing", ["exp", "sub", "jti", "sid", "ver", "typ", "iss", "iat"])
def test_token_missing_a_required_claim_is_rejected(settings: Settings, missing: str) -> None:
    payload = _valid_payload(settings)
    del payload[missing]
    token = jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)
    with pytest.raises(AuthenticationError):
        TokenService(settings).decode_access_token(token)


@pytest.mark.parametrize("garbage", ["", "abc", "a.b.c", "....", "null"])
def test_garbage_tokens_are_rejected(settings: Settings, garbage: str) -> None:
    with pytest.raises(AuthenticationError):
        TokenService(settings).decode_access_token(garbage)
