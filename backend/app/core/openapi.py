"""OpenAPI 3 document generated from the ``@endpoint`` declarations.

Because the document is derived from the same schemas and permission lists that
are enforced at runtime, it cannot drift from the actual behaviour of the API.
"""

from __future__ import annotations

import re
from typing import Any

from apispec import APISpec
from apispec.ext.marshmallow import MarshmallowPlugin
from flask import Flask
from marshmallow import Schema
from werkzeug.routing import Rule

from app.config import Settings
from app.core.api import ENDPOINT_SPEC_ATTRIBUTE, EndpointSpec
from app.core.schemas import PaginationMetaSchema

_PATH_PARAMETER = re.compile(r"<(?:(?P<converter>[^:<>]+):)?(?P<name>[^<>]+)>")
_ERROR_SCHEMA_NAME = "ErrorResponse"
_BEARER_SCHEME = "bearerAuth"

_TAGS = [
    {"name": "auth", "description": "احراز هویت و مدیریت نشست"},
    {"name": "dashboard", "description": "خلاصهٔ داشبورد"},
    {"name": "companies", "description": "مدیریت شرکت‌ها (مدیر مرکزی)"},
    {"name": "users", "description": "مدیریت کارمندان (مدیر مرکزی)"},
    {"name": "shipments", "description": "محموله‌ها و کدهای رهگیری"},
    {"name": "documents", "description": "سندهای محموله"},
    {"name": "product-fields", "description": "فیلدهای پویای کالا"},
    {"name": "customer", "description": "درگاه مشتری (دسترسی با کد رهگیری)"},
    {"name": "audit-logs", "description": "گزارش ممیزی (مدیر مرکزی)"},
    {"name": "health", "description": "سلامت سرویس"},
]

_ERROR_DESCRIPTIONS = {
    400: "درخواست نامعتبر",
    401: "احراز هویت لازم است یا توکن نامعتبر/منقضی است",
    403: "مجوز کافی وجود ندارد",
    404: "یافت نشد (یا خارج از محدودهٔ دسترسی)",
    409: "تعارض با وضعیت فعلی داده‌ها",
    413: "حجم درخواست یا فایل بیش از حد مجاز است",
    415: "قالب بدنهٔ درخواست پشتیبانی نمی‌شود",
    422: "خطای اعتبارسنجی",
    429: "تعداد درخواست بیش از حد مجاز",
    503: "سرویس موقتاً در دسترس نیست",
}


def _schema_name(schema: type[Schema] | Schema) -> str:
    cls = schema if isinstance(schema, type) else type(schema)
    name = cls.__name__
    return name[: -len("Schema")] if name.endswith("Schema") else name


def _envelope(data_schema: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "type": "object",
        "required": ["success", "message", "data", "errors"],
        "properties": {
            "success": {"type": "boolean", "enum": [True]},
            "message": {"type": "string"},
            "data": data_schema if data_schema is not None else {"nullable": True},
            "errors": {"nullable": True},
        },
    }


def _error_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "required": ["success", "message", "data", "errors"],
        "properties": {
            "success": {"type": "boolean", "enum": [False]},
            "message": {"type": "string", "description": "پیام قابل نمایش به کاربر"},
            "data": {"nullable": True},
            "errors": {
                "type": "object",
                "required": ["code"],
                "properties": {
                    "code": {"type": "string", "description": "کد پایدار خطا برای استفادهٔ برنامه‌ها"},
                    "request_id": {"type": "string"},
                    "fields": {
                        "type": "object",
                        "description": "خطاهای اعتبارسنجی به تفکیک فیلد",
                        "additionalProperties": {"type": "array", "items": {"type": "string"}},
                    },
                    "required_permissions": {"type": "array", "items": {"type": "string"}},
                    "retry_after_seconds": {"type": "integer"},
                },
                "additionalProperties": True,
            },
        },
    }


