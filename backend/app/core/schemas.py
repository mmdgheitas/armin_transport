"""Base marshmallow schemas for request validation and response serialization."""

from __future__ import annotations

from typing import Any

from flask import current_app
from marshmallow import EXCLUDE, RAISE, Schema, ValidationError, post_load

from app.config import Settings
from app.core import fields
from app.core.text import fa_number


class InputSchema(Schema):
    """Strict request-body schema: unknown fields are rejected."""

    class Meta:
        unknown = RAISE

    error_messages = {
        "unknown": "این فیلد شناخته‌شده نیست.",
        "type": "نوع دادهٔ ورودی نامعتبر است.",
    }


class QuerySchema(InputSchema):
    """Query-string schema: unknown parameters are ignored."""

    class Meta:
        unknown = EXCLUDE


class PaginationQuerySchema(QuerySchema):
    """``page`` / ``per_page`` parameters shared by every collection endpoint."""

    page = fields.Integer(load_default=1, validate=fields.number_range(min=1, max=1_000_000))
    per_page = fields.Integer(load_default=None, allow_none=True, validate=fields.number_range(min=1))

    @post_load
    def _apply_page_size_policy(self, data: dict[str, Any], **_: Any) -> dict[str, Any]:
        settings: Settings = current_app.extensions["settings"]
        if data.get("per_page") is None:
            data["per_page"] = settings.default_page_size
        elif data["per_page"] > settings.max_page_size:
            raise ValidationError({"per_page": [f"مقدار نباید بیشتر از {fa_number(settings.max_page_size)} باشد."]})
        return data


class OutputSchema(Schema):
    """Base class for response serialization schemas."""


class PaginationMetaSchema(OutputSchema):
    page = fields.Integer()
    per_page = fields.Integer()
    total = fields.Integer()
    total_pages = fields.Integer()
    has_next = fields.Boolean()
    has_prev = fields.Boolean()


def flatten_errors(messages: Any, prefix: str = "") -> dict[str, list[str]]:
    """Flatten marshmallow's nested error structure into ``{"path.to.field": [messages]}``."""
    flat: dict[str, list[str]] = {}
    if isinstance(messages, dict):
        for key, value in messages.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            for nested_path, nested_messages in flatten_errors(value, path).items():
                flat.setdefault(nested_path, []).extend(nested_messages)
    elif isinstance(messages, list | tuple):
        flat.setdefault(prefix or "_schema", []).extend(str(item) for item in messages)
    else:
        flat.setdefault(prefix or "_schema", []).append(str(messages))
    return flat
