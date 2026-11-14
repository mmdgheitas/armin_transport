"""Environment-driven application configuration.

Configuration is read from environment variables at application start-up and
exposed as an immutable, typed :class:`Settings` object. Three environments are
supported: ``development``, ``testing`` and ``production``. Production settings
are validated strictly and the application refuses to start when they are unsafe.
"""

from __future__ import annotations

import dataclasses
import os
import re
import secrets
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError

BACKEND_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = BACKEND_ROOT.parent
APP_VERSION = "1.0.0"
DEFAULT_DATABASE_URL = f"sqlite:///{BACKEND_ROOT / 'instance' / 'armin_transport.sqlite3'}"

ENVIRONMENTS = ("development", "testing", "production")
# Every extension whose content the upload pipeline can verify. ALLOWED_UPLOAD_EXTENSIONS
# may narrow this set but can never extend it (unverifiable types are refused).
SUPPORTED_UPLOAD_EXTENSIONS = ("pdf", "jpg", "jpeg", "png", "webp", "doc", "docx", "xls", "xlsx", "txt")
DEFAULT_ALLOWED_EXTENSIONS = SUPPORTED_UPLOAD_EXTENSIONS
TRACKING_CODE_COLUMN_LENGTH = 64
SUPPORTED_DATABASE_DIALECTS = ("mysql", "sqlite")
_ORIGIN_PATTERN = re.compile(r"https?://[A-Za-z0-9.-]+(:\d{1,5})?")
_FRAME_ANCESTORS_PATTERN = re.compile(r"('none'|((\*|'self'|https?://[A-Za-z0-9.*-]+(:\d{1,5})?)( (?!$)|$))+)")
_PLACEHOLDER_SECRETS = {"", "change-me", "changeme", "secret", "replace-with-a-long-random-secret"}
_MIN_SECRET_LENGTH = 32


class ConfigError(RuntimeError):
    """Raised when the configuration is missing or unsafe."""


@dataclass(frozen=True)
class RateLimitRule:
    """Allow at most ``limit`` events per ``window_seconds`` for one key."""

    limit: int
    window_seconds: int

    @classmethod
    def parse(cls, raw: str, name: str) -> RateLimitRule:
        try:
            limit_text, window_text = raw.strip().split("/", 1)
            rule = cls(limit=int(limit_text), window_seconds=int(window_text))
        except ValueError as exc:
            raise ConfigError(f"{name} must use the '<max_events>/<window_seconds>' format.") from exc
        if rule.limit < 1 or rule.window_seconds < 1:
            raise ConfigError(f"{name} values must be positive integers.")
        return rule


@dataclass(frozen=True)
class Settings:
    """Typed application settings. See ``.env.example`` for documentation."""

    env: str
    debug: bool
    testing: bool
    app_version: str

    # Database
    database_url: str
    db_pool_size: int
    db_max_overflow: int
    db_pool_recycle_seconds: int

    # Authentication
    jwt_secret_key: str
    jwt_algorithm: str
    jwt_issuer: str
    access_token_ttl_seconds: int
    refresh_token_ttl_seconds: int
    password_min_length: int
    argon2_time_cost: int
    argon2_memory_cost_kib: int
    argon2_parallelism: int

    # Document storage and upload policy
    storage_root: Path
    max_upload_size_bytes: int
    max_files_per_upload: int
    allowed_upload_extensions: frozenset[str]
    allowed_upload_mime_types: frozenset[str] | None
    verify_checksum_on_download: bool
    document_customer_visible_default: bool
    document_purge_file_on_delete: bool
    malware_scan_command: str | None
    malware_scan_timeout_seconds: int

    # Configurable business rules (see docs/REQUIREMENTS.md, section "تصمیم‌های کسب‌وکاری")
    employee_can_use_manual_tracking_code: bool
    employee_can_change_tracking_code: bool
    employee_can_archive_shipments: bool
    employee_can_delete_documents: bool

    # Tracking codes
    tracking_code_auto_length: int
    tracking_code_auto_group_size: int
    tracking_code_auto_prefix: str
    tracking_code_min_length: int
    tracking_code_max_attempts: int

    # Customer portal
    customer_session_ttl_seconds: int
    customer_show_company_name: bool
    customer_show_description: bool
    customer_allow_archived_shipments: bool

    # Rate limiting
    rate_limit_enabled: bool
    rate_limit_login_ip: RateLimitRule
    rate_limit_login_user: RateLimitRule
    rate_limit_refresh_ip: RateLimitRule
    rate_limit_customer_lookup_ip: RateLimitRule
    rate_limit_customer_lookup_failures_ip: RateLimitRule
    rate_limit_customer_access_ip: RateLimitRule

    # HTTP
    cors_allowed_origins: tuple[str, ...]
    trusted_proxy_count: int
    frame_ancestors: str
    hsts_enabled: bool
    serve_web_app: bool
    web_app_dir: Path | None

    # Pagination
    default_page_size: int
    max_page_size: int

    # Logging
    log_level: str
    log_format: str

    @property
    def is_production(self) -> bool:
        return self.env == "production"

    @property
    def max_request_size_bytes(self) -> int | None:
        """Upper bound for a whole multipart request (all files plus form overhead)."""
        return None

    @property
    def database_dialect(self) -> str:
        return self.database_url.split(":", 1)[0].split("+", 1)[0]


