"""Unit tests for tracking code normalization, validation and generation."""

from __future__ import annotations

import dataclasses
import itertools
import re

import pytest

from app.config import Settings
from app.modules.shipments.tracking_codes import (
    AUTO_CODE_ALPHABET,
    InvalidTrackingCodeError,
    TrackingCodeGenerator,
    normalize_tracking_code,
    validate_tracking_code,
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("abc-123", "ABC-123"),
        ("  AbC 12 3\t", "ABC123"),
        ("ab\u00a0cd\u200c12", "ABCD12"),  # no-break space and zero-width non-joiner
        ("۱۲۳۴۵۶", "123456"),  # Persian digits
        ("٠١٢٣٤٥", "012345"),  # Arabic-Indic digits
        ("ＡＢＣ１２３", "ABC123"),  # full-width forms (NFKC)
        ("AB–12—34", "AB-12-34"),  # en dash / em dash
        ("ab\ncd\r\n12", "ABCD12"),
    ],
)
def test_normalization(raw: str, expected: str) -> None:
    assert normalize_tracking_code(raw) == expected


def test_normalization_is_idempotent() -> None:
    once = normalize_tracking_code(" ab-۱۲ cd ")
    assert normalize_tracking_code(once) == once


@pytest.mark.parametrize("code", ["ABC123", "A1B2C3D4", "ABCD-1234-EFGH", "X" * 64, "000000"])
def test_valid_codes(code: str) -> None:
    assert validate_tracking_code(code, min_length=6) == code


@pytest.mark.parametrize(
    "code",
    [
        "",
        "ABC12",  # too short
        "X" * 65,  # too long
        "-ABC123",
        "ABC123-",
        "ABC_123",
        "ABC/123",
        "ABC.123",
        "ABC 123",
        "abc123",  # must already be normalized
        "ABC123؛",
        "محموله۱۲۳",
        "ABC123'; DROP TABLE shipments;--",
        "../../etc/passwd",
        "<script>1</script>",
    ],
)
def test_invalid_codes(code: str) -> None:
    with pytest.raises(InvalidTrackingCodeError):
        validate_tracking_code(code, min_length=6)


def test_generated_codes_use_the_unambiguous_alphabet(settings: Settings) -> None:
    generator = TrackingCodeGenerator(settings)
    assert not set("ILOU") & set(AUTO_CODE_ALPHABET)
    assert len(AUTO_CODE_ALPHABET) == 32
    for _ in range(200):
        code = generator.generate()
        assert re.fullmatch(r"[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}", code), code
        assert validate_tracking_code(normalize_tracking_code(code), settings.tracking_code_min_length) == code


def test_generated_codes_are_not_uuids_or_sequential(settings: Settings) -> None:
    generator = TrackingCodeGenerator(settings)
    codes = [generator.generate() for _ in range(2000)]
    assert len(set(codes)) == len(codes)
    assert not any(re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-.*", code) for code in codes)
    # Consecutive codes must not share a predictable prefix (as counters or timestamps would).
    shared_prefixes = sum(1 for first, second in itertools.pairwise(codes) if first[:6] == second[:6])
    assert shared_prefixes == 0
    # Every alphabet symbol shows up: no obviously biased source.
    assert set("".join(codes).replace("-", "")) == set(AUTO_CODE_ALPHABET)


def test_generator_honours_length_grouping_and_prefix(settings: Settings) -> None:
    custom = dataclasses.replace(
        settings, tracking_code_auto_length=20, tracking_code_auto_group_size=5, tracking_code_auto_prefix="ARM"
    )
    generator = TrackingCodeGenerator(custom)
    code = generator.generate()
    assert re.fullmatch(r"ARM(-[0-9A-Z]{5}){4}", code)
    assert len(code) == generator.max_generated_length()

    ungrouped = dataclasses.replace(settings, tracking_code_auto_length=12, tracking_code_auto_group_size=0)
    assert re.fullmatch(r"[0-9A-Z]{12}", TrackingCodeGenerator(ungrouped).generate())
