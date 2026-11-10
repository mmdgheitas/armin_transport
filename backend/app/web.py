"""Optional static hosting of the built web client (``SERVE_WEB_APP=true``).

In production the web client is normally served by the reverse proxy; this
blueprint exists for single-process deployments, local development and demos.
"""

from __future__ import annotations

from pathlib import Path

from flask import Blueprint, Response, send_from_directory
from werkzeug.exceptions import NotFound

INDEX_FILE = "index.html"


def create_web_blueprint(web_root: Path) -> Blueprint:
    bp = Blueprint("web", __name__)

    def _serve(filename: str) -> Response:
        response = send_from_directory(web_root, filename, conditional=True, max_age=0)
        response.headers["Cache-Control"] = "no-cache"
        return response

    @bp.get("/")
    def index() -> Response:
        return _serve(INDEX_FILE)

    @bp.get("/<path:filename>")
    def asset(filename: str) -> Response:
        if filename.startswith("api/"):
            raise NotFound()
        return _serve(filename)

    return bp
