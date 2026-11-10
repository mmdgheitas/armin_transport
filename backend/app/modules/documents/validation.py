"""Upload validation: file name, extension, declared MIME type and content signature.

A file is accepted only when *all* of these agree:

1. the sanitized name ends in an allowed extension and contains no blocked one;
2. the Content-Type declared by the client is consistent with that extension;
3. the leading bytes / container structure match the format of that extension.

The MIME type stored and later served is the server's canonical type for the
validated extension, never the value claimed by the client.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import IO

MAX_FILENAME_LENGTH = 255
CHUNK_SIZE = 1024 * 1024

# Never accepted, even as an inner extension ("invoice.exe.pdf").
BLOCKED_EXTENSIONS = frozenset({"exe", "dll", "bat", "cmd", "ps1", "sh", "js", "vbs", "jar", "scr", "com"})
GENERIC_MIME_TYPES = frozenset({"", "application/octet-stream", "binary/octet-stream"})

_OLE2_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
_ZIP_MAGIC = b"PK\x03\x04"
_MAX_ZIP_ENTRIES = 10_000
_RESERVED_CHARACTERS = re.compile(r'[<>:"/\\|?*]')
_ALLOWED_TEXT_CONTROLS = frozenset(b"\t\n\x0c\r")
_BINARY_CONTROL_BYTES = bytes(sorted((set(range(0x20)) - _ALLOWED_TEXT_CONTROLS) | {0x7F}))
_UTF16_BOMS = (b"\xff\xfe", b"\xfe\xff")
_KEPT_FORMAT_CHARACTERS = frozenset("\u200c\u200d")


class UploadRejectedError(ValueError):
    """The uploaded file violates the upload policy."""

    def __init__(self, code: str, message: str, *, status_code: int = 422) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code


# --------------------------------------------------------------------------- content signatures
def _read_head(path: Path, size: int) -> bytes:
    with path.open("rb") as handle:
        return handle.read(size)


def _is_pdf(path: Path) -> bool:
    return _read_head(path, 5) == b"%PDF-"


def _is_jpeg(path: Path) -> bool:
    return _read_head(path, 3) == b"\xff\xd8\xff"


def _is_png(path: Path) -> bool:
    return _read_head(path, 8) == b"\x89PNG\r\n\x1a\n"


def _is_webp(path: Path) -> bool:
    head = _read_head(path, 12)
    return head[:4] == b"RIFF" and head[8:12] == b"WEBP"


def _contains_any(path: Path, needles: tuple[bytes, ...]) -> bool:
    """Chunked substring search (keeps an overlap so matches across chunks are found)."""
    overlap = max(len(needle) for needle in needles) - 1
    tail = b""
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_SIZE):
            window = tail + chunk
            if any(needle in window for needle in needles):
                return True
            tail = window[-overlap:]
    return False


def _ole2_checker(*stream_names: str) -> Callable[[Path], bool]:
    """OLE2 compound file that contains one of the given directory entry names."""
    needles = tuple(name.encode("utf-16-le") for name in stream_names)

    def check(path: Path) -> bool:
        return _read_head(path, 8) == _OLE2_MAGIC and _contains_any(path, needles)

    return check


def _ooxml_checker(main_part: str) -> Callable[[Path], bool]:
    """ZIP container with the OOXML content-types part, the main part and no VBA macros."""

    def check(path: Path) -> bool:
        if _read_head(path, 4) != _ZIP_MAGIC:
            return False
        try:
            with zipfile.ZipFile(path) as archive:
                names = archive.namelist()
        except (zipfile.BadZipFile, OSError, ValueError, NotImplementedError, RuntimeError):
            return False
        if len(names) > _MAX_ZIP_ENTRIES:
            return False
        if any(name.lower().endswith("vbaproject.bin") for name in names):
            return False
        return "[Content_Types].xml" in names and main_part in names

    return check


def _is_text(path: Path) -> bool:
    """Plain text: no binary control bytes (UTF-16 is accepted only with a BOM)."""
    if _read_head(path, 2) in _UTF16_BOMS:
        try:
            text = path.read_bytes().decode("utf-16")
        except UnicodeDecodeError:
            return False
        return not any(ord(char) < 0x20 and char not in "\t\n\x0c\r" for char in text)
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_SIZE):
            if chunk.translate(None, delete=_BINARY_CONTROL_BYTES) != chunk:
                return False
    return True


@dataclass(frozen=True)
class FileType:
    extension: str
    mime_type: str
    accepted_declared_types: frozenset[str]
    matches_content: Callable[[Path], bool]


def _file_type(extension: str, mime_type: str, check: Callable[[Path], bool], *aliases: str) -> FileType:
    return FileType(extension, mime_type, frozenset({mime_type, *aliases}), check)


_DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
_XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

SUPPORTED_FILE_TYPES: dict[str, FileType] = {
    file_type.extension: file_type
    for file_type in (
        _file_type("pdf", "application/pdf", _is_pdf, "application/x-pdf"),
        _file_type("jpg", "image/jpeg", _is_jpeg, "image/jpg", "image/pjpeg"),
        _file_type("jpeg", "image/jpeg", _is_jpeg, "image/jpg", "image/pjpeg"),
        _file_type("png", "image/png", _is_png, "image/x-png"),
        _file_type("webp", "image/webp", _is_webp),
        _file_type("doc", "application/msword", _ole2_checker("WordDocument")),
        _file_type("docx", _DOCX, _ooxml_checker("word/document.xml")),
        _file_type(
            "xls",
            "application/vnd.ms-excel",
            _ole2_checker("Workbook", "Book"),
            "application/excel",
            "application/x-excel",
            "application/x-msexcel",
        ),
        _file_type("xlsx", _XLSX, _ooxml_checker("xl/workbook.xml")),
        _file_type("txt", "text/plain", _is_text),
    )
}


# --------------------------------------------------------------------------- file names
def sanitize_filename(raw_name: str | None) -> str:
    """Return a safe display name: no path components, control or reserved characters."""
    name = unicodedata.normalize("NFC", raw_name or "")
    name = name.replace("\\", "/").rsplit("/", 1)[-1]
    # Drop control/format characters (e.g. the right-to-left override used to disguise
    # extensions) but keep the zero-width (non-)joiners that Persian words legitimately use.
    name = "".join(char for char in name if char in _KEPT_FORMAT_CHARACTERS or unicodedata.category(char)[0] != "C")
    name = _RESERVED_CHARACTERS.sub("_", name).strip().rstrip(". ").strip()
    if not name or name.strip(".") == "":
        raise UploadRejectedError("invalid_filename", "نام فایل معتبر نیست.")
    if len(name) > MAX_FILENAME_LENGTH:
        stem, dot, extension = name.rpartition(".")
        if not dot or len(extension) > 20:
            raise UploadRejectedError("invalid_filename", "نام فایل بیش از حد طولانی است.")
        name = f"{stem[: MAX_FILENAME_LENGTH - len(extension) - 1]}.{extension}"
    return name


def resolve_file_type(filename: str, allowed_extensions: frozenset[str]) -> FileType:
    """Determine the file type from the (sanitized) name according to the upload policy."""
    segments = [segment.strip().lower() for segment in filename.split(".")]
    if len(segments) < 2 or not segments[-1]:
        raise UploadRejectedError("file_type_not_allowed", "فایل باید پسوند مجاز داشته باشد.")
    blocked = next((segment for segment in segments[1:] if segment in BLOCKED_EXTENSIONS), None)
    if blocked is not None:
        raise UploadRejectedError("file_type_blocked", f"بارگذاری فایل با پسوند «{blocked}» مجاز نیست.")
    extension = segments[-1]
    file_type = SUPPORTED_FILE_TYPES.get(extension)
    if file_type is None or extension not in allowed_extensions:
        allowed = "، ".join(sorted(allowed_extensions))
        raise UploadRejectedError("file_type_not_allowed", f"نوع فایل مجاز نیست. پسوندهای مجاز: {allowed}")
    return file_type


def check_declared_mime_type(file_type: FileType, declared: str | None) -> None:
    """The client-declared Content-Type must be generic or consistent with the extension."""
    normalized = (declared or "").split(";", 1)[0].strip().lower()
    if normalized in GENERIC_MIME_TYPES or normalized in file_type.accepted_declared_types:
        return
    raise UploadRejectedError("mime_type_mismatch", "نوع محتوای اعلام‌شده (MIME) با پسوند فایل همخوانی ندارد.")


# --------------------------------------------------------------------------- content
def copy_with_limit(source: IO[bytes], destination: IO[bytes], max_bytes: int) -> tuple[int, str]:
    """Stream ``source`` to ``destination``; returns ``(size, sha256_hex)``.

    Stops as soon as the size limit is exceeded, so oversized uploads are never
    fully written to disk.
    """
    digest = hashlib.sha256()
    size = 0
    while chunk := source.read(CHUNK_SIZE):
        size += len(chunk)
        if size > max_bytes:
            limit_mb = max_bytes / (1024 * 1024)
            raise UploadRejectedError(
                "file_too_large", f"حجم فایل بیشتر از حد مجاز ({limit_mb:g} مگابایت) است.", status_code=413
            )
        digest.update(chunk)
        destination.write(chunk)
    if size == 0:
        raise UploadRejectedError("empty_file", "فایل خالی است.")
    return size, digest.hexdigest()


def verify_content(file_type: FileType, path: Path) -> None:
    if not file_type.matches_content(path):
        raise UploadRejectedError("file_content_mismatch", "محتوای فایل با پسوند آن همخوانی ندارد یا فایل خراب است.")


def sha256_of_stream(stream: IO[bytes]) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    while chunk := stream.read(CHUNK_SIZE):
        size += len(chunk)
        digest.update(chunk)
    return size, digest.hexdigest()
