#!/usr/bin/env python3
"""Failure-boundary helpers only; not evidence of literal rendering in Windows."""
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

import text_window_acceptance as acceptance
import text_window_fixture as fixture

real_source_inventory = fixture.source_inventory


class TextWindowHelperTests(unittest.TestCase):
    endpoint = "http://127.0.0.1:12345/literal-probe"

    def setUp(self):
        # These helpers test identity comparisons, not repository disk speed or
        # a specific checkout. Native acceptance still hashes the real sources.
        for name, value in (("source_revision", "a" * 40), ("source_inventory", {"controlled-source": "b" * 64})):
            owner = patch.object(fixture, name, return_value=value)
            owner.start()
            self.addCleanup(owner.stop)

    def test_external_or_ambiguous_counter_endpoints_rejected(self):
        for value in ("https://example.invalid/literal-probe", "http://localhost:123/literal-probe",
                      self.endpoint + "?x", "http://user@127.0.0.1:123/literal-probe", "http://127.0.0.1/literal-probe"):
            with self.assertRaises(ValueError):
                fixture.declaration(value)

    def test_tampered_archive_cannot_be_adopted_by_updating_plan_hash(self):
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="text-window-fixture-test-", dir=parent) as temporary:
            root = Path(temporary) / "inputs"
            plan = fixture.generate(root, self.endpoint)
            archive = root / plan["archive"]["path"]
            archive.unlink()
            manifest = fixture.declaration(self.endpoint)
            manifest["permissions"].append("ui.web")
            fixture.write_archive(archive, {"plugin.json": fixture.json_bytes(manifest)})
            plan["archive"]["sha256"] = fixture.sha256(archive)
            (root / "plan.json").write_bytes(fixture.json_bytes(plan))
            with self.assertRaisesRegex(ValueError, "content changed"):
                fixture.load_plan(root)

    def test_source_inventory_uses_one_deadline_for_host_and_streamed_third_party(self):
        with patch.object(fixture, "host_source_inventory", return_value={}) as host, \
                patch.object(fixture.time, "monotonic", side_effect=[0, 301]), \
                patch.object(fixture.subprocess, "run") as command:
            with self.assertRaisesRegex(TimeoutError, "300 seconds"):
                real_source_inventory()
            host.assert_called_once_with(deadline=300)
            command.assert_not_called()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "third_party/data.bin"
            source.parent.mkdir()
            source.write_bytes(b"controlled input")
            result = SimpleNamespace(stdout=b"third_party/data.bin\0")
            with patch.object(fixture, "ROOT", root), \
                    patch.object(fixture, "host_source_inventory", return_value={}), \
                    patch.object(fixture.subprocess, "run", return_value=result), \
                    patch.object(fixture.time, "monotonic", side_effect=[0, 0, 0, 301]):
                with self.assertRaisesRegex(TimeoutError, "300 seconds"):
                    real_source_inventory()

    def test_run_source_is_reusable_at_new_revision_but_rejects_later_drift(self):
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="text-window-fixture-test-", dir=parent) as temporary:
            root = Path(temporary) / "inputs"
            with patch.object(fixture, "source_revision", return_value="1" * 40):
                plan = fixture.generate(root, self.endpoint)
                self.assertEqual(plan["sourceCommit"], "1" * 40)
                self.assertEqual(fixture.load_plan(root), plan)
            with patch.object(fixture, "source_revision", return_value="2" * 40):
                with self.assertRaisesRegex(ValueError, "identity changed"):
                    fixture.load_plan(root)
            with patch.object(fixture, "source_revision", return_value="1" * 40), patch.object(fixture, "source_inventory", return_value={}):
                with self.assertRaisesRegex(ValueError, "identity changed"):
                    fixture.load_plan(root)

    def observer(self):
        context = Mock()
        observer = acceptance.PassiveRequests(SimpleNamespace(contexts=[context]))
        page = SimpleNamespace(context=context)
        return observer, page

    def rows(self):
        return [{"url": acceptance.TEXT_URL, "method": "GET", "resourceType": "document"},
                {"url": acceptance.BRIDGE_URL, "method": "GET", "resourceType": "script"}]

    def test_empty_or_late_observer_is_failure(self):
        observer, page = self.observer()
        for rows in ([], self.rows()[1:]):
            observer.requests = [(page, row) for row in rows]
            with self.assertRaisesRegex(AssertionError, "missing original request"):
                observer.assert_page(page)
        observer.close()

    def test_other_context_and_extra_ipc_external_requests_are_failure(self):
        observer, page = self.observer()
        observer.requests = [(page, row) for row in self.rows()]
        page.context = Mock()
        with self.assertRaisesRegex(AssertionError, "outside pre-observed"):
            observer.assert_page(page)
        page.context = observer.contexts[0]
        for url in ("http://ipc.localhost/plugin%3Adeclarative-web%7Crequest", self.endpoint):
            observer.requests = [(page, row) for row in self.rows() + [{"url": url, "method": "POST", "resourceType": "fetch"}]]
            with self.assertRaises(AssertionError):
                observer.assert_page(page)
        observer.close()

    def test_dom_detects_entity_decoding_injection_and_extra_script(self):
        result = {"url": acceptance.TEXT_URL, "text": fixture.literal_text(self.endpoint), "bodyTags": ["PRE"],
                  "dangerous": 0, "injected": False, "scripts": [{"src": acceptance.BRIDGE_URL, "text": ""}],
                  "context": {"pluginID": fixture.PLUGIN_ID, "windowID": fixture.WINDOW_ID}}
        for key, value in (("text", result["text"].replace("&lt;", "<")), ("bodyTags", ["PRE", "SCRIPT"]),
                           ("dangerous", 1), ("injected", True), ("scripts", result["scripts"] + [{"src": "", "text": "alert(1)"}])):
            changed = copy.deepcopy(result)
            changed[key] = value
            with self.assertRaises(AssertionError):
                acceptance.assert_dom(changed, self.endpoint)

    def test_counter_failure_path_closes_thread_and_socket(self):
        counter = acceptance.Counter()
        try:
            counter.start()
            raise ValueError("controlled failure")
        except ValueError:
            pass
        finally:
            counter.close()
        self.assertTrue(counter.closed)
        self.assertFalse(counter.thread.is_alive())
        self.assertEqual(counter.server.fileno(), -1)

    def test_observer_ui_side_effects_fail_and_cleanup_removes_listeners(self):
        observer, page = self.observer()
        observer.requests = [(page, row) for row in self.rows()]
        dialog = Mock(type="alert", message="literal")
        observer.on_dialog(dialog)
        dialog.dismiss.assert_called_once()
        with self.assertRaises(AssertionError):
            observer.assert_page(page)
        observer.close()
        self.assertEqual(observer.contexts[0].remove_listener.call_count, 4)

    def test_first_identity_failure_survives_teardown_and_cleans_counter(self):
        from acceptance_driver import Reporter
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="text-window-fixture-test-", dir=parent) as temporary:
            root = Path(temporary)
            (root / "image").mkdir()
            args = SimpleNamespace(fixture_root=root / "inputs", artifact_root=root / "evidence", run_image=root / "image",
                host_identity=root / "identity.json", executable=root / "image/host.exe", app_local_data=root / "local/app.lithe.windows.host-acceptance",
                app_roaming_data=root / "roaming/app.lithe.windows.host-acceptance", webview_data=root / "runtime/webview2")
            driver = MagicMock()
            driver.owned_processes = {}
            driver.ACCEPTANCE_IDENTIFIER = "app.lithe.windows.host-acceptance"
            driver.sync_playwright.return_value.__exit__.side_effect = RuntimeError("observer teardown failed")
            counter = acceptance.Counter()
            reporter = Reporter()
            with patch.object(acceptance, "Counter", return_value=counter), patch.object(acceptance, "verify_host", side_effect=ValueError("first identity failure")), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "first identity failure"):
                    acceptance.run(args, driver, reporter)
            driver.AppSession.assert_not_called()
            self.assertTrue(counter.closed)
            self.assertFalse(counter.thread.is_alive())
            row = next(row for row in reporter.tests if row["name"].endswith(" / resource-invariance"))
            self.assertEqual(row["status"], "failed")
            failure = next(call.args[1] for call in driver.write_json.call_args_list if call.args[0].name == "first-failure.json")
            self.assertEqual(failure["message"], "first identity failure")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        return int(not result.wasSuccessful())
    if args.report is None:
        parser.error("--report is required")
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(TextWindowHelperTests):
        started = time.monotonic()
        status, details, code = "passed", "", None
        command = [sys.executable, "-B", str(Path(__file__).resolve()), "--case", "TextWindowHelperTests." + name]
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
        rows.append({"name": name, "suite": "plugin-host-acceptance / text-window-helpers-only", "status": status,
                     "durationMs": duration, "maxMs": 10_000, "details": details, "command": command, "exitCode": code})
        print(f"{status.upper()} {name} ({duration} ms) {details}", flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(fixture.json_bytes({"runner": "acceptance", "warnMs": 2000, "maxMs": 10_000, "tests": rows}))
    return int(any(row["status"] != "passed" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
