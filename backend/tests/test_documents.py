"""Documents: upload validation pipeline, storage, download, visibility and deletion."""

from __future__ import annotations

import hashlib
import io
import stat
import sys
import uuid
import zipfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from flask import Flask

from app.config import SUPPORTED_UPLOAD_EXTENSIONS
from app.container import Services
from app.core.datetime_utils import utcnow
from app.extensions import db
from app.models import AuditLog, Company, Document, Shipment, User
from app.modules.documents.validation import (
    BLOCKED_EXTENSIONS,
    SUPPORTED_FILE_TYPES,
    UploadRejectedError,
    sanitize_filename,
)
from tests.support import (
    DOC_BYTES,
    DOCM_AS_DOCX_BYTES,
    DOCX_BYTES,
    EXE_BYTES,
    JPEG_BYTES,
    PDF_BYTES,
    PNG_BYTES,
    TEXT_BYTES,
    WEBP_BYTES,
    XLS_BYTES,
    XLSX_BYTES,
    Api,
    Factory,
    upload_file,
)

DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


class Scenario:
    """One company with an employee, a shipment and a logged-in client."""

    def __init__(self, factory: Factory) -> None:
        self.company: Company = factory.company()
        self.employee: User = factory.employee(self.company)
        self.shipment: Shipment = factory.shipment(self.company, self.employee)
        self.api: Api = factory.login(self.employee)


@pytest.fixture
def scenario(factory: Factory) -> Scenario:
    return Scenario(factory)


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


def stored_files(services: Services) -> list[Path]:
    """Every regular file in the storage root, including leftovers in the temp directory."""
    return sorted(path for path in services.storage.root.rglob("*") if path.is_file())


@pytest.fixture(autouse=True)
def empty_storage(services: Services) -> None:
    for path in stored_files(services):
        path.unlink()


def _code(response: Any) -> str:
    result: str = response.get_json()["errors"]["code"]
    return result


# --------------------------------------------------------------------------- successful uploads
def test_upload_stores_the_file_privately_under_a_random_name(
    scenario: Scenario, services: Services, app: Flask, factory: Factory
) -> None:
    response = scenario.api.upload(
        scenario.shipment.id, [upload_file("بارنامه شماره ۱۲.pdf", PDF_BYTES, "application/pdf")]
    )
    assert response.status_code == 201, response.get_json()
    (item,) = response.get_json()["data"]
    assert item["original_name"] == "بارنامه شماره ۱۲.pdf"
    assert item["mime_type"] == "application/pdf"
    assert item["extension"] == "pdf"
    assert item["file_size"] == len(PDF_BYTES)
    assert item["checksum"] == hashlib.sha256(PDF_BYTES).hexdigest()
    assert item["shipment_id"] == str(scenario.shipment.id)
    assert item["uploaded_by"] == {"id": str(scenario.employee.id), "full_name": scenario.employee.full_name}
    assert item["is_customer_visible"] is True
    assert "storage_path" not in item and "storage_name" not in item

    with app.app_context():
        document = db.session.get(Document, uuid.UUID(item["id"]))
        assert document is not None
        storage_name, storage_path = document.storage_name, document.storage_path
        db.session.remove()
    assert len(storage_name) == 64 and int(storage_name, 16) >= 0
    assert storage_path == f"{storage_name[:2]}/{storage_name[2:4]}/{storage_name}"
    assert "." not in storage_name  # no extension on disk
    assert "بارنامه" not in storage_path

    (stored,) = stored_files(services)
    assert stored == services.storage.root / storage_path
    assert stored.read_bytes() == PDF_BYTES
    assert stat.S_IMODE(stored.stat().st_mode) == 0o600
    assert factory.audit_actions()[-1] == "DOCUMENT_UPLOADED"


