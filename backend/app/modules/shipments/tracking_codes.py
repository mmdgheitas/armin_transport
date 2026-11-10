"""Tracking code normalization, validation and secure generation."""

from __future__ import annotations

import re
import secrets
import unicodedata

from app.config import Settings
from app.core.client_settings import TRACKING_CODE_MAX_LENGTH, TRACKING_CODE_PATTERN
from app.core.text import fa_number

# Crockford base32 alphabet: no I, L, O or U, so codes are unambiguous when read aloud or typed.
AUTO_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

_PATTERN = re.compile(TRACKING_CODE_PATTERN)
_TRANSLATION = str.maketrans(
    {
        **{ord(digit): str(index) for index, digit in enumerate("۰۱۲۳۴۵۶۷۸۹")},  # Persian digits
        **{ord(digit): str(index) for index, digit in enumerate("٠١٢٣٤٥٦٧٨٩")},  # Arabic-Indic digits
        **{ord(dash): "-" for dash in "\u2010\u2011\u2012\u2013\u2014\u2015\u2212"},  # dash variants
        **{ord(mark): None for mark in "\u200b\u200c\u200d\u200e\u200f\u2060\ufeff"},  # zero-width marks
    }
)


class InvalidTrackingCodeError(ValueError):
    """The code cannot be a tracking code (user-facing Persian message)."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


def normalize_tracking_code(raw: str) -> str:
    """Return the canonical form used for storage, uniqueness checks and lookups.

    Compatibility-normalizes Unicode, maps Persian/Arabic digits and dash variants
    to ASCII, removes every whitespace and zero-width character and upper-cases.
    """
    text = unicodedata.normalize("NFKC", raw).translate(_TRANSLATION)
    return "".join(character for character in text if not character.isspace()).upper()


def validate_tracking_code(code: str, min_length: int) -> str:
    """Validate an already-normalized code and return it."""
    if len(code) < min_length:
        raise InvalidTrackingCodeError(f"کد رهگیری باید دست‌کم {fa_number(min_length)} نویسه باشد.")
    if len(code) > TRACKING_CODE_MAX_LENGTH:
        raise InvalidTrackingCodeError(f"کد رهگیری نباید بیشتر از {fa_number(TRACKING_CODE_MAX_LENGTH)} نویسه باشد.")
    if _PATTERN.fullmatch(code) is None:
        raise InvalidTrackingCodeError(
            "کد رهگیری فقط می‌تواند شامل حروف انگلیسی، رقم و خط تیره باشد و نباید با خط تیره شروع یا تمام شود."
        )
    return code


class TrackingCodeGenerator:
    """Generates non-sequential, unpredictable tracking codes from the OS CSPRNG.

    The default of 16 symbols carries 80 bits of entropy, which makes guessing a
    valid code infeasible even before the lookup rate limits are considered.
    """

    def __init__(self, settings: Settings) -> None:
        self._length = settings.tracking_code_auto_length
        self._group_size = settings.tracking_code_auto_group_size
        self._prefix = settings.tracking_code_auto_prefix

    def generate(self) -> str:
        body = "".join(secrets.choice(AUTO_CODE_ALPHABET) for _ in range(self._length))
        if self._group_size:
            body = "-".join(body[index : index + self._group_size] for index in range(0, len(body), self._group_size))
        return f"{self._prefix}-{body}" if self._prefix else body

    def max_generated_length(self) -> int:
        separators = (self._length - 1) // self._group_size if self._group_size else 0
        prefix = len(self._prefix) + 1 if self._prefix else 0
        return prefix + self._length + separators
