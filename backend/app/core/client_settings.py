"""Non-sensitive policy values exposed to authenticated clients.

Web and Flutter read these instead of hard-coding business rules, so the backend
stays the single source of truth (limits are still enforced server-side).
"""

from __future__ import annotations

from typing import Any

from app.config import Settings

TRACKING_CODE_MAX_LENGTH = 64
TRACKING_CODE_PATTERN = r"^[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$"


def client_settings(settings: Settings) -> dict[str, Any]:
    return {
        "upload": {
            "max_file_size_bytes": settings.max_upload_size_bytes,
            "max_files_per_upload": settings.max_files_per_upload,
            "allowed_extensions": [],
            "customer_visible_default": settings.document_customer_visible_default,
        },
        "tracking_code": {
            "min_length": settings.tracking_code_min_length,
            "max_length": TRACKING_CODE_MAX_LENGTH,
            "pattern": TRACKING_CODE_PATTERN,
        },
        "password": {"min_length": settings.password_min_length},
        "pagination": {
            "default_page_size": settings.default_page_size,
            "max_page_size": settings.max_page_size,
        },
    }