@pytest.mark.parametrize(
    ("name", "content", "declared", "expected_mime"),
    [
        ("scan.pdf", PDF_BYTES, "application/pdf", "application/pdf"),
        ("photo.jpg", JPEG_BYTES, "image/jpeg", "image/jpeg"),
        ("photo.JPEG", JPEG_BYTES, "image/jpeg", "image/jpeg"),
        ("image.png", PNG_BYTES, "image/png", "image/png"),
        ("image.webp", WEBP_BYTES, "image/webp", "image/webp"),
        ("letter.doc", DOC_BYTES, "application/msword", "application/msword"),
        ("letter.docx", DOCX_BYTES, DOCX_MIME, DOCX_MIME),
        ("sheet.xls", XLS_BYTES, "application/vnd.ms-excel", "application/vnd.ms-excel"),
        ("sheet.xlsx", XLSX_BYTES, XLSX_MIME, XLSX_MIME),
        ("notes.txt", TEXT_BYTES, "text/plain; charset=utf-8", "text/plain"),
        ("generic.pdf", PDF_BYTES, "application/octet-stream", "application/pdf"),
        ("undeclared.pdf", PDF_BYTES, None, "application/pdf"),
    ],
)
def test_every_allowed_type_is_accepted(
    scenario: Scenario, name: str, content: bytes, declared: str | None, expected_mime: str
) -> None:
    response = scenario.api.upload(scenario.shipment.id, [upload_file(name, content, declared)])
    assert response.status_code == 201, response.get_json()
    (item,) = response.get_json()["data"]
    assert item["mime_type"] == expected_mime  # the server's canonical type, not the client's claim
    assert item["extension"] == name.rsplit(".", 1)[1].lower()


def test_multiple_files_in_one_request(scenario: Scenario, services: Services) -> None:
    files = [
        upload_file("a.pdf", PDF_BYTES, "application/pdf"),
        upload_file("b.png", PNG_BYTES, "image/png"),
        upload_file("c.txt", TEXT_BYTES, "text/plain"),
    ]
    response = scenario.api.upload(scenario.shipment.id, files)
    assert response.status_code == 201, response.get_json()
    assert [item["original_name"] for item in response.get_json()["data"]] == ["a.pdf", "b.png", "c.txt"]
    assert len(stored_files(services)) == 3


def test_identical_content_is_stored_as_separate_documents(scenario: Scenario, services: Services) -> None:
    for _ in range(2):
        assert scenario.api.upload(scenario.shipment.id, [upload_file("same.pdf", PDF_BYTES)]).status_code == 201
    assert len(stored_files(services)) == 2
    assert len({path.name for path in stored_files(services)}) == 2


@pytest.mark.parametrize(
    ("form_value", "expected"),
    [(None, True), ("true", True), ("false", False), ("1", True), ("0", False)],
)
def test_customer_visibility_can_be_chosen_at_upload(
    scenario: Scenario, form_value: str | None, expected: bool
) -> None:
    form = {} if form_value is None else {"customer_visible": form_value}
    response = scenario.api.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)], **form)
    assert response.status_code == 201, response.get_json()
    assert response.get_json()["data"][0]["is_customer_visible"] is expected


def test_default_customer_visibility_is_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    scenario = Scenario(factory)
    private_by_default = make_app(document_customer_visible_default=False)
    client = factory.login(scenario.employee, app=private_by_default)
    response = client.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)])
    assert response.get_json()["data"][0]["is_customer_visible"] is False


# --------------------------------------------------------------------------- file names
@pytest.mark.parametrize(
    ("raw_name", "stored_name"),
    [
        ("../../etc/passwd.pdf", "passwd.pdf"),
        ("/absolute/path/report.pdf", "report.pdf"),
        ("in<va>li:d|na?me*.pdf", "in_va_li_d_na_me_.pdf"),
        ("with\x00null\x1fcontrol.pdf", "withnullcontrol.pdf"),
        ("  spaced name .pdf", "spaced name .pdf"),
        ("می‌خواهم.pdf", "می‌خواهم.pdf"),  # the zero-width non-joiner of Persian words is preserved
        ("a" * 300 + ".pdf", "a" * 251 + ".pdf"),
    ],
)
def test_file_names_are_sanitized(scenario: Scenario, services: Services, raw_name: str, stored_name: str) -> None:
    response = scenario.api.upload(scenario.shipment.id, [upload_file(raw_name, PDF_BYTES, "application/pdf")])
    assert response.status_code == 201, response.get_json()
    assert response.get_json()["data"][0]["original_name"] == stored_name
    # Whatever the client called the file, it lands inside the storage root under a random name.
    (stored,) = stored_files(services)
    assert stored.resolve().is_relative_to(services.storage.root.resolve())
    assert len(stored.name) == 64


