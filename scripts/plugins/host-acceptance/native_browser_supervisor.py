#!/usr/bin/env python3
"""Own the controlled browser worker through the existing gated Windows Job."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import threading
import time

from vcs_move_diagnostic import WindowsJob, supervised


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-ms", required=True, type=int)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--force-owner-exit-on", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if sys.platform != "win32" or not command or not 1 <= args.timeout_ms <= 600_000:
        parser.error("requires Windows, an explicit command and a 1..600000ms timeout")
    stop = threading.Event()
    watcher = None
    if args.force_owner_exit_on is not None:
        def forced_exit():
            deadline = time.monotonic() + args.timeout_ms / 1000
            # Controlled lifecycle fault: kill-on-job-close must clean descendants
            # even when this owner cannot publish its ordinary cleanup proof.
            while not stop.is_set() and time.monotonic() < deadline:
                if args.force_owner_exit_on.is_file():
                    os._exit(37)
                stop.wait(0.01)
        watcher = threading.Thread(target=forced_exit, daemon=True)
        watcher.start()
    try:
        # WindowsJob creates a trusted Python bootstrap, assigns its native
        # handle, then sends release. Node cannot spawn a driver before assignment.
        result = supervised(command, args.timeout_ms / 1000, args.log, WindowsJob)
        temporary = args.result.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2), encoding="utf-8")
        temporary.replace(args.result)
        return 0 if result["status"] == "passed" else 1
    finally:
        stop.set()
        if watcher is not None:
            watcher.join(timeout=1)


if __name__ == "__main__":
    raise SystemExit(main())
