#!/usr/bin/env python3
"""Deterministic driver self-checks, explicitly separate from product acceptance."""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import settings_functions_acceptance as acceptance
import settings_functions_fixture as fixture


class SettingsFunctionsHelperTests(unittest.TestCase):
    def setUp(self):
        # Tests own their temporary directories and never touch installed data.
        temporary = tempfile.TemporaryDirectory(prefix="lithe-settings-functions-helper-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root_patch = patch.object(fixture, "ROOT", self.directory)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.root = self.directory / ".artifacts/plugin-host-acceptance/settings-functions-fixture"
        # Only Git revision lookup is substituted; package bytes/paths are real.
        self.revision_patch = patch.object(fixture, "source_revision", return_value="a" * 40)
        self.revision_patch.start()
        self.addCleanup(self.revision_patch.stop)
        self.plan = fixture.generate(self.root)

    def test_package_bytes_are_deterministic_and_sdk_is_not_claimed_executed(self):
        other = self.root.with_name("settings-functions-fixture-second")
        second = fixture.generate(other)
        self.assertEqual(second, self.plan)
        self.assertEqual(fixture.load_plan(self.root), self.plan)
        self.assertFalse(self.plan["sdk"]["used"])
        for asset in self.plan["archives"].values():
            self.assertEqual((self.root / asset["path"]).read_bytes(), (other / asset["path"]).read_bytes())

    def test_archive_tampering_is_a_failure(self):
        path = self.root / self.plan["archives"]["1.0.0"]["path"]
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "digest/version"):
            fixture.load_plan(self.root)

    def test_archived_text_settings_accept_the_exercised_default_empty_and_saved_values(self):
        for asset in self.plan["archives"].values():
            with zipfile.ZipFile(self.root / asset["path"]) as archive:
                declaration = json.loads(archive.read("plugin.json"))
            for setting in declaration["settings"]:
                # settings:2 requires a whole-value pattern, including for an
                # explicit empty override. Check the actual installed inputs.
                self.assertEqual(setting["type"], "text")
                for value in (setting["default"], "", "global-value", "window-one", "window-two", "project-reload", "global-reload"):
                    with self.subTest(version=asset["version"], setting=setting["id"], value=value):
                        self.assertIsNotNone(re.fullmatch(setting["pattern"], value))
                        self.assertLessEqual(len(value), setting["maxLength"])

    def test_plan_from_another_checkout_revision_is_rejected(self):
        with patch.object(fixture, "source_revision", return_value="b" * 40):
            with self.assertRaisesRegex(ValueError, "identity changed"):
                fixture.load_plan(self.root)

    def test_manifest_rewrite_cannot_forge_a_supported_external_package(self):
        self.plan["requires"]["buildProviders"] = 1
        (self.root / "settings-functions-plan.json").write_text(json.dumps(self.plan), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "identity changed"):
            fixture.load_plan(self.root)

    def test_generator_refuses_overwrite_and_resettable_or_external_roots(self):
        with self.assertRaises(FileExistsError):
            fixture.generate(self.root)
        for output in (self.directory / "external", self.root.parent / "run-image", self.root.parent / "packages"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                fixture.generate(output)

    def test_controlled_arguments_refuse_missing_identity_and_other_lanes(self):
        parser = argparse.ArgumentParser()
        args = SimpleNamespace(settings_functions_fixture_root=self.root, settings_functions_host_identity=None,
                               marketplace=False, lsp_lifecycle=False, build_fixture_root=None)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            acceptance.validate_arguments(parser, args)
        args.settings_functions_host_identity = self.directory / "identity.json"
        acceptance.validate_arguments(parser, args)
        for other in ("marketplace", "lsp_lifecycle", "build_fixture_root"):
            setattr(args, other, True)
            with self.subTest(other=other), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                acceptance.validate_arguments(parser, args)
            setattr(args, other, False)

    def test_snapshot_includes_empty_directories_and_detects_all_mutations(self):
        resources = self.directory / "resources"
        resources.mkdir()
        (resources / "empty").mkdir()
        (resources / "tool.bin").write_bytes(b"baseline")
        before = acceptance.snapshot_resources(resources)
        self.assertIn("empty/", before)
        (resources / "empty").rmdir()
        (resources / "tool.bin").write_bytes(b"mutated")
        (resources / "new").write_bytes(b"new")
        after = acceptance.snapshot_resources(resources)
        self.assertEqual(acceptance.resource_diff(before, after), {"added": ["new"], "removed": ["empty/"], "changed": ["tool.bin"]})
        with self.assertRaisesRegex(AssertionError, "read-only resource mutation"):
            acceptance.assert_resources(before, after)

    def test_snapshot_enforces_entry_and_byte_budgets(self):
        with self.assertRaisesRegex(ValueError, "entry budget"):
            acceptance.snapshot_resources(self.root, max_files=1)
        with self.assertRaisesRegex(ValueError, "byte budget"):
            acceptance.snapshot_resources(self.root, max_bytes=1)

    def test_snapshot_refuses_junction_and_does_not_hash_external_files(self):
        if os.name != "nt":
            self.skipTest("Windows junction boundary")
        import _winapi
        link = self.directory / "junction"
        _winapi.CreateJunction(str(self.root), str(link))
        self.addCleanup(lambda: link.rmdir() if link.exists() else None)
        with self.assertRaisesRegex(ValueError, "link/reparse"):
            acceptance.snapshot_resources(link)
        with self.assertRaisesRegex(ValueError, "link or junction"):
            fixture.generate(link / "settings-functions-fixture-escaped")

    def test_wait_deadline_uses_injected_clock_without_sleep(self):
        clock = [0]
        polls = []
        def pump():
            clock[0] += 1
        with self.assertRaisesRegex(TimeoutError, "settings/functions deadline: stalled native reload"):
            acceptance.wait_for(lambda: polls.append(clock[0]), "stalled native reload", now=lambda: clock[0], pump=pump, seconds=3)
        self.assertEqual(polls, [0, 1, 2])

    def test_wait_propagates_product_failure_and_never_turns_it_into_pending(self):
        def failed():
            raise ValueError("native command failed")
        pump = Mock()
        with self.assertRaisesRegex(ValueError, "native command failed"):
            acceptance.wait_for(failed, "failure", now=lambda: 0, pump=pump)
        pump.assert_not_called()

    def test_host_mismatch_rejects_before_product_restart(self):
        executable = self.directory / "host.exe"
        executable.write_bytes(b"controlled identity bytes, never launched")
        path = self.directory / "identity.json"
        identity = {"identifier": "app.lithe.windows.host-acceptance", "rustTarget": "x86_64-pc-windows-msvc",
                    "gitRevision": self.plan["sourceCommit"], "executableSha256": fixture.sha256(executable)}
        path.write_text(json.dumps(identity), encoding="utf-8")
        self.assertEqual(acceptance.verify_host(path, executable, self.plan), identity)
        for key, bad in (("identifier", "production"), ("rustTarget", "aarch64-pc-windows-msvc"),
                         ("gitRevision", "b" * 40), ("executableSha256", "0" * 64)):
            with self.subTest(key=key):
                path.write_text(json.dumps({**identity, key: bad}), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "identity does not match"):
                    acceptance.verify_host(path, executable, self.plan)

    def test_complete_sample_remains_blocked_even_when_controlled_settings_are_supported(self):
        rows = acceptance.pending_cases(self.plan, acceptance.source_capabilities())
        self.assertEqual(len(rows), len(acceptance.SETTINGS_CASES) + len(acceptance.FUNCTION_CASES) + 2)
        self.assertTrue(all(row["status"] == "skipped" for row in rows))
        for row in rows:
            if row["name"].startswith("real-functions"):
                self.assertIn("buildProviders:1", row["details"])
                self.assertIn("buildSystems:1", row["details"])
                self.assertIn("publisher-signed", row["details"])
                self.assertIn("No existing dedicated native acceptance seam", row["details"])

    def test_preflight_pending_is_nonzero_and_never_native_pass(self):
        report = self.directory / "pending.json"
        with patch.object(sys, "argv", ["preflight", "--fixture-root", str(self.root), "--report", str(report)]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(acceptance.main(), 2)
        parsed = json.loads(report.read_text(encoding="utf-8"))
        self.assertFalse(parsed["complete"])
        self.assertTrue(all(row["status"] == "skipped" for row in parsed["tests"]))

    def test_preflight_input_failure_has_failed_json_and_nonzero_exit(self):
        (self.root / "settings-functions-plan.json").write_text("broken", encoding="utf-8")
        report = self.directory / "failure.json"
        with patch.object(sys, "argv", ["preflight", "--fixture-root", str(self.root), "--report", str(report)]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(acceptance.main(), 1)
        rows = json.loads(report.read_text(encoding="utf-8"))["tests"]
        self.assertEqual(rows[0]["status"], "failed")
        self.assertIn("JSONDecodeError", rows[0]["details"])

    def test_failure_restores_observer_and_preserves_resource_failure_report(self):
        # Exercise the real Reporter and lane finally without starting a host.
        from acceptance_driver import Reporter
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence",
                               run_image=self.directory / "image", app_local_data=self.directory / "app",
                               settings_functions_host_identity=self.directory / "identity.json", executable=self.directory / "host.exe")
        args.run_image.mkdir()
        reporter, driver, page = Reporter(), Mock(), Mock()
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        page.evaluate.return_value = {"calls": [], "dropped": 0}
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, reporter, Mock(return_value=(page, Mock())))
        def fail_install(_):
            (args.run_image / "illegal-runtime-write").write_bytes(b"mutation")
            raise RuntimeError("controlled install failure")
        lane.install = fail_install
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "read-only resource mutation"):
                lane.run()
        self.assertTrue(any(".stop()" in call.args[0] for call in page.evaluate.call_args_list))
        self.assertEqual([row["status"] for row in reporter.tests], ["failed", "passed", "failed"])
        self.assertIn("controlled install failure", reporter.tests[0]["details"])
        self.assertIn("read-only resource mutation", reporter.tests[2]["details"])

    def test_failure_cleanup_attempts_both_observers(self):
        from acceptance_driver import Reporter
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence",
                               run_image=self.directory / "image", app_local_data=self.directory / "app",
                               settings_functions_host_identity=self.directory / "identity.json", executable=self.directory / "host.exe")
        args.run_image.mkdir()
        page, second = Mock(), Mock()
        page.evaluate.return_value = second.evaluate.return_value = {"calls": [], "dropped": 0}
        driver = Mock()
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, Reporter(), Mock(return_value=(page, Mock())))
        lane.second = second
        lane.install = Mock(side_effect=RuntimeError("install failed"))
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "install failed"):
                lane.run()
        for observer in (page, second):
            self.assertTrue(any(".stop()" in call.args[0] for call in observer.evaluate.call_args_list))
        def first_failed(expression):
            raise RuntimeError("closed first window")
        page.evaluate.side_effect = first_failed
        second.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "closed first window"):
            lane.stop_observers()
        self.assertTrue(any(".stop()" in call.args[0] for call in second.evaluate.call_args_list))

    def test_pending_registration_keeps_existing_failures(self):
        name = "controlled-settings / trusted-install-review"
        reporter = SimpleNamespace(tests=[{"name": name, "status": "failed"}])
        acceptance.record_unreached_cases(reporter, self.plan)
        self.assertEqual(sum(row["name"] == name for row in reporter.tests), 1)
        self.assertEqual(reporter.tests[0]["status"], "failed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case")
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        return 0 if result.wasSuccessful() else 1
    if args.report is None:
        parser.error("--report is required")
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(SettingsFunctionsHelperTests):
        started = time.monotonic()
        status, details = "passed", ""
        try:
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "--case", f"SettingsFunctionsHelperTests.{name}"],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
            if result.returncode:
                status, details = "failed", result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            status, details = "timeout", "driver self-check exceeded its 10 second process deadline"
        duration = round((time.monotonic() - started) * 1000, 3)
        if duration >= 10_000:
            status, details = "timeout", details + "; hard per-case timing budget exceeded"
        rows.append({"name": name, "suite": "plugin-host-acceptance / settings-functions-helpers", "status": status,
                     "durationMs": duration, "maxMs": 10_000, "details": details})
        print(f"{status.upper()} {name} ({duration} ms)", flush=True)
        if details:
            print(details, file=sys.stderr)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"runner": "acceptance", "warnMs": 2_000, "maxMs": 10_000, "tests": rows}, indent=2) + "\n", encoding="utf-8")
    return 1 if any(row["status"] != "passed" for row in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
