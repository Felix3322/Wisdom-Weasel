from __future__ import annotations

import os
import signal
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PID_FILE = ROOT / "demo_service.pid"


def main() -> int:
    if not PID_FILE.exists():
        print("No pid file found.")
        return 1

    pid = int(PID_FILE.read_text(encoding="utf-8").strip())

    try:
        if os.name == "nt":
            import subprocess

            subprocess.run(["taskkill", "/PID", str(pid), "/F"], check=True)
        else:
            os.kill(pid, signal.SIGTERM)
    except Exception as e:
        print(f"Failed to stop PID {pid}: {e}")
        return 2

    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass

    print(f"Stopped PID {pid}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