class _Env:
    """Typed accessors over an environment mapping."""

    def __init__(self, environ: Mapping[str, str]) -> None:
        self._environ = environ

    def text(self, name: str, default: str) -> str:
        value = self._environ.get(name)
        return default if value is None or value.strip() == "" else value.strip()

    def optional(self, name: str) -> str | None:
        value = self._environ.get(name)
        return None if value is None or value.strip() == "" else value.strip()

    def boolean(self, name: str, default: bool) -> bool:
        value = self.optional(name)
        if value is None:
            return default
        lowered = value.lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
        raise ConfigError(f"{name} must be a boolean (true/false).")

    def integer(self, name: str, default: int, *, minimum: int | None = None, maximum: int | None = None) -> int:
        value = self.optional(name)
        if value is None:
            return default
        try:
            number = int(value)
        except ValueError as exc:
            raise ConfigError(f"{name} must be an integer.") from exc
        if minimum is not None and number < minimum:
            raise ConfigError(f"{name} must be >= {minimum}.")
        if maximum is not None and number > maximum:
            raise ConfigError(f"{name} must be <= {maximum}.")
        return number

    def csv(self, name: str, default: tuple[str, ...]) -> tuple[str, ...]:
        value = self.optional(name)
        if value is None:
            return default
        return tuple(item.strip() for item in value.split(",") if item.strip())

    def rate_limit(self, name: str, default: str) -> RateLimitRule:
        return RateLimitRule.parse(self.text(name, default), name)


def resolve_environment(env_name: str | None, environ: Mapping[str, str]) -> str:
    name = (env_name or environ.get("APP_ENV") or "development").strip().lower()
    if name not in ENVIRONMENTS:
        raise ConfigError(f"APP_ENV must be one of {', '.join(ENVIRONMENTS)} (got '{name}').")
    return name


def _database_url(env: _Env, env_name: str) -> str:
    if env_name == "testing":
        url = env.optional("TEST_DATABASE_URL")
        if url:
            return url
        # Tests always use a separate database, never the application database.
        return f"sqlite:///{Path(tempfile.gettempdir()) / f'armin_transport_test_{os.getpid()}.sqlite3'}"
    return env.optional("DATABASE_URL") or DEFAULT_DATABASE_URL


def _jwt_secret(env: _Env, env_name: str) -> str:
    secret = env.optional("JWT_SECRET_KEY")
    if secret:
        return secret
    if env_name == "testing":
        return "testing-only-secret-key-not-used-anywhere-else-0123456789"
    if env_name == "development":
        # Ephemeral secret: tokens are invalidated on restart. Never used in production.
        return secrets.token_urlsafe(48)
    raise ConfigError("JWT_SECRET_KEY is required in production.")


