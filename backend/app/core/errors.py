"""Application-specific exception hierarchy.

Every error carries an HTTP status, a stable machine-readable ``code`` and a
user-facing (Persian) message. The centralized handlers in
``app.core.error_handlers`` serialize them into the common response envelope.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


class AppError(Exception):
    """Base class for all expected application errors."""

    status_code: int = 400
    code: str = "bad_request"
    default_message: str = "درخواست نامعتبر است."

    def __init__(
        self,
        message: str | None = None,
        *,
        code: str | None = None,
        details: Mapping[str, Any] | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> None:
        super().__init__(message or self.default_message)
        self.message: str = message or self.default_message
        if code is not None:
            self.code = code
        self.details: dict[str, Any] = dict(details or {})
        self.headers: dict[str, str] = dict(headers or {})


class BadRequestError(AppError):
    status_code = 400
    code = "bad_request"


class ValidationFailedError(AppError):
    """Input validation failure. ``fields`` maps field paths to lists of messages."""

    status_code = 422
    code = "validation_error"
    default_message = "اطلاعات ارسال‌شده معتبر نیست."

    def __init__(
        self,
        fields: Mapping[str, Any] | None = None,
        message: str | None = None,
        *,
        code: str | None = None,
    ) -> None:
        super().__init__(message, code=code, details={"fields": dict(fields or {})})

    @classmethod
    def single(cls, field: str, message: str, *, code: str | None = None) -> ValidationFailedError:
        return cls({field: [message]}, code=code)


class AuthenticationError(AppError):
    status_code = 401
    code = "authentication_required"
    default_message = "احراز هویت لازم است."

    def __init__(self, message: str | None = None, *, code: str | None = None) -> None:
        super().__init__(message, code=code, headers={"WWW-Authenticate": 'Bearer realm="api"'})


class CustomerSessionInvalidError(AppError):
    """A customer portal token that is unknown, expired, revoked or no longer applicable.

    Deliberately a single error for every cause, so the response reveals nothing
    about why the token stopped working.
    """

    status_code = 401
    code = "customer_session_invalid"
    default_message = "مهلت مشاهدهٔ این محموله تمام شده یا پیوند نامعتبر است. لطفاً دوباره کد رهگیری را وارد کنید."


class PermissionDeniedError(AppError):
    status_code = 403
    code = "permission_denied"
    default_message = "شما مجوز انجام این عملیات را ندارید."


class AccountDisabledError(AppError):
    """Valid credentials for an account (or company) that has been deactivated."""

    status_code = 403
    code = "account_disabled"
    default_message = "حساب کاربری شما غیرفعال است. با مدیر سامانه تماس بگیرید."


class NotFoundError(AppError):
    status_code = 404
    code = "not_found"
    default_message = "مورد درخواستی یافت نشد."


class ConflictError(AppError):
    status_code = 409
    code = "conflict"
    default_message = "این عملیات با وضعیت فعلی داده‌ها در تعارض است."


class PayloadTooLargeError(AppError):
    status_code = 413
    code = "payload_too_large"
    default_message = "حجم درخواست بیش از حد مجاز است."


class UnsupportedMediaTypeError(AppError):
    status_code = 415
    code = "unsupported_media_type"
    default_message = "قالب دادهٔ ارسال‌شده پشتیبانی نمی‌شود."


class RateLimitExceededError(AppError):
    status_code = 429
    code = "rate_limited"
    default_message = "تعداد درخواست‌ها بیش از حد مجاز است. لطفاً کمی بعد دوباره تلاش کنید."

    def __init__(self, retry_after_seconds: int, message: str | None = None) -> None:
        retry_after = max(1, int(retry_after_seconds))
        super().__init__(
            message,
            details={"retry_after_seconds": retry_after},
            headers={"Retry-After": str(retry_after)},
        )


class IntegrityFailureError(AppError):
    """Stored data failed an integrity verification (e.g. checksum mismatch)."""

    status_code = 500
    code = "integrity_error"
    default_message = "یکپارچگی دادهٔ ذخیره‌شده تأیید نشد."


class ServiceUnavailableError(AppError):
    status_code = 503
    code = "service_unavailable"
    default_message = "سرویس موقتاً در دسترس نیست."
