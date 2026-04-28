from __future__ import annotations

import os
import subprocess
import sys
import time
import urllib.request
import webbrowser
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VENV_PYTHON = ROOT / ".venv" / "Scripts" / "python.exe"
MAIN_FILE = ROOT / "html_demo" / "main.py"
STDOUT_LOG = ROOT / "demo_service_stdout.log"
STDERR_LOG = ROOT / "demo_service_stderr.log"
PID_FILE = ROOT / "demo_service.pid"
HOST = "127.0.0.1"
PORT = 8080
URL = f"http://{HOST}:{PORT}/"


def wait_until_ready(timeout_seconds: int = 90) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(URL, timeout=3) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(1)
    return False


def main() -> int:
    if not VENV_PYTHON.exists():
        print(f"[ERROR] venv python not found: {VENV_PYTHON}")
        return 1
    if not MAIN_FILE.exists():
        print(f"[ERROR] main.py not found: {MAIN_FILE}")
        return 1

    env = os.environ.copy()
    env["IME_DEMO_HOST"] = HOST
    env["IME_DEMO_PORT"] = str(PORT)

    creationflags = 0
    if os.name == "nt":
        creationflags |= getattr(subprocess, "DETACHED_PROCESS", 0)
        creationflags |= getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)

    with open(STDOUT_LOG, "ab") as stdout, open(STDERR_LOG, "ab") as stderr:
        proc = subprocess.Popen(
            [str(VENV_PYTHON), "-u", str(MAIN_FILE)],
            cwd=str(ROOT),
            stdout=stdout,
            stderr=stderr,
            env=env,
            creationflags=creationflags,
            close_fds=True,
        )

    PID_FILE.write_text(str(proc.pid), encoding="utf-8")
    print(f"Starting backend... PID={proc.pid}")
    print(f"Logs: {STDOUT_LOG}")

    if wait_until_ready():
        print(f"Backend ready: {URL}")
        webbrowser.open(URL)
        return 0

    print("Backend did not become ready in time.")
    print(f"Check logs:\n- {STDOUT_LOG}\n- {STDERR_LOG}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
