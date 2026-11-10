"""Declarative endpoint wrapper.

``@endpoint(...)`` applies, in order: authentication, permission checks, query and
body validation, response serialization into the common envelope. It also
attaches an :class:`EndpointSpec` used to generate the OpenAPI document, so the
documentation is derived from the same declarations that are enforced at runtime.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from functools import wraps
from typing import TYPE_CHECKING, Any, Literal

from flask import current_app, g, request
from marshmallow import Schema
from werkzeug.wrappers import Response as WerkzeugResponse

from app.core.actor import Actor
from app.core.errors import AuthenticationError, BadRequestError, UnsupportedMediaTypeError
from app.core.pagination import Page
from app.core.permissions import Permission
from app.core.responses import DEFAULT_SUCCESS_MESSAGE, success_response

if TYPE_CHECKING:
    from app.container import Services

AuthMode = Literal["bearer", "public", "customer_token"]
ENDPOINT_SPEC_ATTRIBUTE = "__endpoint_spec__"
MAX_JSON_BODY_BYTES = 1024 * 1024


@dataclass(frozen=True)
class EndpointSpec:
    """Metadata describing one API operation."""

    summary: str
    tag: str
    description: str | None = None
    auth: AuthMode = "bearer"
    permissions: tuple[Permission, ...] = ()
    query: type[Schema] | None = None
    body: type[Schema] | None = None
    form: type[Schema] | None = None
    files_field: str | None = None
    response: type[Schema] | None = None
    many: bool = False
    paginated: bool = False
    status: int = 200
    binary: bool = False
    # Error statuses beyond the ones implied by the other declarations (documentation only).
    errors: tuple[int, ...] = ()


@dataclass
class ApiResult:
    """Return value of a view: payload plus optional message, status and headers."""

    data: Any = None
    message: str = DEFAULT_SUCCESS_MESSAGE
    status: int | None = None
    headers: Mapping[str, str] = field(default_factory=dict)


def get_services() -> Services:
    services: Services = current_app.extensions["services"]
    return services


def current_actor() -> Actor:
    actor: Actor | None = g.get("actor")
    if actor is None:
        raise AuthenticationError()
    return actor


def client_ip() -> str | None:
    return request.remote_addr


def _bearer_token() -> str:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthenticationError()
    return token.strip()


def _json_body() -> dict[str, Any]:
    if not request.is_json:
        raise UnsupportedMediaTypeError("بدنهٔ درخواست باید با قالب JSON (application/json) ارسال شود.")
    # JSON bodies are small; only the multipart upload endpoint may use the large global limit.
    request.max_content_length = MAX_JSON_BODY_BYTES
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        raise BadRequestError("بدنهٔ درخواست باید یک شیء JSON معتبر باشد.", code="invalid_json")
    return payload


def _serialize(spec: EndpointSpec, data: Any) -> Any:
    if spec.response is None or data is None:
        return data
    if spec.paginated:
        if not isinstance(data, Page):
            raise TypeError("Paginated endpoints must return a Page instance.")
        return {"items": spec.response(many=True).dump(data.items), "pagination": data.meta()}
    return spec.response(many=spec.many).dump(data)


def endpoint(
    *,
    summary: str,
    tag: str,
    description: str | None = None,
    auth: AuthMode = "bearer",
    permissions: tuple[Permission, ...] = (),
    query: type[Schema] | None = None,
    body: type[Schema] | None = None,
    form: type[Schema] | None = None,
    files_field: str | None = None,
    response: type[Schema] | None = None,
    many: bool = False,
    paginated: bool = False,
    status: int = 200,
    binary: bool = False,
    errors: tuple[int, ...] = (),
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Wrap a view function with the standard request/response pipeline.

    The view receives, as keyword arguments, the URL parameters plus ``actor``
    (for ``auth="bearer"``) and ``query``, ``body``, ``form`` and ``files`` when the
    respective declaration is present. It returns an :class:`ApiResult`, a bare
    payload, or a ready response object (binary downloads).
    """
    spec = EndpointSpec(
        summary=summary,
        tag=tag,
        description=description,
        auth=auth,
        permissions=permissions,
        query=query,
        body=body,
        form=form,
        files_field=files_field,
        response=response,
        many=many,
        paginated=paginated,
        status=status,
        binary=binary,
        errors=errors,
    )

    def decorator(view: Callable[..., Any]) -> Callable[..., Any]:
        @wraps(view)
        def wrapper(**url_params: Any) -> Any:
            kwargs: dict[str, Any] = dict(url_params)
            if spec.auth == "bearer":
                actor = get_services().auth.authenticate(_bearer_token())
                g.actor = actor
                actor.require(*spec.permissions)
                kwargs["actor"] = actor
            if spec.query is not None:
                kwargs["query"] = spec.query().load(request.args.to_dict(flat=True))
            if spec.body is not None:
                kwargs["body"] = spec.body().load(_json_body())
            if spec.form is not None:
                kwargs["form"] = spec.form().load(request.form.to_dict(flat=True))
            if spec.files_field is not None:
                kwargs["files"] = request.files.getlist(spec.files_field)

            result = view(**kwargs)
            if isinstance(result, WerkzeugResponse):
                return result
            if not isinstance(result, ApiResult):
                result = ApiResult(data=result)
            return success_response(
                _serialize(spec, result.data),
                message=result.message,
                status=result.status or spec.status,
                headers=result.headers,
            )

        setattr(wrapper, ENDPOINT_SPEC_ATTRIBUTE, spec)
        return wrapper

    return decorator