@pytest.mark.parametrize(
    ("raw_name", "expected"),
    [
        ("..\\..\\windows\\system32\\evil.pdf", "evil.pdf"),
        ("C:\\Users\\me\\Desktop\\فاکتور.pdf", "فاکتور.pdf"),
        ("mixed/..\\separators/..\\name.pdf", "name.pdf"),
        ("e\u0301.pdf", "\u00e9.pdf"),  # normalized to NFC
        ("trailing dots and spaces.pdf. . ", "trailing dots and spaces.pdf"),
        ("tab\tand\nnewline.pdf", "tabandnewline.pdf"),
        ("bidi\u202eoverride\u2066marks.pdf", "bidioverridemarks.pdf"),
    ],
)
def test_sanitize_filename_unit(raw_name: str, expected: str) -> None:
    assert sanitize_filename(raw_name) == expected


@pytest.mark.parametrize("raw_name", [None, "", ".", "..", " . ", "a/", "dir\\", "\u202e\u200f", "x" * 300])
def test_sanitize_filename_rejects_unusable_names(raw_name: str | None) -> None:
    with pytest.raises(UploadRejectedError) as error:
        sanitize_filename(raw_name)
    assert error.value.code == "invalid_filename"


def test_supported_types_and_configuration_agree() -> None:
    """The configurable allow-list can only ever contain types the validator understands."""
    assert set(SUPPORTED_UPLOAD_EXTENSIONS) == set(SUPPORTED_FILE_TYPES)
    assert not set(SUPPORTED_FILE_TYPES) & BLOCKED_EXTENSIONS


def test_backslash_paths_never_reach_the_file_system(scenario: Scenario, services: Services) -> None:
    response = scenario.api.upload(
        scenario.shipment.id, [upload_file("..\\..\\windows\\system32\\evil.pdf", PDF_BYTES, "application/pdf")]
    )
    assert response.status_code == 201, response.get_json()
    name = response.get_json()["data"][0]["original_name"]
    assert "/" not in name and "\\" not in name
    (stored,) = stored_files(services)
    assert stored.resolve().is_relative_to(services.storage.root.resolve())


@pytest.mark.parametrize("raw_name", ["", ".", "..", "...", "   ", "/"])
def test_unusable_file_names_are_rejected(scenario: Scenario, services: Services, raw_name: str) -> None:
    data = {"files": [(io.BytesIO(PDF_BYTES), raw_name, "application/pdf")]}
    response = scenario.api.post(
        f"/shipments/{scenario.shipment.id}/documents", data=data, content_type="multipart/form-data"
    )
    assert response.status_code == 422
    assert _code(response) in {"invalid_filename", "no_files", "file_type_not_allowed"}
    assert stored_files(services) == []


