"""The uniform JSON response envelope used by every API endpoint."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from flask import Response, g, jsonify

DEFAULT_SUCCESS_MESSAGE = "عملیات با موفقیت انجام شد."


def success_response(
    data: Any = None,
    message: str = DEFAULT_SUCCESS_MESSAGE,
    status: int = 200,
    headers: Mapping[str, str] | None = None,
) -> Response:
    response = jsonify({"success": True, "message": message, "data": data, "errors": None})
    response.status_code = status
    for name, value in (headers or {}).items():
        response.headers[name] = value
    return response


def error_response(
    message: str,
    status: int,
    code: str,
    details: Mapping[str, Any] | None = None,
    headers: Mapping[str, str] | None = None,
) -> Response:
    errors: dict[str, Any] = {"code": code}
    errors.update(details or {})
    request_id = g.get("request_id")
    if request_id:
        errors["request_id"] = request_id
    response = jsonify({"success": False, "message": message, "data": None, "errors": errors})
    response.status_code = status
    for name, value in (headers or {}).items():
        response.headers[name] = value
    return response
