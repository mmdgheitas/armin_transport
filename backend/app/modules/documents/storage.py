"""Private file storage for shipment documents.

Files live outside any web root under server-generated random names without an
extension, so they can never be requested or executed directly. Every path is
resolved against the storage root to rule out directory traversal.
"""

from __future__ import annotations

import contextlib
import os
import secrets
import tempfile
import time
from pathlib import Path
from typing import BinaryIO

TEMP_DIRECTORY_NAME = ".tmp"
_PRIVATE_DIRECTORY_MODE = 0o700
_PRIVATE_FILE_MODE = 0o600


class StorageError(RuntimeError):
    """The storage backend could not complete an operation."""


class StoredFileMissingError(StorageError):
    """Metadata exists but the file is not present in storage."""


class DocumentStorage:
    def __init__(self, root: Path) -> None:
        self._root = root

    @property
    def root(self) -> Path:
        return self._root

    @property
    def _temp_directory(self) -> Path:
        return self._root / TEMP_DIRECTORY_NAME

    def ensure_ready(self) -> None:
        self._root.mkdir(parents=True, exist_ok=True, mode=_PRIVATE_DIRECTORY_MODE)
        self._temp_directory.mkdir(exist_ok=True, mode=_PRIVATE_DIRECTORY_MODE)

    def create_temp_file(self) -> tuple[BinaryIO, Path]:
        """Create an exclusive, owner-only temporary file inside the storage root."""
        self.ensure_ready()
        descriptor, name = tempfile.mkstemp(prefix="upload-", suffix=".part", dir=self._temp_directory)
        return os.fdopen(descriptor, "wb"), Path(name)

    @staticmethod
    def new_storage_name() -> str:
        """Random 256-bit name; unrelated to the original file name."""
        return secrets.token_hex(32)

    def commit(self, temp_path: Path, storage_name: str) -> str:
        """Move a validated temporary file to its final location; returns the relative path."""
        relative_path = f"{storage_name[:2]}/{storage_name[2:4]}/{storage_name}"
        target = self._root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True, mode=_PRIVATE_DIRECTORY_MODE)
        if target.exists():
            raise StorageError("Storage name collision.")
        os.replace(temp_path, target)  # atomic: both paths are on the storage file system
        os.chmod(target, _PRIVATE_FILE_MODE)
        return relative_path

    def resolve(self, storage_path: str) -> Path:
        """Return the absolute path of a stored file, refusing anything outside the root."""
        root = self._root.resolve()
        candidate = (root / storage_path).resolve()
        if candidate == root or not candidate.is_relative_to(root):
            raise StorageError("Storage path escapes the storage root.")
        return candidate

    def open(self, storage_path: str) -> BinaryIO:
        path = self.resolve(storage_path)
        try:
            return path.open("rb")
        except FileNotFoundError as exc:
            raise StoredFileMissingError(storage_path) from exc
        except OSError as exc:
            raise StorageError(str(exc)) from exc

    def delete(self, storage_path: str) -> bool:
        try:
            self.resolve(storage_path).unlink()
        except FileNotFoundError:
            return False
        return True

    @staticmethod
    def discard_temp(path: Path) -> None:
        with contextlib.suppress(FileNotFoundError):
            path.unlink()

    def is_writable(self) -> bool:
        """Readiness probe: can a file be created and removed in the storage root?"""
        try:
            handle, path = self.create_temp_file()
            handle.close()
            self.discard_temp(path)
        except OSError:
            return False
        return True

    def purge_stale_temp_files(self, max_age_seconds: int = 3600) -> int:
        """Remove leftovers of interrupted uploads (maintenance task)."""
        if not self._temp_directory.is_dir():
            return 0
        threshold = time.time() - max_age_seconds
        removed = 0
        for entry in self._temp_directory.iterdir():
            with contextlib.suppress(OSError):
                if entry.is_file() and entry.stat().st_mtime < threshold:
                    entry.unlink()
                    removed += 1
        return removed