# --------------------------------------------------------------------------- rejected uploads
@pytest.mark.parametrize(
    ("name", "content", "declared", "code"),
    [
        # extension policy
        ("archive.zip", b"PK\x03\x04" + b"\x00" * 30, "application/zip", "file_type_not_allowed"),
        ("page.html", b"<html><script>alert(1)</script></html>", "text/html", "file_type_not_allowed"),
        ("vector.svg", b"<svg xmlns='http://www.w3.org/2000/svg'/>", "image/svg+xml", "file_type_not_allowed"),
        ("macro.docm", DOCM_AS_DOCX_BYTES, None, "file_type_not_allowed"),
        ("noextension", PDF_BYTES, "application/pdf", "file_type_not_allowed"),
        ("trailingdot.", PDF_BYTES, "application/pdf", "file_type_not_allowed"),
        ("script.php", b"<?php system($_GET['c']); ?>", None, "file_type_not_allowed"),
        # explicitly blocked executables, in any position and any letter case
        ("setup.exe", EXE_BYTES, "application/x-msdownload", "file_type_blocked"),
        ("SETUP.EXE", EXE_BYTES, None, "file_type_blocked"),
        ("library.dll", EXE_BYTES, None, "file_type_blocked"),
        ("run.bat", b"@echo off\r\ndel /q *\r\n", None, "file_type_blocked"),
        ("run.cmd", b"@echo off\r\n", None, "file_type_blocked"),
        ("run.ps1", b"Remove-Item -Recurse C:\\\r\n", None, "file_type_blocked"),
        ("run.sh", b"#!/bin/sh\nrm -rf /\n", None, "file_type_blocked"),
        ("app.js", b"alert(1)", "application/javascript", "file_type_blocked"),
        ("macro.vbs", b"MsgBox 1", None, "file_type_blocked"),
        ("tool.jar", b"PK\x03\x04", None, "file_type_blocked"),
        ("saver.scr", EXE_BYTES, None, "file_type_blocked"),
        ("command.com", EXE_BYTES, None, "file_type_blocked"),
        ("invoice.pdf.exe", EXE_BYTES, "application/pdf", "file_type_blocked"),
        ("invoice.exe.pdf", PDF_BYTES, "application/pdf", "file_type_blocked"),
        ("invoice.Js.pdf", PDF_BYTES, "application/pdf", "file_type_blocked"),
        ("invoice.pdf.exe.", EXE_BYTES, None, "file_type_blocked"),
        ("invoice.pdf .exe", EXE_BYTES, None, "file_type_blocked"),
        ("invoice.pdf\x00.exe", EXE_BYTES, None, "file_type_blocked"),
        ("invoice\u202efdp.exe", EXE_BYTES, None, "file_type_blocked"),  # right-to-left override trick
        # declared MIME type contradicts the extension
        ("photo.png", PNG_BYTES, "application/pdf", "mime_type_mismatch"),
        ("report.pdf", PDF_BYTES, "text/html", "mime_type_mismatch"),
        ("notes.txt", TEXT_BYTES, "application/x-msdownload", "mime_type_mismatch"),
        # content does not match the extension
        ("malware.pdf", EXE_BYTES, "application/pdf", "file_content_mismatch"),
        ("really-png.jpg", PNG_BYTES, "image/jpeg", "file_content_mismatch"),
        ("really-pdf.png", PDF_BYTES, "image/png", "file_content_mismatch"),
        ("fake.webp", b"RIFF\x00\x00\x00\x00WAVEfmt " + b"\x00" * 16, "image/webp", "file_content_mismatch"),
        ("binary.txt", b"text then binary \x00\x01\x02", "text/plain", "file_content_mismatch"),
        ("executable.txt", EXE_BYTES, "text/plain", "file_content_mismatch"),
        ("plain-zip.docx", b"PK\x03\x04" + b"\x00" * 40, DOCX_MIME, "file_content_mismatch"),
        ("sheet-as-doc.docx", XLSX_BYTES, DOCX_MIME, "file_content_mismatch"),
        ("with-macros.docx", DOCM_AS_DOCX_BYTES, DOCX_MIME, "file_content_mismatch"),
        ("word-as-excel.xls", DOC_BYTES, "application/vnd.ms-excel", "file_content_mismatch"),
        ("html.doc", b"<html><body>fake</body></html>", "application/msword", "file_content_mismatch"),
        ("truncated.pdf", b"%PD", "application/pdf", "file_content_mismatch"),
        # empty
        ("empty.pdf", b"", "application/pdf", "empty_file"),
    ],
)
def test_dangerous_or_inconsistent_files_are_rejected(
    scenario: Scenario,
    services: Services,
    factory: Factory,
    name: str,
    content: bytes,
    declared: str | None,
    code: str,
) -> None:
    response = scenario.api.upload(scenario.shipment.id, [upload_file(name, content, declared)])
    assert response.status_code == 422, response.get_json()
    errors = response.get_json()["errors"]
    assert errors["code"] == code
    assert list(errors["fields"]) == ["files.0"]
    assert factory.count(Document) == 0
    assert stored_files(services) == []  # nothing stored, no temporary leftovers
    assert factory.audit_actions()[-1] == "DOCUMENT_UPLOAD_REJECTED"


def test_one_bad_file_rejects_the_whole_request(scenario: Scenario, services: Services, factory: Factory) -> None:
    files = [
        upload_file("good-1.pdf", PDF_BYTES, "application/pdf"),
        upload_file("good-2.png", PNG_BYTES, "image/png"),
        upload_file("bad.pdf", EXE_BYTES, "application/pdf"),
        upload_file("good-3.txt", TEXT_BYTES, "text/plain"),
    ]
    response = scenario.api.upload(scenario.shipment.id, files)
    assert response.status_code == 422
    assert list(response.get_json()["errors"]["fields"]) == ["files.2"]
    assert factory.count(Document) == 0
    assert stored_files(services) == []
    assert "DOCUMENT_UPLOADED" not in factory.audit_actions()


