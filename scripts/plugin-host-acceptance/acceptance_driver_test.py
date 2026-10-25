#!/usr/bin/env python3
"""Bounded unit checks for the native acceptance driver's process owner."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from acceptance_driver import OwnedProcess, fixture_command_matches, process_exists, run_bounded_process


def run_case(name, action, tests):
    started = time.monotonic()
    try:
        action()
        status = "passed"
        details = ""
    except Exception as error:  # noqa: BLE001 - the report must retain any failure.
        status = "failed"
        details = f"{type(error).__name__}: {error}"
    tests.append(
        {
            "name": name,
            "suite": "plugin-host-acceptance / driver",
            "status": status,
            "durationMs": round((time.monotonic() - started) * 1000, 3),
            "details": details,
            "maxMs": 10_000,
        }
    )
    if status != "passed":
        raise AssertionError(details)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    tests = []

    def completes():
        result = run_bounded_process(
            [sys.executable, "-c", "print('bounded-ok')"], timeout_seconds=5
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "bounded-ok"

    def timeout_cleans_tree():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="lithe-host-driver-test-", dir=args.report.parent
        ) as directory:
            pid_file = Path(directory) / "child.pid"
            script = (
                "import pathlib,subprocess,sys,time; "
                "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                f"pathlib.Path({str(pid_file)!r}).write_text(str(p.pid)); "
                "time.sleep(60)"
            )
            try:
                run_bounded_process([sys.executable, "-c", script], timeout_seconds=1)
            except TimeoutError:
                pass
            else:
                raise AssertionError("bounded process did not time out")
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            assert pid_file.exists(), "fixture child PID was not recorded"
            child_pid = int(pid_file.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 5
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            assert not process_exists(child_pid), f"timed-out child {child_pid} survived cleanup"

    def retained_handle_ignores_changed_pid():
        first = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        second = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        owner = None
        try:
            owner = OwnedProcess.capture(first.pid)
            assert owner is not None
            # Model PID reuse without depending on the OS actually recycling it.
            owner.pid = second.pid
            owner.terminate()
            first.wait(timeout=3)
            assert second.poll() is None, "termination followed a recycled PID instead of the retained handle"
        finally:
            if owner is not None:
                owner.close()
            for process in (first, second):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)

    def mismatched_identity_is_not_owned():
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        original = rejected = None
        try:
            original = OwnedProcess.capture(process.pid)
            assert original is not None
            rejected = OwnedProcess.capture(process.pid, {
                "CreationTime": original.creation_time - 100,
                "ExecutablePath": original.executable,
            })
            assert rejected is None
            rejected = OwnedProcess.capture(process.pid, {
                "CreationTime": original.creation_time,
                "ExecutablePath": original.executable + ".unrelated",
            })
            assert rejected is None
            assert process.poll() is None
        finally:
            if original is not None:
                original.close()
            if rejected is not None:
                rejected.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)

    def fixture_arguments_are_exact():
        root = Path(tempfile.gettempdir()) / "lithe fixture state"
        valid = subprocess.list2cmdline(["node.exe", "C:/fixture/fake-lsp-server.mjs", "--state-dir", str(root)])
        assert fixture_command_matches(valid, root)
        assert not fixture_command_matches(valid.replace("fake-lsp-server.mjs", "other-fake-lsp-server.mjs"), root)
        sibling = subprocess.list2cmdline(["node.exe", "C:/fixture/fake-lsp-server.mjs", "--state-dir", str(root) + "-unrelated"])
        assert not fixture_command_matches(sibling, root)

    try:
        run_case("bounded process captures a successful child", completes, tests)
        run_case("timeout terminates the owned process tree", timeout_cleans_tree, tests)
        run_case("termination targets a retained handle despite a changed PID", retained_handle_ignores_changed_pid, tests)
        run_case("creation-time and executable mismatches reject ownership", mismatched_identity_is_not_owned, tests)
        run_case("fixture arguments reject substring lookalikes", fixture_arguments_are_exact, tests)
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(
                {
                    "runner": "acceptance",
                    "warnMs": 2_000,
                    "maxMs": 10_000,
                    "tests": tests,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
