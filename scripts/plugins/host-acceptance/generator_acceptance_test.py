#!/usr/bin/env python3
"""Offline failure-boundary checks; these do not establish product acceptance."""
from __future__ import annotations

import argparse
import copy
from contextlib import nullcontext
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import generator_acceptance as acceptance
import generator_fixture as fixture


class GeneratorHelperTests(unittest.TestCase):
    url = "https://example.invalid/fixed-source.zip"
    opened = "fixed-source/README.md"

    def setUp(self):
        for name, value in (("source_revision", "a" * 40), ("source_inventory", {"controlled-source": "b" * 64})):
            owner = patch.object(fixture, name, return_value=value)
            owner.start()
            self.addCleanup(owner.stop)

    def test_fixture_keeps_complete_requires_and_all_step_kinds(self):
        manifest = fixture.declaration(self.url, self.opened)
        self.assertEqual(manifest["requires"], {"projectGenerators": 1})
        self.assertEqual(manifest["permissions"], ["project.generate"])
        self.assertEqual(manifest["vendor"]["signatureRequirement"], "none")
        steps = {step["kind"] for generator in manifest["projectGenerators"] for step in generator["steps"]}
        self.assertEqual(steps, {"files", "command", "archive"})
        self.assertNotIn("languageServers", manifest)

    def test_archive_credentials_plain_http_and_unsafe_open_files_are_rejected(self):
        for url in ("http://example.invalid/source.zip", "https://user:secret@example.invalid/source.zip",
                    self.url + "?token=private", self.url + "#fragment"):
            with self.assertRaises(ValueError):
                fixture.declaration(url, self.opened)
        for path in ("../README.md", "C:/README.md", "/README.md", "x\\README.md", "x//README.md", ""):
            with self.assertRaises(ValueError):
                fixture.declaration(self.url, path)

    def test_preflight_cannot_claim_native_execution_or_partial_requires(self):
        plan = {"requires": {"projectGenerators": 1, "buildProviders": 1}}
        result = acceptance.preflight(plan, {"projectGenerators": [1]})
        self.assertFalse(result["complete"])
        self.assertFalse(result["runtimeExecuted"])
        self.assertEqual(result["missingCapabilities"], ["buildProviders:1"])
        self.assertEqual(len(result["tests"]), len(acceptance.CASES))
        self.assertTrue(all(row["status"] == "skipped" for row in result["tests"]))

    def test_closed_capability_never_launches_or_writes_a_product_profile(self):
        driver = MagicMock()
        with patch.object(acceptance, "source_capabilities", return_value={}):
            with self.assertRaisesRegex(ValueError, "closed complete-package"):
                acceptance.run(SimpleNamespace(), driver, MagicMock(), {"requires": fixture.REQUIRES})
        driver.AppSession.assert_not_called()
        driver.sync_playwright.assert_not_called()

    def test_source_identity_mismatch_fails_before_product_launch(self):
        driver = MagicMock()
        plan = {"requires": fixture.REQUIRES, "sourceInventory": {"source": "first"}}
        args = SimpleNamespace(host_identity=Path("identity.json"), executable=Path("host.exe"))
        with patch.object(acceptance, "source_capabilities", return_value={"projectGenerators": [1]}), \
                patch.object(acceptance, "verify_host", return_value={"sourceInventory": {"source": "changed"}}):
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                acceptance.run(args, driver, MagicMock(), plan)
        driver.AppSession.assert_not_called()

    def test_ineffective_cancel_fails_before_natural_exit(self):
        now = [0]
        owner = SimpleNamespace(running=lambda: now[0] < fixture.COMMAND_TIMEOUT_SECONDS)
        def wait(predicate, description, seconds):
            self.assertEqual(seconds, fixture.CANCEL_OBSERVATION_SECONDS)
            now[0] += seconds
            if not predicate():
                raise TimeoutError(description)
        with self.assertRaisesRegex(TimeoutError, "cancelled generator"):
            acceptance.observe_cancelled(owner, wait, 0, now=lambda: now[0])
        self.assertLess(now[0], fixture.COMMAND_TIMEOUT_SECONDS)

    def test_close_requires_real_wizard_unmount_even_after_process_exit(self):
        owner = SimpleNamespace(running=lambda: False)
        def wait(predicate, description, seconds):
            if not predicate():
                raise TimeoutError(description)
        with self.assertRaisesRegex(TimeoutError, "wizard unmounted"):
            acceptance.observe_cancelled(owner, wait, 0, closed=lambda: False, now=lambda: 0)
        acceptance.observe_cancelled(owner, wait, 0, closed=lambda: True, now=lambda: 0)

    def test_aged_command_cannot_pass_cancellation_on_natural_timeout(self):
        owner, wait = MagicMock(), MagicMock()
        with self.assertRaisesRegex(TimeoutError, "too old"):
            acceptance.observe_cancelled(owner, wait, 0,
                now=lambda: fixture.COMMAND_TIMEOUT_SECONDS - fixture.CANCEL_OBSERVATION_SECONDS)
        wait.assert_not_called()
        owner.running.assert_not_called()

    def test_marker_pid_without_retained_product_ancestry_is_never_adopted(self):
        session = SimpleNamespace(root_owner=object(), owned_tree=[])
        driver = MagicMock()
        driver.capture_owned_tree.return_value = []
        with self.assertRaisesRegex(AssertionError, "retained product descendant"):
            acceptance.owned_marker_process(driver, session, 123)
        driver.remember_owned_process.assert_not_called()
        owner = MagicMock(pid=123)
        owner.running.return_value = True
        driver.capture_owned_tree.return_value = [owner]
        self.assertIs(acceptance.owned_marker_process(driver, session, 123), owner)

    def test_resource_snapshot_is_bound_to_launched_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "image"
            image.mkdir()
            executable = image / "host.exe"
            executable.write_bytes(b"not executed")
            args = SimpleNamespace(run_image=image, executable=executable,
                artifact_root=root / "evidence", app_local_data=root / "local", app_roaming_data=root / "roaming",
                webview_data=root / "webview2", fixture_root=root / "fixture", host_identity=root / "identity.json")
            acceptance.runtime_paths(args)
            args.run_image = root
            with self.assertRaisesRegex(ValueError, "exact snapshotted"):
                acceptance.runtime_paths(args)
            args.run_image, args.artifact_root = image, image / "evidence"
            with self.assertRaisesRegex(ValueError, "overlaps"):
                acceptance.runtime_paths(args)

    def test_shutdown_failure_retries_retained_owner_before_profile_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = SimpleNamespace(app_local_data=root / "local", app_roaming_data=root / "roaming", webview_data=root / "webview2")
            owner = MagicMock(pid=123)
            owner.running.side_effect = [True, False]
            driver = MagicMock(owned_processes={123: owner}, ACCEPTANCE_IDENTIFIER="controlled")
            session = MagicMock()
            session.stop.side_effect = RuntimeError("original quit failure")
            result = acceptance.cleanup_session(args, driver, session)
            self.assertEqual(result["survivors"], [])
            self.assertIn("original quit failure", result["errors"][0])
            driver.terminate_process_tree.assert_called_once_with(123)
            self.assertEqual(driver.safe_remove_owned_directory.call_count, 3)

    def test_survivor_or_unknown_inspection_retains_profiles(self):
        args = SimpleNamespace(app_local_data=Path("local"), app_roaming_data=Path("roaming"), webview_data=Path("webview2"))
        owner = MagicMock(pid=123)
        owner.running.side_effect = [True, OSError("inspection unavailable")]
        driver = MagicMock(owned_processes={123: owner}, ACCEPTANCE_IDENTIFIER="controlled")
        result = acceptance.cleanup_session(args, driver, None)
        self.assertEqual(result["survivors"], [123])
        self.assertTrue(result["errors"])
        driver.safe_remove_owned_directory.assert_not_called()

    def test_observer_entry_failure_still_cleans_and_preserves_first_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "image"
            image.mkdir()
            executable = image / "host.exe"
            executable.write_bytes(b"not executed")
            inputs = root / "inputs"
            (inputs / "projects").mkdir(parents=True)
            (inputs / "fixture.zip").write_bytes(b"not installed")
            plan = {"requires": fixture.REQUIRES, "sourceInventory": {"source": "fixed"},
                    "archiveReference": "reference.zip", "archiveInput": {"fixed": True},
                    "archive": {"path": "fixture.zip"}}
            args = SimpleNamespace(run_image=image, executable=executable, fixture_root=inputs,
                artifact_root=root / "evidence", app_local_data=root / "local",
                app_roaming_data=root / "roaming", webview_data=root / "webview2", host_identity=root / "identity.json")
            driver = MagicMock(owned_processes={})
            driver.sync_playwright.return_value.__enter__.side_effect = RuntimeError("original observer entry failure")
            reporter = SimpleNamespace(step=lambda *args: nullcontext())
            identity = {"sourceInventory": plan["sourceInventory"], "configSha256": "fixed"}
            with patch.object(acceptance, "source_capabilities", return_value={"projectGenerators": [1]}), \
                    patch.object(acceptance, "verify_host", return_value=identity), \
                    patch.object(acceptance, "source_inventory", return_value=plan["sourceInventory"]), \
                    patch.object(acceptance, "sha256", return_value="fixed"), \
                    patch.object(acceptance, "require_x64_executable"), \
                    patch.object(acceptance, "snapshot_resources", return_value={}), \
                    patch.object(acceptance, "cleanup_session", return_value={"survivors": [], "errors": [], "profilesAbsent": True}) as cleanup:
                with self.assertRaisesRegex(RuntimeError, "original observer entry failure"):
                    acceptance.run(args, driver, reporter, plan)
            cleanup.assert_called_once_with(args, driver, None)
            driver.AppSession.assert_not_called()

    def test_changed_package_cannot_be_adopted_by_updating_its_receipt(self):
        parent = fixture.ROOT / ".artifacts/plugin-host-acceptance"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="generator-fixture-test-", dir=parent) as temporary:
            root = Path(temporary) / "inputs"
            plan = fixture.generate(root, self.url, self.opened)
            self.assertEqual(fixture.load_plan(root), plan)
            archive = root / plan["archive"]["path"]
            archive.unlink()
            changed = copy.deepcopy(fixture.declaration(self.url, self.opened))
            changed["requires"]["buildProviders"] = 1
            fixture.write_archive(archive, {"plugin.json": fixture.json_bytes(changed), **fixture.FILES})
            plan["archive"]["sha256"] = fixture.sha256(archive)
            (root / "plan.json").write_bytes(fixture.json_bytes(plan))
            with self.assertRaisesRegex(ValueError, "content changed"):
                fixture.load_plan(root)

    def test_downloaded_archive_must_match_each_fixed_reference_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reference = root / "reference.zip"
            fixture.write_archive(reference, {"source/README.md": b"fixed input\n"})
            receipt = {"repository": "example/source", "commit": "a" * 40, "url": self.url,
                "license": "MIT", "zipSha256": fixture.sha256(reference), "zipBytes": reference.stat().st_size,
                "entries": 1, "expandedBytes": 12, "expectedOpenFile": "source/README.md"}
            receipt_path = root / "receipt.json"
            receipt_path.write_bytes(fixture.json_bytes(receipt))
            self.assertEqual(fixture.archive_input(receipt_path, reference), receipt)
            target = root / "project"
            (target / "source").mkdir(parents=True)
            opened = target / "source/README.md"
            opened.write_bytes(b"fixed input\n")
            self.assertIn("source/README.md", fixture.verify_extracted_reference(reference, target))
            opened.write_bytes(b"changed output\n")
            with self.assertRaisesRegex(AssertionError, "archive bytes differ"):
                fixture.verify_extracted_reference(reference, target)
            reference.write_bytes(b"replaced container")
            with self.assertRaisesRegex(ValueError, "reference bytes changed"):
                fixture.archive_input(receipt_path, reference)

    def test_staging_and_partial_output_are_observable_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            acceptance.assert_clean_projects(root, "Cancelled")
            stage = root / ".Cancelled.lithe-creating-owner"
            stage.mkdir()
            with self.assertRaisesRegex(AssertionError, "staging"):
                acceptance.assert_clean_projects(root, "Cancelled")
            stage.rmdir()
            (root / "Cancelled").mkdir()
            with self.assertRaisesRegex(AssertionError, "partial output"):
                acceptance.assert_clean_projects(root, "Cancelled")


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
    for name in unittest.defaultTestLoader.getTestCaseNames(GeneratorHelperTests):
        started = time.monotonic()
        status, details, code = "passed", "", None
        command = [sys.executable, "-B", str(Path(__file__).resolve()), "--case", "GeneratorHelperTests." + name]
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
        rows.append({"name": name, "suite": "plugin-host-acceptance / generator-helpers-only", "status": status,
                     "durationMs": duration, "maxMs": 10_000, "details": details, "command": command, "exitCode": code})
        print(f"{status.upper()} {name} ({duration} ms) {details}", flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(fixture.json_bytes({"runner": "acceptance", "warnMs": 2000, "maxMs": 10_000, "tests": rows}))
    return int(any(row["status"] != "passed" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