def test_request_without_files_is_rejected(scenario: Scenario) -> None:
    response = scenario.api.post(
        f"/shipments/{scenario.shipment.id}/documents",
        data={"customer_visible": "true"},
        content_type="multipart/form-data",
    )
    assert response.status_code == 422
    assert _code(response) == "no_files"
    wrong_field = scenario.api.post(
        f"/shipments/{scenario.shipment.id}/documents",
        data={"file": [upload_file("a.pdf", PDF_BYTES)]},
        content_type="multipart/form-data",
    )
    assert _code(wrong_field) == "no_files"
    as_json = scenario.api.post(f"/shipments/{scenario.shipment.id}/documents", json={"files": ["a.pdf"]})
    assert as_json.status_code == 422


def test_invalid_form_fields_are_rejected(scenario: Scenario, services: Services) -> None:
    response = scenario.api.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)], customer_visible="perhaps")
    assert response.status_code == 422
    assert "customer_visible" in response.get_json()["errors"]["fields"]
    unknown = scenario.api.upload(
        scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)], shipment_id=str(uuid.uuid4())
    )
    assert unknown.status_code == 422
    assert stored_files(services) == []


def test_file_size_limit(factory: Factory, make_app: Callable[..., Flask], services: Services) -> None:
    scenario = Scenario(factory)
    limited = make_app(max_upload_size_bytes=1024)
    client = factory.login(scenario.employee, app=limited)

    at_limit = b"%PDF-1.4\n" + b"x" * (1024 - 9)
    assert client.upload(scenario.shipment.id, [upload_file("ok.pdf", at_limit)]).status_code == 201

    response = client.upload(scenario.shipment.id, [upload_file("big.pdf", at_limit + b"y")])
    assert response.status_code == 413
    assert _code(response) == "file_too_large"
    assert response.get_json()["errors"]["file_index"] == 0
    assert factory.count(Document) == 1
    assert len(stored_files(services)) == 1


def test_total_request_size_limit(factory: Factory, make_app: Callable[..., Flask], services: Services) -> None:
    scenario = Scenario(factory)
    limited = make_app(max_upload_size_bytes=1024, max_files_per_upload=1)
    client = factory.login(scenario.employee, app=limited)
    huge = b"%PDF-1.4\n" + b"x" * (3 * 1024 * 1024)
    response = client.upload(scenario.shipment.id, [upload_file("huge.pdf", huge)])
    assert response.status_code == 413
    assert _code(response) == "payload_too_large"
    assert stored_files(services) == []


def test_file_count_limit(factory: Factory, make_app: Callable[..., Flask], services: Services) -> None:
    scenario = Scenario(factory)
    limited = make_app(max_files_per_upload=2)
    client = factory.login(scenario.employee, app=limited)
    files = [upload_file(f"f{index}.pdf", PDF_BYTES) for index in range(3)]
    response = client.upload(scenario.shipment.id, files)
    assert response.status_code == 422
    assert _code(response) == "too_many_files"
    assert stored_files(services) == []


def test_allowed_extensions_are_configurable(factory: Factory, make_app: Callable[..., Flask]) -> None:
    scenario = Scenario(factory)
    pdf_only = make_app(allowed_upload_extensions=frozenset({"pdf"}))
    client = factory.login(scenario.employee, app=pdf_only)
    assert client.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)]).status_code == 201
    response = client.upload(scenario.shipment.id, [upload_file("a.png", PNG_BYTES, "image/png")])
    assert response.status_code == 422
    assert _code(response) == "file_type_not_allowed"


def test_upload_to_an_archived_shipment_is_refused(scenario: Scenario, factory: Factory, services: Services) -> None:
    assert scenario.api.post(f"/shipments/{scenario.shipment.id}/archive").status_code == 200
    response = scenario.api.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)])
    assert response.status_code == 409
    assert _code(response) == "shipment_archived"
    assert stored_files(services) == []


def test_upload_to_unknown_or_foreign_shipment(scenario: Scenario, factory: Factory, services: Services) -> None:
    other = Scenario(factory)
    for shipment_id in (other.shipment.id, uuid.uuid4()):
        response = scenario.api.upload(shipment_id, [upload_file("a.pdf", PDF_BYTES)])
        assert response.status_code == 404
    assert factory.count(Document) == 0
    assert stored_files(services) == []


def test_upload_requires_authentication(api: Api, scenario: Scenario, services: Services) -> None:
    response = api.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)])
    assert response.status_code == 401
    assert stored_files(services) == []


