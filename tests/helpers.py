"""Helpers shared by the config and integration tests: running the real
PowerShell scripts (black-box, exactly as an operator would), and small
HTTP / Docker utilities."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPO_ROOT / "scripts"


def powershell_exe() -> str:
    """pwsh (PowerShell 7, CI on Linux) or Windows PowerShell 5.1."""
    for candidate in ("pwsh", "powershell"):
        found = shutil.which(candidate)
        if found:
            return found
    raise RuntimeError("PowerShell not found (need pwsh or powershell on PATH)")


def run_script(name: str, *args: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    """Run scripts/<name>.ps1 with the current environment (GATEWAY_* vars
    select which gateway / state dir the script operates on)."""
    cmd = [powershell_exe(), "-NoProfile", "-NonInteractive"]
    if os.name == "nt":
        cmd += ["-ExecutionPolicy", "Bypass"]
    cmd += ["-File", str(SCRIPTS / f"{name}.ps1"), *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO_ROOT)


def poll_until(predicate: Callable[[], bool], timeout: float = 30.0, interval: float = 0.5, desc: str = "") -> None:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except Exception as exc:  # noqa: BLE001 - keep polling, report the last error
            last = exc
        time.sleep(interval)
    raise AssertionError(f"timed out after {timeout}s waiting for {desc}" + (f" (last error: {last})" if last else ""))


def docker(*args: str, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
