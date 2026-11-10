"""Optional malware-scanner integration (e.g. ClamAV's ``clamdscan``).

Enabled by setting ``MALWARE_SCAN_COMMAND``. The command is executed without a
shell; ``{path}`` is replaced by the file to scan (or the path is appended).
Exit status follows the ClamAV convention: 0 = clean, 1 = infected, anything
else = scanner failure. Failures reject the upload (fail closed).
"""

from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

PATH_PLACEHOLDER = "{path}"
_EXIT_CLEAN = 0
_EXIT_INFECTED = 1


class MalwareDetectedError(RuntimeError):
    """The scanner flagged the file."""


class ScannerUnavailableError(RuntimeError):
    """The scanner could not be run or reported an error."""


class MalwareScanner:
    def __init__(self, command: str, timeout_seconds: int) -> None:
        self._arguments = shlex.split(command)
        if not self._arguments:
            raise ValueError("MALWARE_SCAN_COMMAND is empty.")
        self._timeout = timeout_seconds

    def scan(self, path: Path) -> None:
        if any(PATH_PLACEHOLDER in argument for argument in self._arguments):
            arguments = [argument.replace(PATH_PLACEHOLDER, str(path)) for argument in self._arguments]
        else:
            arguments = [*self._arguments, str(path)]
        try:
            # The command comes from operator configuration and runs without a shell.
            completed = subprocess.run(  # noqa: S603
                arguments, capture_output=True, timeout=self._timeout, check=False
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ScannerUnavailableError(str(exc)) from exc
        if completed.returncode == _EXIT_CLEAN:
            return
        if completed.returncode == _EXIT_INFECTED:
            raise MalwareDetectedError(path.name)
        raise ScannerUnavailableError(f"scanner exited with status {completed.returncode}")