def test_database_failure_after_staging_leaves_no_orphan_files(
    scenario: Scenario, services: Services, factory: Factory, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Compensation: files already moved into place are removed when the transaction fails."""

    def explode(*_: Any, **__: Any) -> None:
        raise RuntimeError("simulated failure while writing the audit trail")

    monkeypatch.setattr(type(services.audit), "record", explode)
    response = scenario.api.upload(
        scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES), upload_file("b.png", PNG_BYTES, "image/png")]
    )
    assert response.status_code == 500
    assert _code(response) == "internal_error"
    assert "simulated failure" not in response.get_data(as_text=True)
    assert factory.count(Document) == 0
    assert stored_files(services) == []


# --------------------------------------------------------------------------- malware scanner hook
def _scanner_script(tmp_path: Path, body: str) -> str:
    script = tmp_path / "scanner.py"
    script.write_text(body, encoding="utf-8")
    return f"{sys.executable} {script}"


def test_malware_scanner_can_reject_a_file(
    factory: Factory, make_app: Callable[..., Flask], tmp_path: Path, services: Services
) -> None:
    command = _scanner_script(
        tmp_path,
        "import sys\nsys.exit(1 if b'EICAR' in open(sys.argv[1], 'rb').read() else 0)\n",
    )
    scenario = Scenario(factory)
    client = factory.login(scenario.employee, app=make_app(malware_scan_command=command))

    assert client.upload(scenario.shipment.id, [upload_file("clean.pdf", PDF_BYTES)]).status_code == 201
    response = client.upload(scenario.shipment.id, [upload_file("infected.pdf", PDF_BYTES + b"EICAR-TEST")])
    assert response.status_code == 422
    assert _code(response) == "malware_detected"
    assert factory.count(Document) == 1
    assert len(stored_files(services)) == 1


def test_scanner_failure_rejects_the_upload(
    factory: Factory, make_app: Callable[..., Flask], tmp_path: Path, services: Services
) -> None:
    scenario = Scenario(factory)
    for command in (_scanner_script(tmp_path, "import sys\nsys.exit(2)\n"), "/nonexistent/clamdscan --no-summary"):
        client = factory.login(scenario.employee, app=make_app(malware_scan_command=command))
        response = client.upload(scenario.shipment.id, [upload_file("a.pdf", PDF_BYTES)])
        assert response.status_code == 503
        assert _code(response) == "malware_scanner_unavailable"
    assert stored_files(services) == []


# --------------------------------------------------------------------------- listing
def test_list_documents_of_a_shipment(scenario: Scenario, factory: Factory) -> None:
    first = factory.document(scenario.shipment, scenario.employee, original_name="اول.pdf")
    second = factory.document(scenario.shipment, scenario.employee, original_name="دوم.pdf", is_customer_visible=False)
    factory.document(scenario.shipment, scenario.employee, deleted_at=utcnow(), deleted_by=scenario.employee.id)
    other_shipment = factory.shipment(scenario.company, scenario.employee)
    factory.document(other_shipment, scenario.employee)

    data = scenario.api.get(f"/shipments/{scenario.shipment.id}/documents").get_json()["data"]
    assert {item["id"] for item in data["items"]} == {str(first.id), str(second.id)}
    assert data["pagination"]["total"] == 2
    paged = scenario.api.get(f"/shipments/{scenario.shipment.id}/documents?per_page=1&page=2").get_json()["data"]
    assert len(paged["items"]) == 1


# --------------------------------------------------------------------------- download
def test_download_returns_the_file_as_a_safe_attachment(scenario: Scenario, factory: Factory) -> None:
    document = factory.document(scenario.shipment, scenario.employee, original_name="بارنامه نهایی.pdf")
    response = scenario.api.get(f"/documents/{document.id}/download")
    assert response.status_code == 200
    assert response.data == PDF_BYTES
    assert response.headers["Content-Type"] == "application/pdf"
    assert response.headers["Content-Length"] == str(len(PDF_BYTES))
    disposition = response.headers["Content-Disposition"]
    assert disposition.startswith("attachment;")
    assert "filename*=UTF-8''" in disposition
    assert "%D8%A8%D8%A7%D8%B1%D9%86%D8%A7%D9%85%D9%87" in disposition  # percent-encoded Persian name
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Content-Security-Policy"] == "default-src 'none'; sandbox"
    assert response.headers["Cache-Control"] == "private, no-store"
    assert "ETag" not in response.headers
    assert factory.audit_actions()[-1] == "DOCUMENT_DOWNLOADED"


def test_download_name_cannot_inject_headers(scenario: Scenario, factory: Factory) -> None:
    document = factory.document(scenario.shipment, scenario.employee, original_name='evil"\r\nSet-Cookie: x=1.pdf')
    response = scenario.api.get(f"/documents/{document.id}/download")
    assert response.status_code == 200
    assert "Set-Cookie" not in response.headers
    assert "\r" not in response.headers["Content-Disposition"]
    assert "\n" not in response.headers["Content-Disposition"]


def test_download_of_unknown_deleted_or_foreign_document_is_404(scenario: Scenario, factory: Factory) -> None:
    other = Scenario(factory)
    foreign = factory.document(other.shipment, other.employee)
    deleted = factory.document(
        scenario.shipment, scenario.employee, deleted_at=utcnow(), deleted_by=scenario.employee.id
    )
    responses = [
        scenario.api.get(f"/documents/{foreign.id}/download"),
        scenario.api.get(f"/documents/{deleted.id}/download"),
        scenario.api.get(f"/documents/{uuid.uuid4()}/download"),
    ]
    assert [response.status_code for response in responses] == [404, 404, 404]
    assert len({response.get_json()["message"] for response in responses}) == 1
    assert all(PDF_BYTES not in response.data for response in responses)
    assert scenario.api.get("/documents/..%2F..%2Fetc%2Fpasswd/download").status_code == 404


def test_documents_of_archived_shipments_stay_downloadable(scenario: Scenario, factory: Factory) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    scenario.api.post(f"/shipments/{scenario.shipment.id}/archive")
    assert scenario.api.get(f"/documents/{document.id}/download").status_code == 200


def test_tampered_file_is_not_served(scenario: Scenario, factory: Factory, services: Services) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    path = services.storage.root / document.storage_path
    path.write_bytes(PDF_BYTES.replace(b"Catalog", b"Hacked!"))  # same size, different content
    response = scenario.api.get(f"/documents/{document.id}/download")
    assert response.status_code == 500
    assert _code(response) == "document_integrity_error"
    assert b"Hacked!" not in response.data
    assert str(services.storage.root) not in response.get_data(as_text=True)
    assert "DOCUMENT_INTEGRITY_FAILURE" in factory.audit_actions()

    path.write_bytes(PDF_BYTES + b"appended")
    assert _code(scenario.api.get(f"/documents/{document.id}/download")) == "document_integrity_error"


def test_missing_file_is_reported_without_leaking_paths(
    scenario: Scenario, factory: Factory, services: Services
) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    (services.storage.root / document.storage_path).unlink()
    response = scenario.api.get(f"/documents/{document.id}/download")
    assert response.status_code == 500
    assert _code(response) == "document_file_missing"
    body = response.get_data(as_text=True)
    assert document.storage_name not in body
    assert str(services.storage.root) not in body


@pytest.mark.parametrize("evil_path", ["../../../../etc/passwd", "/etc/passwd", "..", "ab/../../../etc/hostname"])
def test_storage_paths_cannot_escape_the_storage_root(
    scenario: Scenario, factory: Factory, app: Flask, evil_path: str
) -> None:
    """Defence in depth: even a manipulated database row cannot make the API read arbitrary files."""
    document = factory.document(scenario.shipment, scenario.employee)
    with app.app_context():
        db.session.execute(db.update(Document).where(Document.id == document.id).values(storage_path=evil_path))
        db.session.commit()
        db.session.remove()
    response = scenario.api.get(f"/documents/{document.id}/download")
    assert response.status_code == 500
    assert _code(response) in {"document_storage_error", "document_file_missing"}
    assert b"root:" not in response.data


def test_checksum_verification_can_be_disabled(
    factory: Factory, make_app: Callable[..., Flask], services: Services
) -> None:
    scenario = Scenario(factory)
    document = factory.document(scenario.shipment, scenario.employee)
    client = factory.login(scenario.employee, app=make_app(verify_checksum_on_download=False))
    response = client.get(f"/documents/{document.id}/download")
    assert response.status_code == 200
    assert response.data == PDF_BYTES


# --------------------------------------------------------------------------- visibility
def test_toggle_customer_visibility(scenario: Scenario, factory: Factory) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    response = scenario.api.patch(f"/documents/{document.id}", json={"is_customer_visible": False})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["is_customer_visible"] is False
    assert factory.get(Document, document.id).is_customer_visible is False
    assert factory.audit_actions()[-1] == "DOCUMENT_VISIBILITY_CHANGED"

    count = len(factory.audit_actions())
    scenario.api.patch(f"/documents/{document.id}", json={"is_customer_visible": False})
    assert len(factory.audit_actions()) == count  # no change, no audit entry


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"is_customer_visible": "maybe"},
        {"is_customer_visible": True, "original_name": "x.exe"},
        {"shipment_id": "x"},
    ],
)
def test_document_update_validation(scenario: Scenario, factory: Factory, payload: dict[str, Any]) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    assert scenario.api.patch(f"/documents/{document.id}", json=payload).status_code == 422
    assert factory.get(Document, document.id).original_name == document.original_name


# --------------------------------------------------------------------------- deletion
def test_employees_cannot_delete_documents_by_default(scenario: Scenario, factory: Factory) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    response = scenario.api.delete(f"/documents/{document.id}")
    assert response.status_code == 403
    assert response.get_json()["errors"]["required_permissions"] == ["document:delete"]
    assert factory.get(Document, document.id).deleted_at is None


def test_admin_delete_is_a_soft_delete(
    scenario: Scenario, factory: Factory, admin_api: Api, services: Services, app: Flask
) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    response = admin_api.delete(f"/documents/{document.id}")
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"] is None

    stored = factory.get(Document, document.id)
    assert stored.deleted_at is not None
    assert stored.deleted_by is not None
    assert (services.storage.root / document.storage_path).exists()  # kept for the audit trail by default

    assert scenario.api.get(f"/shipments/{scenario.shipment.id}/documents").get_json()["data"]["items"] == []
    assert scenario.api.get(f"/documents/{document.id}/download").status_code == 404
    assert scenario.api.get(f"/shipments/{scenario.shipment.id}").get_json()["data"]["document_count"] == 0
    assert admin_api.delete(f"/documents/{document.id}").status_code == 404

    with app.app_context():
        entry = db.session.scalars(db.select(AuditLog).where(AuditLog.action == "DOCUMENT_DELETED")).one()
        assert entry.entity_id == str(document.id)
        assert entry.meta["checksum"] == document.checksum
        assert entry.meta["file_purged"] is False
        db.session.remove()


def test_employee_delete_and_file_purge_are_configurable(
    factory: Factory, make_app: Callable[..., Flask], services: Services
) -> None:
    scenario, other = Scenario(factory), Scenario(factory)
    own = factory.document(scenario.shipment, scenario.employee)
    foreign = factory.document(other.shipment, other.employee)
    permissive = make_app(employee_can_delete_documents=True, document_purge_file_on_delete=True)
    client = factory.login(scenario.employee, app=permissive)

    assert client.delete(f"/documents/{foreign.id}").status_code == 404  # still tenant-scoped
    assert factory.get(Document, foreign.id).deleted_at is None

    assert client.delete(f"/documents/{own.id}").status_code == 200
    assert factory.get(Document, own.id).deleted_at is not None
    assert not (services.storage.root / own.storage_path).exists()
    assert (services.storage.root / foreign.storage_path).exists()


def test_documents_of_archived_shipments_cannot_be_changed(
    scenario: Scenario, factory: Factory, admin_api: Api
) -> None:
    document = factory.document(scenario.shipment, scenario.employee)
    scenario.api.post(f"/shipments/{scenario.shipment.id}/archive")
    assert admin_api.delete(f"/documents/{document.id}").status_code == 409
    assert scenario.api.patch(f"/documents/{document.id}", json={"is_customer_visible": False}).status_code == 409


# --------------------------------------------------------------------------- validation unit checks
def test_zip_based_checks_do_not_decompress_archives(scenario: Scenario) -> None:
    """A highly compressed member (zip bomb pattern) is never inflated by the validator."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", b"\x00" * (20 * 1024 * 1024))
    assert len(buffer.getvalue()) < 100 * 1024
    response = scenario.api.upload(scenario.shipment.id, [upload_file("big-inside.docx", buffer.getvalue(), DOCX_MIME)])
    assert response.status_code == 201, response.get_json()
    assert response.get_json()["data"][0]["file_size"] == len(buffer.getvalue())
