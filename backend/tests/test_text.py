"""Numbers inside Persian messages are written with Persian digits."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Any

import pytest
from marshmallow import ValidationError

from app.core import fields
from app.core.text import fa_number
from app.models.enums import ProductFieldType
from app.modules.product_fields.validation import FieldValidationError, validate_value
from app.modules.shipments.tracking_codes import InvalidTrackingCodeError, validate_tracking_code

LEFT_TO_RIGHT_ISOLATE = "\u2066"
POP_DIRECTIONAL_ISOLATE = "\u2069"
ASCII_DIGITS = set("0123456789")


@dataclass(frozen=True)
class Definition:
    data_type: ProductFieldType
    validation_rules: dict[str, Any] | None = None
    options: list[dict[str, Any]] | None = None


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (0, "۰"),
        (1234567890, "۱۲۳۴۵۶۷۸۹۰"),
        ("12.5", "۱۲٫۵"),
        (Decimal("0.250"), "۰٫۲۵۰"),
        (10.0, "۱۰٫۰"),
    ],
)
def test_digits_and_the_decimal_point_become_persian(value: object, expected: str) -> None:
    assert fa_number(value) == expected


@pytest.mark.parametrize(("value", "digits"), [(-25, "۲۵"), ("-0.5", "۰٫۵"), (Decimal("-18"), "۱۸")])
def test_a_negative_number_keeps_its_sign_on_the_left_in_right_to_left_text(value: object, digits: str) -> None:
    # Without the isolate the bidirectional algorithm draws the minus sign to the right of the digits.
    assert fa_number(value) == f"{LEFT_TO_RIGHT_ISOLATE}\u2212{digits}{POP_DIRECTIONAL_ISOLATE}"


def test_length_and_range_messages_use_persian_digits() -> None:
    with pytest.raises(ValidationError) as too_short:
        fields.length(min=2, max=200)("x")
    assert too_short.value.messages == ["طول مقدار باید بین ۲ و ۲۰۰ نویسه باشد."]

    with pytest.raises(ValidationError) as too_long:
        fields.length(max=5)("123456")
    assert too_long.value.messages == ["طول مقدار نباید بیشتر از ۵ نویسه باشد."]

    with pytest.raises(ValidationError) as out_of_range:
        fields.number_range(min=1, max=100)(0)
    assert out_of_range.value.messages == ["مقدار باید بین ۱ و ۱۰۰ باشد."]

    with pytest.raises(ValidationError) as too_small:
        fields.number_range(min=1)(0)
    assert too_small.value.messages == ["مقدار باید دست‌کم ۱ باشد."]


@pytest.mark.parametrize(
    ("definition", "value", "expected"),
    [
        (Definition(ProductFieldType.NUMBER, {"min": 1, "max": 100000}), 0, "مقدار باید دست‌کم ۱ باشد."),
        (Definition(ProductFieldType.NUMBER, {"min": 1, "max": 100000}), 100001, "مقدار نباید بیشتر از ۱۰۰۰۰۰ باشد."),
        (
            Definition(ProductFieldType.NUMBER, {"min": -25, "max": 8}),
            -30,
            f"مقدار باید دست‌کم {LEFT_TO_RIGHT_ISOLATE}\u2212۲۵{POP_DIRECTIONAL_ISOLATE} باشد.",
        ),
        (Definition(ProductFieldType.DECIMAL, {"max": "99.5"}), "100", "مقدار نباید بیشتر از ۹۹٫۵ باشد."),
        (
            Definition(ProductFieldType.DECIMAL, {"max_decimal_places": 3}),
            "1.23456",
            "تعداد رقم‌های اعشار نباید بیشتر از ۳ باشد.",
        ),
        (Definition(ProductFieldType.TEXT, {"min_length": 3}), "ab", "طول متن باید دست‌کم ۳ نویسه باشد."),
        (Definition(ProductFieldType.TEXT, {"max_length": 4}), "abcde", "طول متن نباید بیشتر از ۴ نویسه باشد."),
        (
            Definition(
                ProductFieldType.MULTI_SELECT,
                {"min_items": 2},
                [{"value": "a", "label": "الف"}, {"value": "b", "label": "ب"}],
            ),
            ["a"],
            "دست‌کم ۲ گزینه باید انتخاب شود.",
        ),
    ],
)
def test_field_rule_messages_use_persian_digits(definition: Definition, value: object, expected: str) -> None:
    with pytest.raises(FieldValidationError) as rejected:
        validate_value(definition, value)
    assert rejected.value.message == expected


def test_a_date_limit_is_named_as_a_gregorian_date() -> None:
    # The API stores Gregorian dates; clients show the limit in the user's calendar themselves.
    with pytest.raises(FieldValidationError) as rejected:
        validate_value(Definition(ProductFieldType.DATE, {"min": "2026-03-21"}), "2026-03-20")
    assert rejected.value.message == "تاریخ نباید قبل از 2026-03-21 (میلادی) باشد."


def test_tracking_code_length_message_uses_persian_digits() -> None:
    with pytest.raises(InvalidTrackingCodeError) as rejected:
        validate_tracking_code("AB1", 6)
    message = str(rejected.value)
    assert "۶" in message
    assert not ASCII_DIGITS & set(message)
