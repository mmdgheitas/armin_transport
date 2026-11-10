"""WSGI entry point (``gunicorn wsgi:app``) and Flask CLI application (``FLASK_APP=wsgi:app``)."""

from __future__ import annotations

from dotenv import load_dotenv

from app import create_app
from app.config import BACKEND_ROOT

# Optional local configuration file; real environment variables always take precedence.
load_dotenv(BACKEND_ROOT / ".env")

app = create_app()