def load_settings(
    env_name: str | None = None,
    environ: Mapping[str, str] | None = None,
    overrides: Mapping[str, Any] | None = None,
) -> Settings:
    """Build :class:`Settings` from the environment, then apply explicit overrides."""
    source = os.environ if environ is None else environ
    name = resolve_environment(env_name, source)
    env = _Env(source)
    is_testing = name == "testing"
    is_production = name == "production"

    default_storage = (
        Path(tempfile.gettempdir()) / f"armin_transport_test_storage_{os.getpid()}"
        if is_testing
        else BACKEND_ROOT / "instance" / "storage"
    )
    default_web_dir = REPO_ROOT / "web" / "dist"
    mime_types = env.csv("ALLOWED_UPLOAD_MIME_TYPES", ())
    web_dir = env.optional("WEB_APP_DIR")

    settings = Settings(
        env=name,
        debug=env.boolean("APP_DEBUG", False) if not is_production else False,
        testing=is_testing,
        app_version=APP_VERSION,
        database_url=_database_url(env, name),
        db_pool_size=env.integer("DB_POOL_SIZE", 10, minimum=1, maximum=200),
        db_max_overflow=env.integer("DB_MAX_OVERFLOW", 10, minimum=0, maximum=200),
        db_pool_recycle_seconds=env.integer("DB_POOL_RECYCLE_SECONDS", 1800, minimum=30),
        jwt_secret_key=_jwt_secret(env, name),
        jwt_algorithm=env.text("JWT_ALGORITHM", "HS256"),
        jwt_issuer=env.text("JWT_ISSUER", "armin-transport"),
        access_token_ttl_seconds=env.integer("JWT_ACCESS_TOKEN_TTL_SECONDS", 900, minimum=60, maximum=86400),
        refresh_token_ttl_seconds=env.integer("JWT_REFRESH_TOKEN_TTL_SECONDS", 1209600, minimum=300),
        password_min_length=env.integer("PASSWORD_MIN_LENGTH", 10, minimum=8, maximum=128),
        argon2_time_cost=env.integer("ARGON2_TIME_COST", 1 if is_testing else 3, minimum=1),
        argon2_memory_cost_kib=env.integer("ARGON2_MEMORY_COST_KIB", 1024 if is_testing else 65536, minimum=8),
        argon2_parallelism=env.integer("ARGON2_PARALLELISM", 1 if is_testing else 4, minimum=1),
        storage_root=Path(env.text("STORAGE_ROOT", str(default_storage))).expanduser(),
        max_upload_size_bytes=0,
        max_files_per_upload=12,
        allowed_upload_extensions=frozenset(
            item.lower().lstrip(".") for item in env.csv("ALLOWED_UPLOAD_EXTENSIONS", DEFAULT_ALLOWED_EXTENSIONS)
        ),
        allowed_upload_mime_types=frozenset(item.lower() for item in mime_types) if mime_types else None,
        verify_checksum_on_download=env.boolean("VERIFY_CHECKSUM_ON_DOWNLOAD", True),
        document_customer_visible_default=env.boolean("DOCUMENT_CUSTOMER_VISIBLE_DEFAULT", True),
        document_purge_file_on_delete=env.boolean("DOCUMENT_PURGE_FILE_ON_DELETE", False),
        malware_scan_command=env.optional("MALWARE_SCAN_COMMAND"),
        malware_scan_timeout_seconds=env.integer("MALWARE_SCAN_TIMEOUT_SECONDS", 60, minimum=1),
        employee_can_use_manual_tracking_code=env.boolean("EMPLOYEE_CAN_USE_MANUAL_TRACKING_CODE", False),
        employee_can_change_tracking_code=env.boolean("EMPLOYEE_CAN_CHANGE_TRACKING_CODE", True),
        employee_can_archive_shipments=env.boolean("EMPLOYEE_CAN_ARCHIVE_SHIPMENTS", True),
        employee_can_delete_documents=env.boolean("EMPLOYEE_CAN_DELETE_DOCUMENTS", False),
        tracking_code_auto_length=env.integer("TRACKING_CODE_AUTO_LENGTH", 16, minimum=12, maximum=40),
        tracking_code_auto_group_size=env.integer("TRACKING_CODE_AUTO_GROUP_SIZE", 4, minimum=0, maximum=10),
        tracking_code_auto_prefix=env.text("TRACKING_CODE_AUTO_PREFIX", "").upper(),
        tracking_code_min_length=env.integer("TRACKING_CODE_MIN_LENGTH", 6, minimum=4, maximum=32),
        tracking_code_max_attempts=env.integer("TRACKING_CODE_MAX_ATTEMPTS", 8, minimum=1, maximum=50),
        customer_session_ttl_seconds=env.integer("CUSTOMER_SESSION_TTL_SECONDS", 1800, minimum=60, maximum=86400),
        customer_show_company_name=env.boolean("CUSTOMER_SHOW_COMPANY_NAME", True),
        customer_show_description=env.boolean("CUSTOMER_SHOW_DESCRIPTION", False),
        customer_allow_archived_shipments=env.boolean("CUSTOMER_ALLOW_ARCHIVED_SHIPMENTS", False),
        rate_limit_enabled=env.boolean("RATE_LIMIT_ENABLED", True),
        rate_limit_login_ip=env.rate_limit("RATE_LIMIT_LOGIN_IP", "30/300"),
        rate_limit_login_user=env.rate_limit("RATE_LIMIT_LOGIN_USER", "10/900"),
        rate_limit_refresh_ip=env.rate_limit("RATE_LIMIT_REFRESH_IP", "120/60"),
        rate_limit_customer_lookup_ip=env.rate_limit("RATE_LIMIT_CUSTOMER_LOOKUP_IP", "10/60"),
        rate_limit_customer_lookup_failures_ip=env.rate_limit("RATE_LIMIT_CUSTOMER_LOOKUP_FAILURES_IP", "20/3600"),
        rate_limit_customer_access_ip=env.rate_limit("RATE_LIMIT_CUSTOMER_ACCESS_IP", "240/60"),
        cors_allowed_origins=env.csv("CORS_ALLOWED_ORIGINS", ()),
        trusted_proxy_count=env.integer("TRUSTED_PROXY_COUNT", 0, minimum=0, maximum=5),
        frame_ancestors=env.text("FRAME_ANCESTORS", "'none'"),
        hsts_enabled=env.boolean("HSTS_ENABLED", is_production),
        serve_web_app=env.boolean("SERVE_WEB_APP", False),
        web_app_dir=Path(web_dir).expanduser() if web_dir else default_web_dir,
        default_page_size=env.integer("DEFAULT_PAGE_SIZE", 20, minimum=1, maximum=200),
        max_page_size=env.integer("MAX_PAGE_SIZE", 100, minimum=1, maximum=500),
        log_level=env.text("LOG_LEVEL", "INFO").upper(),
        log_format=env.text("LOG_FORMAT", "json" if is_production else "text").lower(),
    )
    if overrides:
        settings = dataclasses.replace(settings, **overrides)
    validate_settings(settings)
    return settings


