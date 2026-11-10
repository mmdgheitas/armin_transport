"""Document application service: upload pipeline, authorized download, deletion."""

from __future__ import annotations

import hmac
import logging
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import IO, BinaryIO

from sqlalchemy.orm import Session, scoped_session

from app.config import Settings
from app.core.actor import Actor
from app.core.datetime_utils import utcnow
from app.core.errors import (
    AppError,
    IntegrityFailureError,
    NotFoundError,
    PayloadTooLargeError,
    ServiceUnavailableError,
    ValidationFailedError,
)
from app.core.pagination import Page
from app.core.transactions import unit_of_work
from app.models import Document
from app.modules.audit_logs.service import AuditService
from app.modules.documents.repository import DocumentRepository
from app.modules.documents.scanner import MalwareDetectedError, MalwareScanner, ScannerUnavailableError
from app.modules.documents.storage import DocumentStorage, StorageError, StoredFileMissingError
from app.modules.documents.validation import (
    FileType,
    UploadRejectedError,
    check_declared_mime_type,
    copy_with_limit,
    resolve_file_type,
    sanitize_filename,
    sha256_of_stream,
    verify_content,
)
from app.modules.shipments.service import ShipmentService

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class IncomingFile:
    """One uploaded file as received from the transport layer."""

    filename: str | None
    content_type: str | None
    stream: IO[bytes]


@dataclass(frozen=True)
class StagedUpload:
    """A fully validated upload waiting in temporary storage."""

    original_name: str
    file_type: FileType
    size: int
    checksum: str
    temp_path: Path


@dataclass(frozen=True)
class DocumentContent:
    """An opened, integrity-checked document ready to be streamed to the client."""

    document: Document
    stream: BinaryIO
    size: int


