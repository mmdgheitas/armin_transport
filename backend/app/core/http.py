"""Request lifecycle hooks: correlation ids, access logging and security headers."""

from __future__ import annotations

import logging
import re
import time
import uuid

from flask import Flask, Response, g, request

from app.config import Settings

logger = logging.getLogger("app.access")

_REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{8,64}$")
_CUSTOMER_TOKEN_PATH = re.compile(r"(/customer/access/)[^/]+")
API_PREFIX = "/api/"


def mask_sensitive_path(path: str) -> str:
    """Remove raw customer access tokens from a URL path before it is logged or stored."""
    return _CUSTOMER_TOKEN_PATH.sub(r"\1[redacted]", path)


def _api_headers(response: Response) -> None:
    response.headers.setdefault("Cache-Control", "no-store")
    response.headers.setdefault("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
    response.headers.setdefault("X-Frame-Options", "DENY")


def _web_headers(response: Response, settings: Settings) -> None:
    connect_sources = " ".join(("'self'", *settings.cors_allowed_origins))
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; "
        f"font-src 'self'; connect-src {connect_sources}; object-src 'none'; base-uri 'self'; "
        f"form-action 'self'; frame-ancestors {settings.frame_ancestors}",
    )
    if settings.frame_ancestors == "'none'":
        response.headers.setdefault("X-Frame-Options", "DENY")
    elif settings.frame_ancestors == "'self'":
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")


def register_request_hooks(app: Flask, settings: Settings) -> None:
    @app.before_request
    def start_request() -> None:
        inbound = request.headers.get("X-Request-ID", "")
        g.request_id = inbound if _REQUEST_ID_PATTERN.match(inbound) else uuid.uuid4().hex
        g.request_started = time.perf_counter()

    @app.after_request
    def finish_request(response: Response) -> Response:
        response.headers["X-Request-ID"] = g.get("request_id", "")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Permissions-Policy", "camera=(), geolocation=(), microphone=()")
        if request.path.startswith(API_PREFIX):
            _api_headers(response)
        else:
            _web_headers(response, settings)
        if settings.hsts_enabled and request.is_secure:
            response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")

        actor = g.get("actor")
        started = g.get("request_started")
        logger.info(
            "%s %s -> %s",
            request.method,
            mask_sensitive_path(request.path),
            response.status_code,
            extra={
                "method": request.method,
                "path": mask_sensitive_path(request.path),
                "status": response.status_code,
                "duration_ms": round((time.perf_counter() - started) * 1000, 2) if started else None,
                "client_ip": request.remote_addr,
                "user_id": str(actor.user_id) if actor else None,
            },
        )
        return response
