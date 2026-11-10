"""Password policy shared by user management and self-service password change."""

from __future__ import annotations

from app.config import Settings
from app.core.errors import ValidationFailedError
from app.core.text import fa_number

MAX_PASSWORD_LENGTH = 128
_MIN_USERNAME_LENGTH_FOR_CONTAINMENT_CHECK = 3


def validate_password(password: str, username: str, settings: Settings, field: str = "password") -> None:
    """Raise :class:`ValidationFailedError` when ``password`` violates the policy."""
    if len(password) < settings.password_min_length:
        raise ValidationFailedError.single(
            field, f"رمز عبور باید دست‌کم {fa_number(settings.password_min_length)} نویسه باشد."
        )
    if len(password) > MAX_PASSWORD_LENGTH:
        raise ValidationFailedError.single(
            field, f"رمز عبور نباید بیشتر از {fa_number(MAX_PASSWORD_LENGTH)} نویسه باشد."
        )
    if password.strip() == "":
        raise ValidationFailedError.single(field, "رمز عبور نمی‌تواند فقط شامل فاصله باشد.")
    if len(username) >= _MIN_USERNAME_LENGTH_FOR_CONTAINMENT_CHECK and username.lower() in password.lower():
        raise ValidationFailedError.single(field, "رمز عبور نباید شامل نام کاربری باشد.")
