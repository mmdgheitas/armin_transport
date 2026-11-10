"""Test helpers: an API client wrapper and a data factory."""

from __future__ import annotations

import hashlib
import io
import itertools
import uuid
import zipfile
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from flask import Flask
from werkzeug.test import TestResponse

from app.container import Services
from app.core.datetime_utils import utcnow
from app.extensions import db
from app.models import (
    AuditLog,
    Company,
    Document,
    ProductFieldDefinition,
    ProductFieldType,
    Shipment,
    ShipmentStatus,
    TrackingCodeHistory,
    TrackingCodeType,
    User,
    UserRole,
)

API_PREFIX = "/api/v1"
DEFAULT_PASSWORD = "Str0ng-Test-Passw0rd"  # test-only credential
_counter = itertools.count(1)

PDF_BYTES = b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 32
JPEG_BYTES = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x00" * 32 + b"\xff\xd9"
WEBP_BYTES = b"RIFF" + (36).to_bytes(4, "little") + b"WEBPVP8 " + b"\x00" * 28
TEXT_BYTES = "سلام دنیا\nplain text file\n".encode()
EXE_BYTES = b"MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff\x00\x00" + b"\x00" * 64
_OLE2_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
DOC_BYTES = _OLE2_MAGIC + b"\x00" * 504 + "WordDocument".encode("utf-16-le") + b"\x00" * 100
XLS_BYTES = _OLE2_MAGIC + b"\x00" * 504 + "Workbook".encode("utf-16-le") + b"\x00" * 100


def _ooxml(main_part: str, *, extra: dict[str, bytes] | None = None) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types/>')
        archive.writestr(main_part, '<?xml version="1.0"?><root/>')
        for name, content in (extra or {}).items():
            archive.writestr(name, content)
    return buffer.getvalue()


DOCX_BYTES = _ooxml("word/document.xml")
XLSX_BYTES = _ooxml("xl/workbook.xml")
DOCM_AS_DOCX_BYTES = _ooxml("word/document.xml", extra={"word/vbaProject.bin": b"\x00\x01"})


def upload_file(
    name: str, content: bytes, content_type: str | None = None
) -> tuple[io.BytesIO, str] | tuple[io.BytesIO, str, str]:
    """A werkzeug test-client file tuple."""
    if content_type is None:
        return (io.BytesIO(content), name)
    return (io.BytesIO(content), name, content_type)


@dataclass
class Tokens:
    access_token: str
    refresh_token: str


class Api:
    """Thin wrapper around the Flask test client that adds the API prefix and auth header."""

    def __init__(self, app: Flask, token: str | None = None, *, ip: str | None = None) -> None:
        self._app = app
        self._client = app.test_client()
        self.token = token
        self._ip = ip

    def _open(self, method: str, path: str, **kwargs: Any) -> TestResponse:
        headers = dict(kwargs.pop("headers", {}) or {})
        if self.token and "Authorization" not in headers:
            headers["Authorization"] = f"Bearer {self.token}"
        if self._ip:
            kwargs.setdefault("environ_overrides", {})["REMOTE_ADDR"] = self._ip
        url = path if path.startswith("/") and path.startswith(API_PREFIX) else f"{API_PREFIX}{path}"
        return self._client.open(url, method=method, headers=headers, **kwargs)

    def get(self, path: str, **kwargs: Any) -> TestResponse:
        return self._open("GET", path, **kwargs)

    def post(self, path: str, **kwargs: Any) -> TestResponse:
        return self._open("POST", path, **kwargs)

    def patch(self, path: str, **kwargs: Any) -> TestResponse:
        return self._open("PATCH", path, **kwargs)

    def put(self, path: str, **kwargs: Any) -> TestResponse:
        return self._open("PUT", path, **kwargs)

    def delete(self, path: str, **kwargs: Any) -> TestResponse:
        return self._open("DELETE", path, **kwargs)

    def login(self, username: str, password: str = DEFAULT_PASSWORD) -> TestResponse:
        return self.post("/auth/login", json={"username": username, "password": password})

    def upload(self, shipment: Any, files: list[Any], /, **form: Any) -> TestResponse:
        data: dict[str, Any] = {"files": files, **form}
        return self.post(f"/shipments/{shipment}/documents", data=data, content_type="multipart/form-data")