def _validate_general(settings: Settings) -> None:
    if settings.database_dialect not in SUPPORTED_DATABASE_DIALECTS:
        raise ConfigError(
            "DATABASE_URL must point to SQLite (sqlite:////absolute/path/armin_transport.sqlite3) "
            "or the optional MySQL backend (mysql+pymysql://...)."
        )
    try:
        url = make_url(settings.database_url)
    except ArgumentError as exc:
        raise ConfigError("DATABASE_URL is not a valid SQLAlchemy database URL.") from exc
    if settings.database_dialect == "sqlite" and url.drivername not in {"sqlite", "sqlite+pysqlite"}:
        raise ConfigError("DATABASE_URL must use SQLite's built-in sqlite3 driver (sqlite or sqlite+pysqlite).")
    if settings.jwt_algorithm not in {"HS256", "HS384", "HS512"}:
        raise ConfigError("JWT_ALGORITHM must be one of HS256, HS384 or HS512.")
    if settings.default_page_size > settings.max_page_size:
        raise ConfigError("DEFAULT_PAGE_SIZE must not exceed MAX_PAGE_SIZE.")
    if settings.log_format not in {"json", "text"}:
        raise ConfigError("LOG_FORMAT must be 'json' or 'text'.")


def _validate_uploads(settings: Settings) -> None:
    if not settings.allowed_upload_extensions:
        raise ConfigError("ALLOWED_UPLOAD_EXTENSIONS must not be empty.")
    unsupported = sorted(settings.allowed_upload_extensions - set(SUPPORTED_UPLOAD_EXTENSIONS))
    if unsupported:
        raise ConfigError(
            "ALLOWED_UPLOAD_EXTENSIONS contains unsupported extension(s): "
            f"{', '.join(unsupported)}. Supported: {', '.join(SUPPORTED_UPLOAD_EXTENSIONS)}."
        )


