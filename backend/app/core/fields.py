"""Marshmallow field types and validators with Persian error messages.

Using these subclasses (instead of mutating marshmallow's global defaults) keeps
user-facing validation messages consistent across the API.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from marshmallow import fields, validate

from app.core.datetime_utils import to_iso

_COMMON_MESSAGES = {
    "required": "این فیلد الزامی است.",
    "null": "این فیلد نمی‌تواند خالی باشد.",
    "validator_failed": "مقدار واردشده معتبر نیست.",
}


class String(fields.String):
    """String field that trims surrounding whitespace on input."""

    default_error_messages = {
        **_COMMON_MESSAGES,
        "invalid": "مقدار باید متن باشد.",
        "invalid_utf8": "رمزگذاری متن نامعتبر است.",
    }

    def __init__(self, *, strip: bool = True, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._strip = strip

    def _deserialize(self, value: Any, attr: str | None, data: Any, **kwargs: Any) -> Any:
        result = super()._deserialize(value, attr, data, **kwargs)
        return result.strip() if self._strip and isinstance(result, str) else result


class Integer(fields.Integer):
    default_error_messages = {
        **_COMMON_MESSAGES,
        "invalid": "مقدار باید عدد صحیح باشد.",
        "too_large": "عدد واردشده بیش از حد بزرگ است.",
    }


class Boolean(fields.Boolean):
    default_error_messages = {**_COMMON_MESSAGES, "invalid": "مقدار باید درست یا نادرست (true/false) باشد."}


class UUID(fields.UUID):
    default_error_messages = {**_COMMON_MESSAGES, "invalid_uuid": "شناسه نامعتبر است."}


class DateTime(fields.DateTime):
    """Date-time field. Output is always UTC in the canonical ``YYYY-MM-DDTHH:MM:SS.mmmZ`` form."""

    default_error_messages = {
        **_COMMON_MESSAGES,
        "invalid": "تاریخ و زمان نامعتبر است.",
        "invalid_awareness": "تاریخ و زمان باید همراه با منطقهٔ زمانی باشد.",
        "format": "قالب تاریخ و زمان نامعتبر است.",
    }

    def _serialize(self, value: Any, attr: str | None, obj: Any, **kwargs: Any) -> str | None:
        return to_iso(value)


class AwareDateTime(fields.AwareDateTime):
    default_error_messages = {
        **_COMMON_MESSAGES,
        "invalid": "تاریخ و زمان نامعتبر است.",
        "invalid_awareness": "تاریخ و زمان باید همراه با منطقهٔ زمانی باشد.",
        "format": "قالب تاریخ و زمان نامعتبر است.",
    }


class Date(fields.Date):
    default_error_messages = {
        **_COMMON_MESSAGES,
        "invalid": "تاریخ نامعتبر است.",
        "format": "قالب تاریخ نامعتبر است.",
    }


class Raw(fields.Raw):
    default_error_messages = dict(_COMMON_MESSAGES)


class Dict(fields.Dict):
    default_error_messages = {**_COMMON_MESSAGES, "invalid": "مقدار باید یک شیء (object) باشد."}


class List(fields.List[Any]):
    default_error_messages = {**_COMMON_MESSAGES, "invalid": "مقدار باید یک فهرست باشد."}


class Nested(fields.Nested):
    default_error_messages = {**_COMMON_MESSAGES, "type": "نوع دادهٔ ورودی نامعتبر است."}


class Enum(fields.Enum[Any]):
    default_error_messages = {**_COMMON_MESSAGES, "unknown": "مقدار باید یکی از این موارد باشد: {choices}."}


def length(min: int | None = None, max: int | None = None) -> validate.Length:
    if min is not None and max is not None:
        message = "طول مقدار باید بین {min} و {max} نویسه باشد."
    elif min is not None:
        message = "طول مقدار باید دست‌کم {min} نویسه باشد."
    else:
        message = "طول مقدار نباید بیشتر از {max} نویسه باشد."
    return validate.Length(min=min, max=max, error=message)


def number_range(min: int | None = None, max: int | None = None) -> validate.Range:
    if min is not None and max is not None:
        message = "مقدار باید بین {min} و {max} باشد."
    elif min is not None:
        message = "مقدار باید دست‌کم {min} باشد."
    else:
        message = "مقدار نباید بیشتر از {max} باشد."
    return validate.Range(min=min, max=max, error=message)


def one_of(choices: Iterable[Any]) -> validate.OneOf:
    return validate.OneOf(list(choices), error="مقدار باید یکی از این موارد باشد: {choices}.")


def regexp(pattern: str, message: str) -> validate.Regexp:
    return validate.Regexp(pattern, error=message)