class Factory:
    """Creates persisted test records directly (bypassing HTTP) and logged-in API clients."""

    def __init__(self, app: Flask) -> None:
        self._app = app

    @property
    def services(self) -> Services:
        result: Services = self._app.extensions["services"]
        return result

    def _save(self, *objects: Any) -> None:
        with self._app.app_context():
            for item in objects:
                db.session.add(item)
            db.session.commit()
            for item in objects:
                db.session.refresh(item)
                db.session.expunge(item)
            db.session.remove()

    def company(self, **overrides: Any) -> Company:
        number = next(_counter)
        company = Company(
            **{"name": f"شرکت آزمایشی {number}", "company_code": f"CO{number:05d}", "is_active": True, **overrides}
        )
        self._save(company)
        return company

    def user(
        self,
        *,
        role: UserRole = UserRole.EMPLOYEE,
        company: Company | None = None,
        password: str = DEFAULT_PASSWORD,
        **overrides: Any,
    ) -> User:
        number = next(_counter)
        if role is UserRole.EMPLOYEE and company is None:
            company = self.company()
        user = User(
            **{
                "username": f"user{number:05d}",
                "full_name": f"کاربر {number}",
                "password_hash": self.services.passwords.hash(password),
                "role": role,
                "company_id": company.id if company is not None and role is UserRole.EMPLOYEE else None,
                "is_active": True,
                **overrides,
            }
        )
        self._save(user)
        return user

    def admin(self, **overrides: Any) -> User:
        return self.user(role=UserRole.SUPER_ADMIN, **overrides)

    def employee(self, company: Company | None = None, **overrides: Any) -> User:
        return self.user(role=UserRole.EMPLOYEE, company=company, **overrides)

    def company_of(self, user: User) -> Company:
        company: Company = self.get(Company, user.company_id)
        return company

    def shipment(self, company: Company, creator: User, **overrides: Any) -> Shipment:
        number = next(_counter)
        values: dict[str, Any] = {
            "company_id": company.id,
            "created_by": creator.id,
            "tracking_code": f"TEST-{number:08d}",
            "tracking_code_type": TrackingCodeType.MANUAL,
            "status": ShipmentStatus.ACTIVE,
            "description": f"محمولهٔ آزمایشی {number}",
            **overrides,
        }
        shipment = Shipment(**values)
        with self._app.app_context():
            db.session.add(shipment)
            db.session.flush()
            db.session.add(
                TrackingCodeHistory(
                    shipment_id=shipment.id, old_code=None, new_code=shipment.tracking_code, changed_by=creator.id
                )
            )
            db.session.commit()
            db.session.refresh(shipment)
            db.session.expunge(shipment)
            db.session.remove()
        return shipment

    def field(self, **overrides: Any) -> ProductFieldDefinition:
        number = next(_counter)
        definition = ProductFieldDefinition(
            **{
                "field_key": f"field_{number}",
                "label": f"فیلد {number}",
                "data_type": ProductFieldType.TEXT,
                "is_required": False,
                "is_active": True,
                "is_customer_visible": False,
                "display_order": number,
                "version": 1,
                **overrides,
            }
        )
        self._save(definition)
        return definition

    def document(self, shipment: Shipment, uploader: User, content: bytes = PDF_BYTES, **overrides: Any) -> Document:
        """Store a real file through the storage backend and create its metadata row."""
        storage = self.services.storage
        handle, temp_path = storage.create_temp_file()
        with handle:
            handle.write(content)
        storage_name = storage.new_storage_name()
        storage_path = storage.commit(temp_path, storage_name)
        number = next(_counter)
        document = Document(
            **{
                "shipment_id": shipment.id,
                "uploaded_by": uploader.id,
                "original_name": f"document-{number}.pdf",
                "storage_name": storage_name,
                "storage_path": storage_path,
                "mime_type": "application/pdf",
                "extension": "pdf",
                "file_size": len(content),
                "checksum": hashlib.sha256(content).hexdigest(),
                "is_customer_visible": True,
                **overrides,
            }
        )
        self._save(document)
        return document

    def login(self, user: User, password: str = DEFAULT_PASSWORD, *, app: Flask | None = None) -> Api:
        """Return an API client authenticated as ``user`` (through the real login endpoint)."""
        target = app or self._app
        client = Api(target)
        response = client.login(user.username, password)
        assert response.status_code == 200, response.get_json()
        client.token = response.get_json()["data"]["access_token"]
        return client

    def tokens(self, user: User, password: str = DEFAULT_PASSWORD) -> Tokens:
        response = Api(self._app).login(user.username, password)
        assert response.status_code == 200, response.get_json()
        data = response.get_json()["data"]
        return Tokens(access_token=data["access_token"], refresh_token=data["refresh_token"])

    def expire_all(self, model: Any, column: str) -> None:
        """Move a timestamp column of every row of ``model`` into the past."""
        with self._app.app_context():
            db.session.execute(db.update(model).values({column: utcnow() - timedelta(seconds=5)}))
            db.session.commit()
            db.session.remove()

    def count(self, model: Any, *conditions: Any) -> int:
        with self._app.app_context():
            statement = db.select(db.func.count()).select_from(model)
            for condition in conditions:
                statement = statement.where(condition)
            result = int(db.session.scalar(statement) or 0)
            db.session.remove()
            return result

    def get(self, model: Any, identifier: uuid.UUID | str) -> Any:
        with self._app.app_context():
            instance = db.session.get(model, uuid.UUID(str(identifier)))
            if instance is not None:
                db.session.refresh(instance)
                db.session.expunge(instance)
            db.session.remove()
            return instance

    def audit_actions(self) -> list[str]:
        with self._app.app_context():
            actions = list(db.session.scalars(db.select(AuditLog.action).order_by(AuditLog.created_at)))
            db.session.remove()
            return actions
