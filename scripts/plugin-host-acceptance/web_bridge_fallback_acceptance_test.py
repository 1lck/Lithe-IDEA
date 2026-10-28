#!/usr/bin/env python3
"""Bounded helper checks; none is evidence of native IPC fallback."""
from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

import web_bridge_fallback_acceptance as acceptance
import web_bridge_fallback_fixture as fixture


class WebFallbackHelperTests(unittest.TestCase):
    def event(self):
        return {"requestId": "request-1", "frameId": "plugin-frame", "request": {
            "url": acceptance.IPC_URL, "method": "POST", "headers": {"Tauri-Callback": "12", "Tauri-Error": "13", "Tauri-Invoke-Key": "ephemeral"},
            "postData": json.dumps({"method": "ui.setState", "params": {"state": {"nonce": "nonce"}}, "generation": 1})}}

    def test_only_exact_owned_state_post_can_be_failed(self):
        event = self.event()
        self.assertEqual(acceptance.classify_request(event, "plugin-frame", "nonce", False), ("fail", None))
        changes = [("frameId", "other"), ("method", "GET"), ("url", acceptance.IPC_URL + "?extra=1"),
                   ("postData", "invalid"), ("postData", json.dumps({"method": "ui.getState", "params": None, "generation": 1})),
                   ("headers", {}), ("postData", json.dumps({"method": "ui.setState", "params": {"state": {"nonce": "other"}}, "generation": 1}))]
        for key, value in changes:
            changed = copy.deepcopy(event)
            (changed if key == "frameId" else changed["request"])[key] = value
            decision, error = acceptance.classify_request(changed, "plugin-frame", "nonce", False)
            self.assertEqual(decision, "continue")
            self.assertIsNotNone(error)
        self.assertEqual(acceptance.classify_request(event, "plugin-frame", "nonce", True)[0], "continue")

    def test_local_static_is_released_but_other_ipc_or_network_fails_acceptance(self):
        event = self.event()
        for url, rejected in ((acceptance.ORIGIN + "/ui/index.html", False),
                              ("http://ipc.localhost/plugin%3Aother%7Crequest", True),
                              (acceptance.ORIGIN + ".evil.test/a", True), ("https://example.invalid/a", True)):
            event["request"]["url"] = url
            decision, error = acceptance.classify_request(event, "plugin-frame", "nonce", False)
            self.assertEqual(decision, "continue")
            self.assertEqual(error is not None, rejected)

    def test_only_exact_native_cors_preflight_is_released_without_command(self):
        event = self.event()
        event["request"] = {"url": acceptance.IPC_URL, "method": "OPTIONS", "headers": {
            "Origin": acceptance.ORIGIN, "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type,tauri-callback,tauri-error,tauri-invoke-key"}}
        self.assertEqual(acceptance.classify_request(event, "plugin-frame", "nonce", False), ("continue", None))
        self.assertIsNotNone(acceptance.classify_request(event, "plugin-frame", "nonce", True)[1])
        event["request"]["headers"]["Origin"] = "http://other.invalid"
        self.assertIsNotNone(acceptance.classify_request(event, "plugin-frame", "nonce", False)[1])

    def test_fault_fails_once_and_never_generalizes_second_request(self):
        session = Mock()
        fault = acceptance.FetchFault(session, "plugin-frame", "nonce")
        with patch.object(acceptance, "cdp_send") as send:
            fault.on_paused(self.event())
            fault.assert_one()
            second = self.event()
            second["requestId"] = "request-2"
            fault.on_paused(second)
        self.assertEqual([call.args[1] for call in send.call_args_list], ["Fetch.failRequest", "Fetch.continueRequest"])
        self.assertEqual(fault.failed, 1)
        self.assertFalse(fault.paused)
        with self.assertRaises(AssertionError):
            fault.assert_one()
        self.assertNotIn("ephemeral", json.dumps(fault.records))

    def test_failed_release_is_retained_until_disable_and_detach(self):
        session = Mock()
        fault = acceptance.FetchFault(session, "plugin-frame", "nonce")
        fault.enabled = True
        session._impl_obj.detach = Mock(side_effect=lambda: __import__("asyncio").sleep(0))
        session._sync.side_effect = lambda coroutine: __import__("asyncio").run(coroutine)
        with patch.object(acceptance, "cdp_send", side_effect=RuntimeError("send failed")):
            fault.on_paused(self.event())
        self.assertEqual(fault.paused, {"request-1"})
        def send(_session, method, params=None):
            if method == "Fetch.continueRequest":
                raise RuntimeError("release failed")
        with patch.object(acceptance, "cdp_send", side_effect=send) as calls:
            with self.assertRaisesRegex(RuntimeError, "release failed"):
                fault.close()
        self.assertEqual([call.args[1] for call in calls.call_args_list], ["Fetch.continueRequest", "Fetch.disable"])
        session._impl_obj.detach.assert_called_once()
        self.assertFalse(fault.enabled)
        self.assertFalse(fault.paused)

    def test_disable_failure_still_detaches_and_is_not_success(self):
        session = Mock()
        session._impl_obj.detach = Mock(side_effect=lambda: __import__("asyncio").sleep(0))
        session._sync.side_effect = lambda coroutine: __import__("asyncio").run(coroutine)
        fault = acceptance.FetchFault(session, "plugin-frame", "nonce")
        fault.enabled = True
        with patch.object(acceptance, "cdp_send", side_effect=RuntimeError("disable failed")):
            with self.assertRaisesRegex(RuntimeError, "disable failed"):
                fault.close()
        session._impl_obj.detach.assert_called_once()
        self.assertTrue(fault.enabled)

    def test_transport_mutation_and_unsettled_native_callbacks_are_rejected(self):
        descriptor = {"writable": False, "configurable": False}
        before = {"descriptors": {key: dict(descriptor) for key in ("lithe", "invoke", "ipc", "postMessage")},
                  "url": acceptance.ORIGIN + "/ui/index.html", "bridgeFrozen": True, "pattern": "brownfield",
                  "callbacks": {"isMap": True, "size": 0}}
        acceptance.assert_transport(before, before)
        for changed in ("callbacks", "descriptors"):
            after = copy.deepcopy(before)
            if changed == "callbacks":
                after[changed]["size"] = 1
            else:
                after[changed]["invoke"]["writable"] = True
            with self.assertRaises(AssertionError):
                acceptance.assert_transport(before, after)

    def test_host_architecture_comes_from_real_pe_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "controlled.exe"
            header = bytearray(64)
            header[:2] = b"MZ"
            header[60:64] = (64).to_bytes(4, "little")
            executable.write_bytes(header + b"PE\0\0\x64\x86")
            self.assertEqual(acceptance.require_x64_executable(executable), "IMAGE_FILE_MACHINE_AMD64")
            executable.write_bytes(header + b"PE\0\0\x64\xaa")
            with self.assertRaisesRegex(ValueError, "not Windows x64"):
                acceptance.require_x64_executable(executable)

    def test_complete_unsigned_static_fixture_rejects_repacked_extra_content(self):
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="web-bridge-fallback-fixture-test-", dir=parent) as temporary:
            root = Path(temporary) / "inputs"
            fixture.generate(root)
            fixture.load_plan(root)
            self.assertEqual(fixture.declaration()["requires"], {"ui": 2})
            self.assertEqual(set(fixture.declaration()["permissions"]), {"ui.contribute", "ui.web"})
            archive = root / "web-fallback.zip"
            with __import__("zipfile").ZipFile(archive, "a") as output:
                output.writestr("program.exe", b"not a static page")
            with self.assertRaisesRegex(ValueError, "identity changed"):
                fixture.load_plan(root)

    def test_first_identity_failure_survives_cleanup_and_cannot_pass_runtime_resources(self):
        from acceptance_driver import Reporter
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="web-bridge-fallback-fixture-test-", dir=parent) as temporary:
            root = Path(temporary)
            fixture.generate(root / "inputs")
            (root / "image").mkdir()
            args = SimpleNamespace(fixture_root=root / "inputs", artifact_root=root / "evidence", run_image=root / "image",
                host_identity=root / "identity.json", executable=root / "image/host.exe", app_local_data=root / "local/app.lithe.windows.host-acceptance",
                app_roaming_data=root / "roaming/app.lithe.windows.host-acceptance", webview_data=root / "runtime/webview2")
            driver = MagicMock()
            driver.owned_processes = {}
            driver.ACCEPTANCE_IDENTIFIER = "app.lithe.windows.host-acceptance"
            driver.sync_playwright.return_value.__exit__.side_effect = RuntimeError("observer teardown failed")
            def persist(path, value):
                if path.name == "console.json":
                    raise OSError("evidence write failed")
            driver.write_json.side_effect = persist
            reporter = Reporter()
            with patch.object(acceptance, "verify_host", side_effect=ValueError("first identity failure")), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "first identity failure"):
                    acceptance.run(args, driver, reporter)
            driver.AppSession.assert_not_called()
            driver.safe_remove_owned_directory.assert_called()
            row = next(row for row in reporter.tests if row["name"].endswith(" / resource-invariance"))
            self.assertEqual(row["status"], "failed")
            self.assertIn("native workflow/shutdown did not complete", row["details"])
            failure = next(call.args[1] for call in driver.write_json.call_args_list if call.args[0].name == "first-failure.json")
            self.assertEqual(failure["message"], "first identity failure")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        return 0 if result.wasSuccessful() else 1
    if args.report is None:
        parser.error("--report is required")
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(WebFallbackHelperTests):
        started = time.monotonic()
        status, details, code = "passed", "", None
        command = [sys.executable, "-B", str(Path(__file__).resolve()), "--case", "WebFallbackHelperTests." + name]
        try:
            result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
            code = result.returncode
            if code:
                status, details = "failed", result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            status, details = "timeout", "helper exceeded its ten-second subprocess deadline"
        duration = round((time.monotonic() - started) * 1000, 3)
        if duration >= 10_000:
            status = "timeout"
        rows.append({"name": name, "suite": "plugin-host-acceptance / web-fallback-helpers-only", "status": status,
                     "durationMs": duration, "maxMs": 10_000, "details": details, "command": command, "exitCode": code})
        print(f"{status.upper()} {name} ({duration} ms) {details}", flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(fixture.json_bytes({"runner": "acceptance", "warnMs": 2000, "maxMs": 10_000, "tests": rows}))
    return int(any(row["status"] != "passed" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
