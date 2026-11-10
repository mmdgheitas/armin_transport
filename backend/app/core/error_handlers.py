"""Centralized exception handling: every failure becomes the common error envelope."""

from __future__ import annotations

import logging

from flask import Flask, Response, g, request
from marshmallow import ValidationError as MarshmallowValidationError
from sqlalchemy.exc import IntegrityError, OperationalError
from werkzeug.exceptions import HTTPException

from app.core.api import get_services
from app.core.db_utils import driver_error_code
from app.core.errors import AppError, PermissionDeniedError
from app.core.http import mask_sensitive_path
from app.core.responses import error_response
from app.core.schemas import flatten_errors
from app.extensions import db

logger = logging.getLogger(__name__)

_HTTP_MESSAGES: dict[int, tuple[str, str]] = {
    400: ("bad_request", "درخواست نامعتبر است."),
    401: ("authentication_required", "احراز هویت لازم است."),
    403: ("permission_denied", "شما مجوز انجام این عملیات را ندارید."),
    404: ("not_found", "مورد درخواستی یافت نشد."),
    405: ("method_not_allowed", "این روش درخواست برای این نشانی مجاز نیست."),
    413: ("payload_too_large", "حجم درخواست بیش از حد مجاز است."),
    415: ("unsupported_media_type", "قالب دادهٔ ارسال‌شده پشتیبانی نمی‌شود."),
    429: ("rate_limited", "تعداد درخواست‌ها بیش از حد مجاز است."),
}


_CONFLICT_MESSAGE = "این عملیات با داده‌های موجود در تعارض است."
_MYSQL_CHECK_CONSTRAINT_VIOLATED = 3819


def _rollback() -> None:
    """Never leave a failed transaction attached to the request session."""
    try:
        db.session.rollback()
    except Exception:  # pragma: no cover - defensive: the original error matters more
        logger.exception("Rollback failed while handling an error")


def _audit_access_denied(error: PermissionDeniedError) -> None:
    actor = g.get("actor")
    try:
        get_services().audit.record_isolated(
            "ACCESS_DENIED",
            "http_request",
            None,
            actor_id=actor.user_id if actor else None,
            metadata={
                "method": request.method,
                "path": mask_sensitive_path(request.path),
                "code": error.code,
                "required_permissions": error.details.get("required_permissions"),
            },
        )
    except Exception:  # pragma: no cover - auditing must not mask the original response
        logger.exception("Failed to record ACCESS_DENIED audit event")
        _rollback()


def register_error_handlers(app: Flask) -> None:
    @app.errorhandler(AppError)
    def handle_app_error(error: AppError) -> Response:
        _rollback()
        if isinstance(error, PermissionDeniedError):
            _audit_access_denied(error)
        level = logging.ERROR if error.status_code >= 500 else logging.INFO
        logger.log(level, "Request failed: %s", error.code, extra={"status": error.status_code, "code": error.code})
        return error_response(error.message, error.status_code, error.code, error.details, error.headers)

    @app.errorhandler(MarshmallowValidationError)
    def handle_validation_error(error: MarshmallowValidationError) -> Response:
        _rollback()
        return error_response(
            "اطلاعات ارسال‌شده معتبر نیست.",
            422,
            "validation_error",
            {"fields": flatten_errors(error.normalized_messages())},  # type: ignore[no-untyped-call]
        )

    @app.errorhandler(HTTPException)
    def handle_http_exception(error: HTTPException) -> Response:
        _rollback()
        status = error.code or 500
        code, message = _HTTP_MESSAGES.get(status, ("http_error", "درخواست قابل انجام نیست."))
        return error_response(message, status, code)

    @app.errorhandler(IntegrityError)
    def handle_integrity_error(error: IntegrityError) -> Response:
        _rollback()
        logger.warning("Unhandled database integrity error: %s", type(error.orig).__name__)
        return error_response(_CONFLICT_MESSAGE, 409, "conflict")

    @app.errorhandler(OperationalError)
    def handle_operational_error(error: OperationalError) -> Response:
        _rollback()
        if driver_error_code(error) == _MYSQL_CHECK_CONSTRAINT_VIOLATED:
            # PyMySQL classifies a violated CHECK constraint as "operational"; it is a data conflict.
            logger.warning("Unhandled database check-constraint violation")
            return error_response(_CONFLICT_MESSAGE, 409, "conflict")
        logger.error("Database operational error", exc_info=error)
        return error_response("سرویس موقتاً در دسترس نیست.", 503, "service_unavailable")

    @app.errorhandler(Exception)
    def handle_unexpected_error(error: Exception) -> Response:
        _rollback()
        # The stack trace goes to the log (with the correlation id), never to the client.
        logger.error("Unhandled exception", exc_info=error)
        return error_response("خطای داخلی سرور رخ داده است.", 500, "internal_error")
