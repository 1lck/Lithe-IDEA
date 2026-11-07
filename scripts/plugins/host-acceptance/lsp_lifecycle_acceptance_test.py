#!/usr/bin/env python3
"""Bounded unit and real fixture-protocol checks, never native Lithe evidence."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import acceptance_driver as driver
from lsp_lifecycle_acceptance import (
    InitializeGate, canonical_file_uri, event_offsets, events_after, matching_did_open,
)


SERVER = Path(__file__).with_name("fake-lsp-server.mjs").resolve()


def reject(action, expected=ValueError):
    try:
        action()
    except expected:
        return
    raise AssertionError(f"expected {expected.__name__}")


def append(path, event):
    with path.open("ab") as stream:
        stream.write((json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8"))


def did_open(uri, **extra):
    return {"event": "message", "method": "textDocument/didOpen", "pid": 10,
            "fixtureVersion": "v1", "uri": uri, "documentVersion": 1, **extra}


def offsets_and_partial_records():
    with tempfile.TemporaryDirectory(prefix="lithe-lsp-events-") as temporary:
        root = Path(temporary)
        workspace = root / "workspace"
        workspace.mkdir()
        events = workspace / "events.jsonl"
        uri = (root / "中文 file.litheaccept").as_uri()
        append(events, did_open(uri))
        offsets = event_offsets(root)
        assert events_after(root, offsets) == [], "an old didOpen satisfied a new action"
        fresh = did_open(uri, documentVersion=2)
        with events.open("ab") as stream:
            stream.write(json.dumps(fresh).encode("utf-8"))
        assert events_after(root, offsets) == [], "a partial record counted as complete"
        with events.open("ab") as stream:
            stream.write(b"\n")
        rows = events_after(root, offsets)
        assert len(rows) == 1 and rows[0]["documentVersion"] == 2
        assert rows[0]["stateDirectory"] == str(workspace.resolve())
        assert matching_did_open(rows, "v1", uri, {10}, lambda pid: pid == 10) == rows[0]
        events.write_bytes(b"")
        reject(lambda: events_after(root, offsets))


def wrong_events_cannot_satisfy_attachment():
    uri = (Path(tempfile.gettempdir()) / "lithe fixture.litheaccept").resolve().as_uri()
    valid = did_open(uri)
    for change in ({"method": "textDocument/didClose"}, {"event": "server-started"},
                   {"fixtureVersion": "old"}, {"uri": uri + "-other"},
                   {"uri": "https://example.invalid/file"}, {"documentVersion": -1},
                   {"documentVersion": None}):
        assert matching_did_open([{**valid, **change}], "v1", uri, {10}, lambda _: True) is None, change
    assert matching_did_open([valid], "v1", uri, set(), lambda _: True) is None
    assert matching_did_open([valid], "v1", uri, {10}, lambda _: False) is None
    assert canonical_file_uri("file://remote.invalid/share/file") is None
    assert canonical_file_uri(uri + "?query=unrelated") is None


def new_state_logs_are_scoped():
    with tempfile.TemporaryDirectory(prefix="lithe-lsp-scope-") as temporary:
        parent = Path(temporary)
        root, other = parent / "plugin-state", parent / "other-plugin"
        root.mkdir()
        other.mkdir()
        offsets = event_offsets(root)
        workspace = root / "new-workspace"
        workspace.mkdir()
        uri = (parent / "one.litheaccept").as_uri()
        append(other / "events.jsonl", did_open(uri, pid=999))
        append(workspace / "events.jsonl", did_open(uri, pid=10))
        rows = events_after(root, offsets)
        assert len(rows) == 1 and rows[0]["pid"] == 10
        # A directory junction must not smuggle another plugin's evidence into
        # this root. Creating the junction is privilege-free on Windows.
        link = root / "outside"
        result = driver.run_bounded_process(["cmd", "/c", "mklink", "/J", str(link), str(other)], 5)
        assert result.returncode == 0, result.stderr
        try:
            reject(lambda: events_after(root, offsets))
        finally:
            link.rmdir()


def gate_failure_releases_only_owned_state():
    with tempfile.TemporaryDirectory(prefix="lithe-lsp-gate-") as temporary:
        parent = Path(temporary)
        root, workspace = parent / "state", parent / "state" / "workspace"
        workspace.mkdir(parents=True)
        unrelated = workspace / "other-state.txt"
        unrelated.write_text("preserve", encoding="utf-8")
        gate = InitializeGate(workspace, root)
        try:
            with gate:
                assert json.loads(gate.path.read_text(encoding="utf-8"))["token"] == gate.token
                raise RuntimeError("controlled failure")
        except RuntimeError:
            pass
        assert not gate.path.exists() and gate.release_path.exists()
        assert unrelated.read_text(encoding="utf-8") == "preserve"
        reject(lambda: InitializeGate(parent, root))
        reject(lambda: InitializeGate(root, root))


def frame(message):
    body = json.dumps(message).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


def response(path):
    body = path.read_bytes()
    if b"\r\n\r\n" not in body:
        return None
    header, payload = body.split(b"\r\n\r\n", 1)
    size = int(header.split(b":", 1)[1])
    return json.loads(payload[:size]) if len(payload) >= size else None


def fixture_protocol(interrupt=False):
    with tempfile.TemporaryDirectory(prefix="lithe-lsp-protocol-") as temporary:
        root = Path(temporary)
        workspace = root / "workspace"
        workspace.mkdir()
        stdout, stderr = root / "stdout.bin", root / "stderr.log"
        handles = []
        process = None
        try:
            with InitializeGate(workspace, root) as gate, stdout.open("wb") as output, stderr.open("wb") as errors:
                process = subprocess.Popen(
                    [shutil.which("node"), str(SERVER), "--state-dir", str(workspace), "--fixture-version", "gate-fixture"],
                    stdin=subprocess.PIPE, stdout=output, stderr=errors, creationflags=driver.CREATE_NO_WINDOW)
                owner = driver.remember_owned_process(process.pid)
                assert owner is not None
                handles.append(owner)
                driver.wait_until(lambda: list(workspace.glob("child-active-*.json")), 5, "the real fixture child")
                handles.extend(driver.capture_owned_tree(owner))
                assert len(handles) >= 2
                process.stdin.write(frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}))
                process.stdin.flush()
                offsets = {}
                gated = driver.wait_until(lambda: next((event for event in events_after(root, offsets)
                                                       if event.get("event") == "initialize-gated"), None),
                                          5, "the protocol initialize gate")
                assert gated["token"] == gate.token and response(stdout) is None
                if interrupt:
                    process.stdin.close()
                    process.wait(timeout=3)
                    assert process.returncode == 0
                    stopped = events_after(root, offsets)[-1]
                    assert stopped["event"] == "server-stopped" and stopped["reason"] == "stdin-end"
                else:
                    gate.release()
                    initialized = driver.wait_until(lambda: response(stdout), 5, "the gated initialize response")
                    assert initialized["id"] == 1
                    uri = (root / "中文 document.litheaccept").as_uri()
                    process.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
                        "textDocument": {"uri": uri, "version": 7, "text": "fixture"}}}))
                    process.stdin.flush()
                    event = driver.wait_until(lambda: matching_did_open(
                        events_after(root, offsets), "gate-fixture", uri, {owner.pid}, lambda _: owner.running()),
                        5, "the URI and version in the real fixture event")
                    assert event["documentVersion"] == 7
                    process.stdin.write(frame({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
                                        + frame({"jsonrpc": "2.0", "method": "exit"}))
                    process.stdin.flush()
                    process.wait(timeout=3)
                    assert process.returncode == 0
        finally:
            if process is not None:
                try:
                    driver.terminate_process_tree(process.pid, timeout_seconds=3)
                    process.wait(timeout=3)
                finally:
                    if process.stdin is not None and not process.stdin.closed:
                        process.stdin.close()
                    for handle in set(handles):
                        assert not handle.running(), f"fixture process {handle.pid} survived cleanup"
                        handle.close()
                        if driver.owned_processes.get(handle.pid) is handle:
                            del driver.owned_processes[handle.pid]


CASES = {
    "event offsets reject old and partial records": offsets_and_partial_records,
    "didOpen requires the exact marker URI version and current owned PID": wrong_events_cannot_satisfy_attachment,
    "new logs remain inside the exact plugin state scope": new_state_logs_are_scoped,
    "failed gate actions release their owned state without deleting unrelated files": gate_failure_releases_only_owned_state,
    "real fixture initialize waits for release then records didOpen URI and version": fixture_protocol,
    "interrupted initialize closes its gate and reclaims the real fixture tree": lambda: fixture_protocol(True),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case", choices=list(CASES))
    args = parser.parse_args()
    if args.case:
        CASES[args.case]()
        return 0
    if not args.report:
        parser.error("--report is required")
    tests = []
    for name in CASES:
        started = time.monotonic()
        status, details = "passed", ""
        try:
            result = driver.run_bounded_process([sys.executable, "-B", str(Path(__file__).resolve()), "--case", name], 15)
            if result.returncode:
                status, details = "failed", result.stderr or result.stdout
        except Exception as error:
            status, details = "failed", f"{type(error).__name__}: {error}"
        tests.append({"name": name, "suite": "lsp-lifecycle-acceptance / fixture-unit", "status": status,
                      "durationMs": round((time.monotonic() - started) * 1000, 3), "maxMs": 15000, "details": details})
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 2000, "maxMs": 15000, "tests": tests})
        print(f"{status.upper()} {name}", flush=True)
    root = Path(__file__).resolve().parents[3]
    generator = root / ".agents/skills/write-stable-tests/scripts/generate-test-report.mjs"
    code = "import {writeTestReportArtifacts} from '" + generator.as_uri() + "';writeTestReportArtifacts(process.argv[1]);"
    artifacts = driver.run_bounded_process(["node", "--input-type=module", "-e", code, str(args.report.resolve())], 15)
    assert artifacts.returncode == 0, artifacts.stderr
    return 1 if any(test["status"] != "passed" for test in tests) else 0


if __name__ == "__main__":
    raise SystemExit(main())
