"""Unit tests for environment-driven configuration."""

from __future__ import annotations

import pytest

from app.config import ConfigError, RateLimitRule, engine_options, load_settings

_PROD_ENV = {
    "DATABASE_URL": "sqlite:////var/lib/armin-transport/armin_transport.sqlite3",
    "JWT_SECRET_KEY": "x" * 48,
    "STORAGE_ROOT": "/var/lib/armin-transport/storage",
}


def test_testing_defaults_use_fast_hashing_and_sqlite_fallback() -> None:
    settings = load_settings("testing", environ={})
    assert settings.testing is True
    assert settings.database_dialect == "sqlite"
    assert settings.argon2_time_cost == 1
    assert settings.employee_can_use_manual_tracking_code is False
    assert settings.employee_can_delete_documents is False
    assert settings.customer_session_ttl_seconds == 1800


def test_testing_uses_test_database_url_never_the_main_database() -> None:
    environ = {"DATABASE_URL": "mysql+pymysql://u:p@h/prod", "TEST_DATABASE_URL": "mysql+pymysql://u:p@h/test"}
    assert load_settings("testing", environ=environ).database_url.endswith("/test")
    assert load_settings("testing", environ={"DATABASE_URL": environ["DATABASE_URL"]}).database_dialect == "sqlite"


def test_development_defaults_to_a_persistent_private_sqlite_file() -> None:
    settings = load_settings("development", environ={})
    assert settings.database_dialect == "sqlite"
    assert settings.database_url.endswith("/backend/instance/armin_transport.sqlite3")


def test_unknown_environment_is_rejected() -> None:
    with pytest.raises(ConfigError, match="APP_ENV"):
        load_settings("staging", environ={})


def test_production_accepts_a_complete_configuration() -> None:
    settings = load_settings("production", environ=_PROD_ENV)
    assert settings.is_production
    assert settings.debug is False
    assert settings.log_format == "json"
    assert settings.hsts_enabled is True


@pytest.mark.parametrize(
    ("override", "message"),
    [
        ({"JWT_SECRET_KEY": ""}, "JWT_SECRET_KEY"),
        ({"JWT_SECRET_KEY": "short"}, "JWT_SECRET_KEY"),
        ({"JWT_SECRET_KEY": "change-me"}, "JWT_SECRET_KEY"),
        ({"DATABASE_URL": "sqlite:///prod.db"}, "absolute path"),
        ({"DATABASE_URL": "sqlite:///:memory:"}, "persistent"),
        ({"DATABASE_URL": "sqlite://"}, "persistent"),
        ({"STORAGE_ROOT": "relative/storage"}, "STORAGE_ROOT"),
        ({"CORS_ALLOWED_ORIGINS": "*"}, "CORS_ALLOWED_ORIGINS"),
    ],
)
def test_production_refuses_unsafe_configuration(override: dict[str, str], message: str) -> None:
    with pytest.raises(ConfigError, match=message):
        load_settings("production", environ={**_PROD_ENV, **override})


def test_debug_can_never_be_enabled_in_production() -> None:
    settings = load_settings("production", environ={**_PROD_ENV, "APP_DEBUG": "true"})
    assert settings.debug is False


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("EMPLOYEE_CAN_DELETE_DOCUMENTS", "maybe"),
        ("RATE_LIMIT_LOGIN_IP", "30"),
        ("RATE_LIMIT_LOGIN_IP", "0/60"),
        ("JWT_ALGORITHM", "none"),
        ("LOG_FORMAT", "xml"),
        ("ALLOWED_UPLOAD_EXTENSIONS", "pdf,exe"),
        ("ALLOWED_UPLOAD_EXTENSIONS", "pdf,csv"),
        ("TRACKING_CODE_AUTO_PREFIX", "AB CD"),
        ("TRACKING_CODE_AUTO_LENGTH", "8"),
        ("CUSTOMER_SESSION_TTL_SECONDS", "5"),
        ("PASSWORD_MIN_LENGTH", "4"),
    ],
)
def test_invalid_values_are_rejected(name: str, value: str) -> None:
    with pytest.raises(ConfigError):
        load_settings("testing", environ={name: value})


def test_page_size_consistency_is_checked() -> None:
    with pytest.raises(ConfigError, match="DEFAULT_PAGE_SIZE"):
        load_settings("testing", environ={"DEFAULT_PAGE_SIZE": "50", "MAX_PAGE_SIZE": "20"})


