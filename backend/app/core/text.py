"""Helpers for user-facing Persian text."""

from __future__ import annotations

_PERSIAN_DIGITS = str.maketrans("0123456789.", "۰۱۲۳۴۵۶۷۸۹٫")
_LEFT_TO_RIGHT_ISOLATE = "\u2066"
_POP_DIRECTIONAL_ISOLATE = "\u2069"
_MINUS_SIGN = "\u2212"


def fa_number(value: object) -> str:
    """Render a number for use inside a Persian sentence.

    Digits become Persian digits and ``.`` becomes the Persian decimal separator.
    A negative number is wrapped in a left-to-right isolate: without it the
    bidirectional algorithm draws the minus sign on the wrong side of the digits
    in right-to-left text.
    """
    text = str(value).translate(_PERSIAN_DIGITS)
    if text.startswith("-"):
        return f"{_LEFT_TO_RIGHT_ISOLATE}{_MINUS_SIGN}{text[1:]}{_POP_DIRECTIONAL_ISOLATE}"
    return text
