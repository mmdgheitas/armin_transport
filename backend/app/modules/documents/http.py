"""HTTP response builder for document downloads (staff and customer portal)."""

from __future__ import annotations

from flask import Response, send_file

from app.models import Document
from app.modules.documents.service import DocumentContent
from app.modules.documents.validation import UploadRejectedError, sanitize_filename


def _download_name(document: Document) -> str:
    """Re-sanitize the stored display name at the output boundary (defence in depth).

    Names are sanitized when a file is uploaded; doing it again here guarantees that
    a row written by any other means can never inject response headers.
    """
    try:
        return sanitize_filename(document.original_name)
    except UploadRejectedError:
        return f"document.{document.extension}"


def download_response(content: DocumentContent) -> Response:
    """Stream a document as an attachment with headers that prevent in-browser execution."""
    document = content.document
    response = send_file(
        content.stream,
        mimetype=document.mime_type,
        as_attachment=True,
        download_name=_download_name(document),
        conditional=False,
        max_age=None,
    )
    response.content_length = content.size
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
    response.headers["X-Download-Options"] = "noopen"
    return response