def test_generated_tracking_codes_must_fit_the_column() -> None:
    with pytest.raises(ConfigError, match="TRACKING_CODE"):
        load_settings(
            "testing",
            environ={
                "TRACKING_CODE_AUTO_LENGTH": "40",
                "TRACKING_CODE_AUTO_GROUP_SIZE": "2",
                "TRACKING_CODE_AUTO_PREFIX": "ARMIN",
            },
        )


def test_business_rules_are_configurable() -> None:
    settings = load_settings(
        "testing",
        environ={
            "EMPLOYEE_CAN_USE_MANUAL_TRACKING_CODE": "true",
            "EMPLOYEE_CAN_DELETE_DOCUMENTS": "yes",
            "MAX_UPLOAD_SIZE_BYTES": "2048",
            "ALLOWED_UPLOAD_EXTENSIONS": "PDF, .png",
            "CUSTOMER_SESSION_TTL_SECONDS": "300",
        },
    )
    assert settings.employee_can_use_manual_tracking_code is True
    assert settings.employee_can_delete_documents is True
    assert settings.max_upload_size_bytes == 0  # Uploads are unlimited by business policy.
    assert settings.allowed_upload_extensions == frozenset({"pdf", "png"})
    assert settings.customer_session_ttl_seconds == 300


def test_rate_limit_rule_parsing() -> None:
    assert RateLimitRule.parse(" 10/60 ", "X") == RateLimitRule(limit=10, window_seconds=60)


def test_mysql_engine_enforces_strict_mode_utc_and_read_committed() -> None:
    options = engine_options(
        load_settings("production", environ={**_PROD_ENV, "DATABASE_URL": "mysql+pymysql://u:p@h/db"})
    )
    assert options["isolation_level"] == "READ COMMITTED"
    assert options["pool_pre_ping"] is True
    init_command = options["connect_args"]["init_command"]
    assert "TRADITIONAL" in init_command
    assert "time_zone='+00:00'" in init_command
    assert options["connect_args"]["charset"] == "utf8mb4"


@pytest.mark.parametrize(
    "value",
    ["'none'", "'self'", "*", "https://portal.example.com", "'self' https://a.example.com https://*.example.org:8443"],
)
def test_frame_ancestors_accepts_csp_source_lists(value: str) -> None:
    assert load_settings("testing", environ={"FRAME_ANCESTORS": value}).frame_ancestors == value


@pytest.mark.parametrize(
    "value",
    [
        "'none'; script-src *",  # directive injection
        "'self'\nX-Injected: 1",
        "none",  # CSP keywords must be quoted
        "'none' 'self'",
        "javascript:alert(1)",
        "https://a.example.com/path",
        "'self'  https://a.example.com",  # exactly one space between sources
        ";",
    ],
)
def test_frame_ancestors_rejects_anything_else(value: str) -> None:
    with pytest.raises(ConfigError, match="FRAME_ANCESTORS"):
        load_settings("testing", environ={"FRAME_ANCESTORS": value})


def test_cors_origins_must_be_bare_origins() -> None:
    settings = load_settings(
        "testing", environ={"CORS_ALLOWED_ORIGINS": "https://app.example.com, http://localhost:5173"}
    )
    assert settings.cors_allowed_origins == ("https://app.example.com", "http://localhost:5173")
    for value in (
        "https://app.example.com/",
        "app.example.com",
        "https://app.example.com/path",
        "https://a.example; x",
    ):
        with pytest.raises(ConfigError, match="CORS_ALLOWED_ORIGINS"):
            load_settings("testing", environ={"CORS_ALLOWED_ORIGINS": value})
    assert load_settings(
        "development", environ={"DATABASE_URL": "sqlite://", "CORS_ALLOWED_ORIGINS": "*"}
    ).cors_allowed_origins == ("*",)
    with pytest.raises(ConfigError, match="explicit origins"):
        load_settings("production", environ={**_PROD_ENV, "CORS_ALLOWED_ORIGINS": "*"})


@pytest.mark.parametrize(
    "url", ["postgresql://u:p@h/db", "mariadb+pymysql://u:p@h/db", "oracle://u:p@h/db", "not-a-url"]
)
def test_only_sqlite_and_optional_mysql_are_supported(url: str) -> None:
    with pytest.raises(ConfigError, match="DATABASE_URL must point to SQLite"):
        load_settings("development", environ={"DATABASE_URL": url})
    with pytest.raises(ConfigError, match="DATABASE_URL must point to SQLite"):
        load_settings("testing", environ={"TEST_DATABASE_URL": url})


def test_sqlite_engine_waits_for_concurrent_writers() -> None:
    assert engine_options(load_settings("testing", environ={})) == {"connect_args": {"timeout": 30}}