def _validate_tracking_codes(settings: Settings) -> None:
    group = settings.tracking_code_auto_group_size
    generated_length = (
        settings.tracking_code_auto_length
        + ((settings.tracking_code_auto_length - 1) // group if group else 0)
        + (len(settings.tracking_code_auto_prefix) + 1 if settings.tracking_code_auto_prefix else 0)
    )
    if generated_length > TRACKING_CODE_COLUMN_LENGTH:
        raise ConfigError(
            "TRACKING_CODE_AUTO_LENGTH/GROUP_SIZE/PREFIX produce codes longer than "
            f"{TRACKING_CODE_COLUMN_LENGTH} characters."
        )
    if settings.tracking_code_auto_prefix and not settings.tracking_code_auto_prefix.replace("-", "").isalnum():
        raise ConfigError("TRACKING_CODE_AUTO_PREFIX may only contain letters, digits and hyphens.")


def _validate_http(settings: Settings) -> None:
    # Both values are copied into response headers, so their shape is checked strictly.
    for origin in settings.cors_allowed_origins:
        if origin != "*" and _ORIGIN_PATTERN.fullmatch(origin) is None:
            raise ConfigError(
                f"CORS_ALLOWED_ORIGINS entry '{origin}' must be an origin such as https://app.example.com "
                "(scheme and host, optional port, no path or trailing slash)."
            )
    if _FRAME_ANCESTORS_PATTERN.fullmatch(settings.frame_ancestors) is None:
        raise ConfigError(
            "FRAME_ANCESTORS must be a CSP source list, e.g. 'none', 'self' or https://portal.example.com."
        )


def _validate_production(settings: Settings) -> None:
    if settings.jwt_secret_key.lower() in _PLACEHOLDER_SECRETS or len(settings.jwt_secret_key) < _MIN_SECRET_LENGTH:
        raise ConfigError(f"JWT_SECRET_KEY must be a random secret of at least {_MIN_SECRET_LENGTH} characters.")
    if settings.database_dialect == "sqlite":
        url = make_url(settings.database_url)
        if not url.database or not Path(url.database).is_absolute() or url.query.get("mode") == "memory":
            raise ConfigError(
                "Production SQLite requires an absolute path to a persistent database file (DATABASE_URL)."
            )
    if not settings.storage_root.is_absolute():
        raise ConfigError("STORAGE_ROOT must be an absolute path in production.")
    if "*" in settings.cors_allowed_origins:
        raise ConfigError("CORS_ALLOWED_ORIGINS must list explicit origins in production.")


def validate_settings(settings: Settings) -> None:
    """Reject inconsistent settings early; apply the strict production checks."""
    _validate_general(settings)
    _validate_uploads(settings)
    _validate_tracking_codes(settings)
    _validate_http(settings)
    if settings.is_production:
        _validate_production(settings)


def engine_options(settings: Settings) -> dict[str, Any]:
    """SQLAlchemy engine options tuned per database dialect."""
    if settings.database_dialect == "mysql":
        return {
            "pool_pre_ping": True,
            "pool_size": settings.db_pool_size,
            "max_overflow": settings.db_max_overflow,
            "pool_recycle": settings.db_pool_recycle_seconds,
            "isolation_level": "READ COMMITTED",
            "connect_args": {
                "charset": "utf8mb4",
                # Enforce strict SQL mode and UTC regardless of the server defaults.
                "init_command": ("SET SESSION sql_mode='TRADITIONAL,ONLY_FULL_GROUP_BY', SESSION time_zone='+00:00'"),
            },
        }
    # SQLite: wait for a concurrent writer; explicit BEGIN preserves SAVEPOINT semantics.
    return {"connect_args": {"timeout": 30}}


def flask_config(settings: Settings) -> dict[str, Any]:
    """Configuration keys consumed by Flask and its extensions."""
    return {
        "ENV_NAME": settings.env,
        "DEBUG": settings.debug,
        "TESTING": settings.testing,
        "PROPAGATE_EXCEPTIONS": False,
        "MAX_CONTENT_LENGTH": settings.max_request_size_bytes,
        "MAX_FORM_MEMORY_SIZE": 1024 * 1024,
        "SQLALCHEMY_DATABASE_URI": settings.database_url,
        "SQLALCHEMY_ENGINE_OPTIONS": engine_options(settings),
        "SQLALCHEMY_RECORD_QUERIES": False,
    }
