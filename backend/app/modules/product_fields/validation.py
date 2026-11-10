"""Validation rules for dynamic product fields (pure functions, no I/O).

The backend is the single authority for these rules; web and Flutter only render
the definitions they receive and display the validation errors returned here.
"""

from __future__ import annotations

import re
import re._parser as _regex_parser  # type: ignore[import-not-found]  # CPython's regex parser (3.11+)
from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, date, datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Protocol

from app.models.enums import ProductFieldType

MAX_TEXT_LENGTH = 2000
MAX_PATTERN_LENGTH = 200
MAX_OPTIONS = 200
MAX_OPTION_VALUE_LENGTH = 100
MAX_OPTION_LABEL_LENGTH = 200
MAX_SAFE_INTEGER = 9_007_199_254_740_991  # 2**53 - 1: exact in JSON/JavaScript/Dart clients
MAX_DECIMAL_DIGITS = 30
DEFAULT_MAX_DECIMAL_PLACES = 6
MAX_DECIMAL_PLACES = 12
OPTION_TYPES = frozenset({ProductFieldType.SELECT, ProductFieldType.MULTI_SELECT})


class FieldValidationError(ValueError):
    """A single user-facing (Persian) validation message."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class FieldDefinitionLike(Protocol):
    @property
    def data_type(self) -> ProductFieldType: ...
    @property
    def validation_rules(self) -> dict[str, Any] | None: ...
    @property
    def options(self) -> list[dict[str, Any]] | None: ...


# --------------------------------------------------------------------------- primitives
def _as_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise FieldValidationError(f"مقدار «{name}» باید عدد صحیح باشد.")
    return value


def _as_decimal(value: Any) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, int | float | str | Decimal):
        raise FieldValidationError("مقدار باید عدد اعشاری باشد.")
    try:
        number = Decimal(str(value).strip())
    except (InvalidOperation, ValueError) as exc:
        raise FieldValidationError("مقدار باید عدد اعشاری معتبر باشد.") from exc
    if not number.is_finite():
        raise FieldValidationError("مقدار باید عدد اعشاری معتبر باشد.")
    _, digits, exponent = number.as_tuple()
    # Bound the magnitude before any formatting so absurd exponents cannot exhaust memory.
    if (
        not isinstance(exponent, int)
        or len(digits) + max(exponent, 0) > MAX_DECIMAL_DIGITS
        or exponent < -MAX_DECIMAL_DIGITS
    ):
        raise FieldValidationError("عدد واردشده خارج از محدودهٔ مجاز است.")
    return number


def _as_date(value: Any) -> date:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value.strip()):
        raise FieldValidationError("تاریخ باید با قالب YYYY-MM-DD باشد.")
    try:
        return date.fromisoformat(value.strip())
    except ValueError as exc:
        raise FieldValidationError("تاریخ واردشده معتبر نیست.") from exc


def _as_datetime(value: Any) -> datetime:
    if not isinstance(value, str):
        raise FieldValidationError("تاریخ و زمان باید با قالب ISO 8601 باشد.")
    try:
        parsed = datetime.fromisoformat(value.strip())
    except ValueError as exc:
        raise FieldValidationError("تاریخ و زمان واردشده معتبر نیست.") from exc
    if parsed.tzinfo is None:
        raise FieldValidationError("تاریخ و زمان باید همراه با منطقهٔ زمانی (مثلاً Z) باشد.")
    return parsed.astimezone(UTC).replace(microsecond=0)


def _format_decimal(number: Decimal) -> str:
    text = format(number, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in {"", "-0"} else text


def _format_datetime(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------- pattern safety
_REPEAT_OPCODES = frozenset({"MAX_REPEAT", "MIN_REPEAT", "POSSESSIVE_REPEAT"})
_NESTING_OPCODES = frozenset({"ASSERT", "ASSERT_NOT", "ATOMIC_GROUP"})
_BACKREFERENCE_OPCODES = frozenset({"GROUPREF", "GROUPREF_EXISTS"})


def _has_risky_structure(items: Any, inside_repeat: bool) -> bool:  # noqa: PLR0911 - one exit per node kind
    for opcode, argument in items:
        name = str(opcode)
        if name in _BACKREFERENCE_OPCODES:
            return True
        if name in _REPEAT_OPCODES:
            _minimum, maximum, body = argument
            repeats = int(maximum) > 1
            if repeats and inside_repeat:
                return True
            if _has_risky_structure(body, inside_repeat or repeats):
                return True
        elif name == "BRANCH":
            if inside_repeat:
                return True
            if any(_has_risky_structure(branch, inside_repeat) for branch in argument[1]):
                return True
        elif name == "SUBPATTERN":
            if _has_risky_structure(argument[3], inside_repeat):
                return True
        elif name in _NESTING_OPCODES:
            body = argument[1] if name != "ATOMIC_GROUP" else argument
            if _has_risky_structure(body, inside_repeat):
                return True
    return False


def is_safe_pattern(pattern: str) -> bool:
    """Conservative guard against catastrophic backtracking (ReDoS).

    Patterns are defined by administrators but evaluated against values submitted
    by every user, so only structures with predictable matching cost are accepted:
    no repetition inside repetition, no alternation inside repetition and no
    back-references. Anything that cannot be analysed is refused.
    """
    try:
        return not _has_risky_structure(_regex_parser.parse(pattern), inside_repeat=False)
    except Exception:
        return False


# --------------------------------------------------------------------------- definition rules
def _normalize_text_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in ("min_length", "max_length"):
        if key in rules:
            number = _as_int(rules[key], key)
            if not 0 <= number <= MAX_TEXT_LENGTH:
                raise FieldValidationError(f"مقدار «{key}» باید بین ۰ و {MAX_TEXT_LENGTH} باشد.")
            result[key] = number
    if "min_length" in result and "max_length" in result and result["min_length"] > result["max_length"]:
        raise FieldValidationError("حداقل طول نمی‌تواند بیشتر از حداکثر طول باشد.")
    if "pattern" in rules:
        pattern = rules["pattern"]
        if not isinstance(pattern, str) or not 1 <= len(pattern) <= MAX_PATTERN_LENGTH:
            raise FieldValidationError(f"الگو باید متنی با حداکثر {MAX_PATTERN_LENGTH} نویسه باشد.")
        try:
            re.compile(pattern)
        except re.error as exc:
            raise FieldValidationError("الگوی عبارت باقاعده معتبر نیست.") from exc
        if not is_safe_pattern(pattern):
            raise FieldValidationError(
                "این الگو پشتیبانی نمی‌شود: تکرارهای تودرتو، انتخاب (|) درون تکرار و ارجاع به گروه مجاز نیستند."
            )
        result["pattern"] = pattern
    return result


def _normalize_number_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    result = {key: _as_int(rules[key], key) for key in ("min", "max") if key in rules}
    if "min" in result and "max" in result and result["min"] > result["max"]:
        raise FieldValidationError("حداقل مقدار نمی‌تواند بیشتر از حداکثر مقدار باشد.")
    return result


def _normalize_decimal_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    bounds = {key: _as_decimal(rules[key]) for key in ("min", "max") if key in rules}
    if "min" in bounds and "max" in bounds and bounds["min"] > bounds["max"]:
        raise FieldValidationError("حداقل مقدار نمی‌تواند بیشتر از حداکثر مقدار باشد.")
    result.update({key: _format_decimal(value) for key, value in bounds.items()})
    if "max_decimal_places" in rules:
        places = _as_int(rules["max_decimal_places"], "max_decimal_places")
        if not 0 <= places <= MAX_DECIMAL_PLACES:
            raise FieldValidationError(f"تعداد رقم اعشار باید بین ۰ و {MAX_DECIMAL_PLACES} باشد.")
        result["max_decimal_places"] = places
    return result


def _normalize_date_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    bounds = {key: _as_date(rules[key]) for key in ("min", "max") if key in rules}
    if "min" in bounds and "max" in bounds and bounds["min"] > bounds["max"]:
        raise FieldValidationError("حداقل تاریخ نمی‌تواند بعد از حداکثر تاریخ باشد.")
    return {key: value.isoformat() for key, value in bounds.items()}


def _normalize_datetime_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    bounds = {key: _as_datetime(rules[key]) for key in ("min", "max") if key in rules}
    if "min" in bounds and "max" in bounds and bounds["min"] > bounds["max"]:
        raise FieldValidationError("حداقل زمان نمی‌تواند بعد از حداکثر زمان باشد.")
    return {key: _format_datetime(value) for key, value in bounds.items()}


def _normalize_multi_select_rules(rules: Mapping[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in ("min_items", "max_items"):
        if key in rules:
            number = _as_int(rules[key], key)
            if not 0 <= number <= MAX_OPTIONS:
                raise FieldValidationError(f"مقدار «{key}» باید بین ۰ و {MAX_OPTIONS} باشد.")
            result[key] = number
    if "min_items" in result and "max_items" in result and result["min_items"] > result["max_items"]:
        raise FieldValidationError("حداقل تعداد انتخاب نمی‌تواند بیشتر از حداکثر آن باشد.")
    return result


_RULE_NORMALIZERS = {
    ProductFieldType.TEXT: (frozenset({"min_length", "max_length", "pattern"}), _normalize_text_rules),
    ProductFieldType.NUMBER: (frozenset({"min", "max"}), _normalize_number_rules),
    ProductFieldType.DECIMAL: (frozenset({"min", "max", "max_decimal_places"}), _normalize_decimal_rules),
    ProductFieldType.DATE: (frozenset({"min", "max"}), _normalize_date_rules),
    ProductFieldType.DATETIME: (frozenset({"min", "max"}), _normalize_datetime_rules),
    ProductFieldType.MULTI_SELECT: (frozenset({"min_items", "max_items"}), _normalize_multi_select_rules),
}


def normalize_rules(data_type: ProductFieldType, rules: Any) -> dict[str, Any] | None:
    """Validate ``validation_rules`` for ``data_type`` and return their canonical form."""
    if rules is None or rules == {}:
        return None
    if not isinstance(rules, Mapping):
        raise FieldValidationError("قواعد اعتبارسنجی باید یک شیء (object) باشد.")
    allowed, normalizer = _RULE_NORMALIZERS.get(data_type, (frozenset(), None))
    unknown = sorted(set(rules) - allowed)
    if unknown:
        raise FieldValidationError(f"این قواعد برای نوع {data_type.value} پشتیبانی نمی‌شوند: {', '.join(unknown)}")
    if normalizer is None:
        return None
    return normalizer(rules) or None


def normalize_options(data_type: ProductFieldType, options: Any) -> list[dict[str, str]] | None:
    """Validate the option list of SELECT / MULTI_SELECT fields."""
    if data_type not in OPTION_TYPES:
        if options:
            raise FieldValidationError("گزینه‌ها فقط برای فیلدهای انتخابی قابل تعریف هستند.")
        return None
    if not isinstance(options, Sequence) or isinstance(options, str | bytes) or len(options) == 0:
        raise FieldValidationError("برای فیلد انتخابی دست‌کم یک گزینه لازم است.")
    if len(options) > MAX_OPTIONS:
        raise FieldValidationError(f"تعداد گزینه‌ها نباید بیشتر از {MAX_OPTIONS} باشد.")
    normalized: list[dict[str, str]] = []
    seen: set[str] = set()
    for option in options:
        if not isinstance(option, Mapping) or set(option) - {"value", "label"}:
            raise FieldValidationError("هر گزینه باید فقط شامل «value» و «label» باشد.")
        value, label = option.get("value"), option.get("label")
        if not isinstance(value, str) or not 1 <= len(value.strip()) <= MAX_OPTION_VALUE_LENGTH:
            raise FieldValidationError(f"مقدار هر گزینه باید متنی با ۱ تا {MAX_OPTION_VALUE_LENGTH} نویسه باشد.")
        if not isinstance(label, str) or not 1 <= len(label.strip()) <= MAX_OPTION_LABEL_LENGTH:
            raise FieldValidationError(f"برچسب هر گزینه باید متنی با ۱ تا {MAX_OPTION_LABEL_LENGTH} نویسه باشد.")
        value = value.strip()
        if value in seen:
            raise FieldValidationError(f"مقدار گزینهٔ «{value}» تکراری است.")
        seen.add(value)
        normalized.append({"value": value, "label": label.strip()})
    return normalized


# --------------------------------------------------------------------------- values
def is_empty_value(value: Any) -> bool:
    """``None``, blank text and empty lists all mean "no value supplied"."""
    return value is None or (isinstance(value, str) and value.strip() == "") or value == []


def _validate_text(value: Any, rules: Mapping[str, Any]) -> str:
    if not isinstance(value, str):
        raise FieldValidationError("مقدار باید متن باشد.")
    text = value.strip()
    max_length = min(int(rules.get("max_length", MAX_TEXT_LENGTH)), MAX_TEXT_LENGTH)
    if len(text) > max_length:
        raise FieldValidationError(f"طول متن نباید بیشتر از {max_length} نویسه باشد.")
    if len(text) < int(rules.get("min_length", 0)):
        raise FieldValidationError(f"طول متن باید دست‌کم {rules['min_length']} نویسه باشد.")
    pattern = rules.get("pattern")
    if pattern and re.fullmatch(pattern, text) is None:
        raise FieldValidationError("مقدار با الگوی تعریف‌شده برای این فیلد مطابقت ندارد.")
    return text


def _validate_number(value: Any, rules: Mapping[str, Any]) -> int:
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int):
        raise FieldValidationError("مقدار باید عدد صحیح باشد.")
    if abs(value) > MAX_SAFE_INTEGER:
        raise FieldValidationError("عدد واردشده بیش از حد بزرگ است.")
    if "min" in rules and value < rules["min"]:
        raise FieldValidationError(f"مقدار باید دست‌کم {rules['min']} باشد.")
    if "max" in rules and value > rules["max"]:
        raise FieldValidationError(f"مقدار نباید بیشتر از {rules['max']} باشد.")
    return value


def _validate_decimal(value: Any, rules: Mapping[str, Any]) -> str:
    number = _as_decimal(value)
    places = int(rules.get("max_decimal_places", DEFAULT_MAX_DECIMAL_PLACES))
    normalized = number.normalize()
    normalized_exponent = normalized.as_tuple().exponent
    actual_places = max(-normalized_exponent, 0) if isinstance(normalized_exponent, int) else 0
    if actual_places > places:
        raise FieldValidationError(f"تعداد رقم‌های اعشار نباید بیشتر از {places} باشد.")
    if "min" in rules and number < Decimal(str(rules["min"])):
        raise FieldValidationError(f"مقدار باید دست‌کم {rules['min']} باشد.")
    if "max" in rules and number > Decimal(str(rules["max"])):
        raise FieldValidationError(f"مقدار نباید بیشتر از {rules['max']} باشد.")
    return _format_decimal(number)


def _validate_date(value: Any, rules: Mapping[str, Any]) -> str:
    parsed = _as_date(value)
    if "min" in rules and parsed < date.fromisoformat(rules["min"]):
        raise FieldValidationError(f"تاریخ نباید قبل از {rules['min']} باشد.")
    if "max" in rules and parsed > date.fromisoformat(rules["max"]):
        raise FieldValidationError(f"تاریخ نباید بعد از {rules['max']} باشد.")
    return parsed.isoformat()


def _validate_datetime(value: Any, rules: Mapping[str, Any]) -> str:
    parsed = _as_datetime(value)
    if "min" in rules and parsed < _as_datetime(rules["min"]):
        raise FieldValidationError(f"زمان نباید قبل از {rules['min']} باشد.")
    if "max" in rules and parsed > _as_datetime(rules["max"]):
        raise FieldValidationError(f"زمان نباید بعد از {rules['max']} باشد.")
    return _format_datetime(parsed)


def _validate_boolean(value: Any) -> bool:
    if not isinstance(value, bool):
        raise FieldValidationError("مقدار باید درست یا نادرست (true/false) باشد.")
    return value


def _option_values(options: Sequence[Mapping[str, Any]] | None) -> set[str]:
    return {str(option["value"]) for option in options or []}


def _validate_select(value: Any, options: Sequence[Mapping[str, Any]] | None) -> str:
    if not isinstance(value, str) or value not in _option_values(options):
        raise FieldValidationError("مقدار انتخاب‌شده جزو گزینه‌های مجاز این فیلد نیست.")
    return value


def _validate_multi_select(
    value: Any, options: Sequence[Mapping[str, Any]] | None, rules: Mapping[str, Any]
) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise FieldValidationError("مقدار باید فهرستی از گزینه‌ها باشد.")
    if len(set(value)) != len(value):
        raise FieldValidationError("گزینهٔ تکراری مجاز نیست.")
    allowed = _option_values(options)
    if any(item not in allowed for item in value):
        raise FieldValidationError("دست‌کم یکی از مقادیر انتخاب‌شده جزو گزینه‌های مجاز این فیلد نیست.")
    if "min_items" in rules and len(value) < rules["min_items"]:
        raise FieldValidationError(f"دست‌کم {rules['min_items']} گزینه باید انتخاب شود.")
    if "max_items" in rules and len(value) > rules["max_items"]:
        raise FieldValidationError(f"حداکثر {rules['max_items']} گزینه قابل انتخاب است.")
    return list(value)


_VALUE_VALIDATORS: dict[ProductFieldType, Callable[[FieldDefinitionLike, Any, Mapping[str, Any]], Any]] = {
    ProductFieldType.TEXT: lambda _definition, value, rules: _validate_text(value, rules),
    ProductFieldType.NUMBER: lambda _definition, value, rules: _validate_number(value, rules),
    ProductFieldType.DECIMAL: lambda _definition, value, rules: _validate_decimal(value, rules),
    ProductFieldType.DATE: lambda _definition, value, rules: _validate_date(value, rules),
    ProductFieldType.DATETIME: lambda _definition, value, rules: _validate_datetime(value, rules),
    ProductFieldType.BOOLEAN: lambda _definition, value, _rules: _validate_boolean(value),
    ProductFieldType.SELECT: lambda definition, value, _rules: _validate_select(value, definition.options),
    ProductFieldType.MULTI_SELECT: lambda definition, value, rules: _validate_multi_select(
        value, definition.options, rules
    ),
}


def validate_value(definition: FieldDefinitionLike, value: Any) -> Any:
    """Validate ``value`` against ``definition`` and return its canonical JSON form.

    Raises :class:`FieldValidationError` when the value is not acceptable.
    Callers handle "empty" values (see :func:`is_empty_value`) before calling this.
    """
    validator = _VALUE_VALIDATORS[definition.data_type]
    return validator(definition, value, definition.validation_rules or {})


def display_value(definition: FieldDefinitionLike, value: Any) -> Any:
    """Human-readable form of a stored value (option labels instead of option values)."""
    labels = {str(option["value"]): str(option["label"]) for option in definition.options or []}
    if definition.data_type is ProductFieldType.SELECT and isinstance(value, str):
        return labels.get(value, value)
    if definition.data_type is ProductFieldType.MULTI_SELECT and isinstance(value, list):
        return [labels.get(str(item), str(item)) for item in value]
    return value