class DocumentService:
    def __init__(
        self,
        session: scoped_session[Session],
        settings: Settings,
        audit: AuditService,
        storage: DocumentStorage,
        shipments: ShipmentService,
        documents: DocumentRepository,
        scanner: MalwareScanner | None = None,
    ) -> None:
        self._session = session
        self._settings = settings
        self._audit = audit
        self._storage = storage
        self._shipments = shipments
        self._documents = documents
        self._scanner = scanner

    # ------------------------------------------------------------------ helpers
    def _get(self, actor: Actor, document_id: uuid.UUID, *, for_update: bool = False) -> Document:
        """Load a document inside the actor's tenant scope (foreign documents look missing)."""
        document = self._documents.get_scoped(
            document_id, self._shipments.scope_company_id(actor), for_update=for_update
        )
        if document is None:
            raise NotFoundError("سند موردنظر یافت نشد.")
        return document

    def _stage(self, incoming: IncomingFile) -> StagedUpload:
        """Run the complete validation pipeline for one file."""
        original_name = sanitize_filename(incoming.filename)
        file_type = resolve_file_type(original_name, self._settings.allowed_upload_extensions)
        allowed_mime_types = self._settings.allowed_upload_mime_types
        if allowed_mime_types is not None and file_type.mime_type not in allowed_mime_types:
            raise UploadRejectedError("file_type_not_allowed", "نوع این فایل مجاز نیست.")
        check_declared_mime_type(file_type, incoming.content_type)

        handle, temp_path = self._storage.create_temp_file()
        try:
            with handle:
                size, checksum = copy_with_limit(incoming.stream, handle, self._settings.max_upload_size_bytes)
            verify_content(file_type, temp_path)
            self._scan(temp_path)
        except BaseException:
            self._storage.discard_temp(temp_path)
            raise
        return StagedUpload(original_name, file_type, size, checksum, temp_path)

    def _scan(self, path: Path) -> None:
        if self._scanner is None:
            return
        try:
            self._scanner.scan(path)
        except MalwareDetectedError as exc:
            raise UploadRejectedError("malware_detected", "فایل توسط ضدبدافزار رد شد.") from exc
        except ScannerUnavailableError as exc:
            logger.error("Malware scanner unavailable: %s", exc)
            raise ServiceUnavailableError(
                "بررسی امنیتی فایل در حال حاضر ممکن نیست. بعداً دوباره تلاش کنید.", code="malware_scanner_unavailable"
            ) from exc

    def _rejection_error(self, index: int, rejection: UploadRejectedError) -> AppError:
        if rejection.status_code == 413:
            return PayloadTooLargeError(rejection.message, code=rejection.code, details={"file_index": index})
        return ValidationFailedError({f"files.{index}": [rejection.message]}, code=rejection.code)

    # ------------------------------------------------------------------ queries
    def list_for_shipment(self, actor: Actor, shipment_id: uuid.UUID, page: int, per_page: int) -> Page[Document]:
        shipment = self._shipments.get_entity(actor, shipment_id)
        return self._documents.list_for_shipment(shipment.id, page, per_page)

    def open_content(self, document: Document) -> DocumentContent:
        """Open a stored file and verify size and checksum before it is served."""
        try:
            stream = self._storage.open(document.storage_path)
        except StoredFileMissingError as exc:
            logger.error("Stored file is missing", extra={"document_id": str(document.id)})
            raise IntegrityFailureError("فایل این سند در دسترس نیست.", code="document_file_missing") from exc
        except StorageError as exc:
            logger.error("Storage error while opening a document", extra={"document_id": str(document.id)})
            raise IntegrityFailureError("فایل این سند در دسترس نیست.", code="document_storage_error") from exc

        size = document.file_size
        if self._settings.verify_checksum_on_download:
            size, checksum = sha256_of_stream(stream)
            if size != document.file_size or not hmac.compare_digest(checksum, document.checksum):
                stream.close()
                logger.error("Document checksum mismatch", extra={"document_id": str(document.id)})
                self._audit.record_isolated("DOCUMENT_INTEGRITY_FAILURE", "document", document.id)
                raise IntegrityFailureError("یکپارچگی فایل این سند تأیید نشد.", code="document_integrity_error")
            stream.seek(0)
        return DocumentContent(document=document, stream=stream, size=size)

    def open_for_download(self, actor: Actor, document_id: uuid.UUID) -> DocumentContent:
        document = self._get(actor, document_id)
        content = self.open_content(document)
        try:
            with unit_of_work(self._session):
                self._audit.record(
                    "DOCUMENT_DOWNLOADED",
                    "document",
                    document.id,
                    actor_id=actor.user_id,
                    metadata={"shipment_id": str(document.shipment_id)},
                )
        except BaseException:
            content.stream.close()
            raise
        return content

    # ------------------------------------------------------------------ commands
    def upload(
        self,
        actor: Actor,
        shipment_id: uuid.UUID,
        files: Sequence[IncomingFile],
        customer_visible: bool | None = None,
    ) -> list[Document]:
        """Validate and store all files, or none of them."""
        shipment = self._shipments.get_entity(actor, shipment_id)
        self._shipments.ensure_writable(shipment)
        if not files:
            raise ValidationFailedError.single("files", "هیچ فایلی برای بارگذاری ارسال نشده است.", code="no_files")
        maximum = self._settings.max_files_per_upload
        if len(files) > maximum:
            raise ValidationFailedError.single(
                "files", f"در هر درخواست حداکثر {maximum} فایل قابل بارگذاری است.", code="too_many_files"
            )
        visible = self._settings.document_customer_visible_default if customer_visible is None else customer_visible

        staged: list[StagedUpload] = []
        committed_paths: list[str] = []
        try:
            for index, incoming in enumerate(files):
                try:
                    staged.append(self._stage(incoming))
                except UploadRejectedError as rejection:
                    self._audit.record_isolated(
                        "DOCUMENT_UPLOAD_REJECTED",
                        "shipment",
                        shipment_id,
                        actor_id=actor.user_id,
                        metadata={"reason": rejection.code, "filename": (incoming.filename or "")[:255]},
                    )
                    raise self._rejection_error(index, rejection) from rejection

            documents: list[Document] = []
            with unit_of_work(self._session):
                for item in staged:
                    storage_name = self._storage.new_storage_name()
                    storage_path = self._storage.commit(item.temp_path, storage_name)
                    committed_paths.append(storage_path)
                    document = Document(
                        shipment_id=shipment_id,
                        uploaded_by=actor.user_id,
                        original_name=item.original_name,
                        storage_name=storage_name,
                        storage_path=storage_path,
                        mime_type=item.file_type.mime_type,
                        extension=item.file_type.extension,
                        file_size=item.size,
                        checksum=item.checksum,
                        is_customer_visible=visible,
                    )
                    self._session.add(document)
                    documents.append(document)
                self._session.flush()
                for document in documents:
                    self._audit.record(
                        "DOCUMENT_UPLOADED",
                        "document",
                        document.id,
                        actor_id=actor.user_id,
                        metadata={
                            "shipment_id": str(shipment_id),
                            "original_name": document.original_name,
                            "file_size": document.file_size,
                            "checksum": document.checksum,
                            "is_customer_visible": document.is_customer_visible,
                        },
                    )
            return documents
        except BaseException:
            # Compensate: the database transaction rolled back, so remove files already moved.
            for path in committed_paths:
                self._storage.delete(path)
            raise
        finally:
            for item in staged:
                self._storage.discard_temp(item.temp_path)

    def set_customer_visibility(self, actor: Actor, document_id: uuid.UUID, visible: bool) -> Document:
        with unit_of_work(self._session):
            document = self._get(actor, document_id, for_update=True)
            self._shipments.ensure_writable(document.shipment)
            if document.is_customer_visible != visible:
                document.is_customer_visible = visible
                self._audit.record(
                    "DOCUMENT_VISIBILITY_CHANGED",
                    "document",
                    document.id,
                    actor_id=actor.user_id,
                    metadata={"shipment_id": str(document.shipment_id), "is_customer_visible": visible},
                )
        return document

    def delete(self, actor: Actor, document_id: uuid.UUID) -> None:
        """Soft-delete: the row is kept for the audit trail and disappears from every API."""
        with unit_of_work(self._session):
            document = self._get(actor, document_id, for_update=True)
            self._shipments.ensure_writable(document.shipment)
            document.deleted_at = utcnow()
            document.deleted_by = actor.user_id
            storage_path = document.storage_path
            purge = self._settings.document_purge_file_on_delete
            self._audit.record(
                "DOCUMENT_DELETED",
                "document",
                document.id,
                actor_id=actor.user_id,
                metadata={
                    "shipment_id": str(document.shipment_id),
                    "original_name": document.original_name,
                    "checksum": document.checksum,
                    "file_purged": purge,
                },
            )
        if purge:
            try:
                self._storage.delete(storage_path)
            except (StorageError, OSError):
                logger.exception("Could not purge the file of a deleted document")