class _Builder:
    def __init__(self, app: Flask) -> None:
        settings: Settings = app.extensions["settings"]
        self._app = app
        self._plugin = MarshmallowPlugin(schema_name_resolver=_schema_name)
        self._spec = APISpec(
            title="Armin Transport API",
            version=settings.app_version,
            openapi_version="3.0.3",
            plugins=[self._plugin],
            info={
                "description": (
                    "REST API سامانهٔ مدیریت محموله و اسناد حمل‌ونقل. همهٔ پاسخ‌های JSON در قالب یکسان "
                    "`{success, message, data, errors}` هستند. زمان‌ها به UTC و با قالب ISO 8601 هستند."
                )
            },
            servers=[{"url": "/", "description": "همین سرور"}],
            tags=_TAGS,
        )
        self._spec.components.security_scheme(
            _BEARER_SCHEME, {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
        )
        self._spec.components.schema(_ERROR_SCHEMA_NAME, _error_schema())

    def _ref(self, schema: type[Schema], *, many: bool = False) -> dict[str, Any]:
        assert self._plugin.resolver is not None  # noqa: S101 - set by APISpec
        resolved: dict[str, Any] = self._plugin.resolver.resolve_schema_dict(schema(many=many))  # type: ignore[no-untyped-call]
        return resolved

    def _data_schema(self, spec: EndpointSpec) -> dict[str, Any] | None:
        if spec.response is None:
            return None
        if spec.paginated:
            return {
                "type": "object",
                "required": ["items", "pagination"],
                "properties": {
                    "items": self._ref(spec.response, many=True),
                    "pagination": self._ref(PaginationMetaSchema),
                },
            }
        return self._ref(spec.response, many=spec.many)

    def _error(self, status: int) -> dict[str, Any]:
        return {
            "description": _ERROR_DESCRIPTIONS[status],
            "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{_ERROR_SCHEMA_NAME}"}}},
        }

    def _path_parameters(self, rule: Rule) -> list[dict[str, Any]]:
        parameters = []
        for match in _PATH_PARAMETER.finditer(rule.rule):
            schema: dict[str, Any] = {"type": "string"}
            if match.group("converter") == "uuid":
                schema["format"] = "uuid"
            parameters.append({"name": match.group("name"), "in": "path", "required": True, "schema": schema})
        return parameters

    def _request_body(self, spec: EndpointSpec) -> dict[str, Any] | None:
        if spec.body is not None:
            return {"required": True, "content": {"application/json": {"schema": self._ref(spec.body)}}}
        if spec.files_field is None:
            return None
        assert self._plugin.converter is not None  # noqa: S101 - set by APISpec
        properties: dict[str, Any] = {
            spec.files_field: {
                "type": "array",
                "items": {"type": "string", "format": "binary"},
                "description": "یک یا چند فایل",
            }
        }
        if spec.form is not None:
            form_schema = self._plugin.converter.schema2jsonschema(spec.form())  # type: ignore[no-untyped-call]
            properties.update(form_schema.get("properties", {}))
        return {
            "required": True,
            "content": {
                "multipart/form-data": {
                    "schema": {"type": "object", "required": [spec.files_field], "properties": properties}
                }
            },
        }

    @staticmethod
    def _error_statuses(spec: EndpointSpec, method: str, *, has_path_parameters: bool) -> list[int]:
        statuses: set[int] = {401, 403} if spec.auth in {"bearer", "customer_token"} else {429}
        if spec.auth == "customer_token":
            statuses.add(401)
        statuses.update(spec.errors)
        if has_path_parameters:
            statuses.add(404)
        if spec.body is not None:
            statuses.update({400, 415, 422})
        if spec.query is not None or spec.form is not None:
            statuses.add(422)
        if spec.files_field is not None:
            statuses.update({413, 422})
        if method in {"post", "patch", "put", "delete"} and spec.auth == "bearer":
            statuses.add(409)
        return sorted(statuses)

    def _operation(self, spec: EndpointSpec, rule: Rule, method: str) -> dict[str, Any]:
        assert self._plugin.converter is not None  # noqa: S101 - set by APISpec
        parameters = self._path_parameters(rule)
        if spec.query is not None:
            parameters.extend(self._plugin.converter.schema2parameters(spec.query(), location="query"))

        description_parts = [spec.description] if spec.description else []
        if spec.permissions:
            description_parts.append("مجوزهای لازم: " + "، ".join(f"`{p.value}`" for p in spec.permissions))

        if spec.binary:
            success: dict[str, Any] = {
                "description": "محتوای فایل به‌صورت پیوست (Content-Type برابر نوع واقعی فایل است)",
                "content": {"*/*": {"schema": {"type": "string", "format": "binary"}}},
            }
        else:
            success = {
                "description": "موفق",
                "content": {"application/json": {"schema": _envelope(self._data_schema(spec))}},
            }
        responses: dict[str, Any] = {str(spec.status): success}

        for status in self._error_statuses(spec, method, has_path_parameters=bool(self._path_parameters(rule))):
            responses[str(status)] = self._error(status)

        operation: dict[str, Any] = {
            "operationId": rule.endpoint.replace(".", "_"),
            "summary": spec.summary,
            "tags": [spec.tag],
            "responses": responses,
        }
        if description_parts:
            operation["description"] = "\n\n".join(description_parts)
        if parameters:
            operation["parameters"] = parameters
        request_body = self._request_body(spec)
        if request_body is not None:
            operation["requestBody"] = request_body
        operation["security"] = [{_BEARER_SCHEME: []}] if spec.auth in {"bearer", "customer_token"} else []
        return operation

    def build(self) -> dict[str, Any]:
        rules = sorted(self._app.url_map.iter_rules(), key=lambda rule: (rule.rule, rule.endpoint))
        for rule in rules:
            view = self._app.view_functions.get(rule.endpoint)
            spec: EndpointSpec | None = getattr(view, ENDPOINT_SPEC_ATTRIBUTE, None)
            if spec is None:
                continue
            methods = sorted((rule.methods or set()) - {"HEAD", "OPTIONS"})
            operations = {method.lower(): self._operation(spec, rule, method.lower()) for method in methods}
            self._spec.path(path=_PATH_PARAMETER.sub(r"{\g<name>}", rule.rule), operations=operations)
        document: dict[str, Any] = self._spec.to_dict()
        return document


def build_openapi_document(app: Flask) -> dict[str, Any]:
    """Build the OpenAPI document for every documented route of ``app``."""
    return _Builder(app).build()
