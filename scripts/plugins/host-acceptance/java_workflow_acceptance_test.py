#!/usr/bin/env python3
"""Bounded helper regressions; none of these tests establish Java product success."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import java_workflow_acceptance as acceptance
import java_workflow_inputs as inputs


def core(sequence, command, payload, data, *, session="java-session"):
    return {"sequence": sequence, "command": "core_execute", "settled": True,
            "core": {"command": command, "payload": {"sessionId": session, **payload}},
            "value": {"ok": True, "data": data}}


class JavaWorkflowHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = {"id": inputs.PLUGIN_ID, "version": "1.1.0", "requires": inputs.REQUIRES,
                         "vendor": {"signatureRequirement": "publisherPackage"},
                         "projectGenerators": [{"id": "java"}],
                         "languageServers": [{"languageID": "java", "hostIntegration": {"id": "jdt"}}]}
        jdk = self.root / "jdk"
        (jdk / "bin").mkdir(parents=True)
        (jdk / "bin/java.exe").write_bytes(b"helper-only, never executed")
        (jdk / "bin/javac.exe").write_bytes(b"helper-only compiler, never executed")
        self.plan = {"schemaVersion": 1, "kind": "windows-plain-java-workflow", "sourceCommit": "a" * 40,
                     "sourceInventory": {"source": "fixed"},
                     "jdk": {"home": str(jdk), "version": "21.0.1", "javaSha256": inputs.sha256(jdk / "bin/java.exe"),
                             "javacSha256": inputs.sha256(jdk / "bin/javac.exe")},
                     "project": {"name": "Java Acceptance", "sourcePath": "src/Main.java", "mainClass": "Main", "configurationName": "Main"}}
        self.package()

    def package(self):
        raw = inputs.json_bytes(self.manifest)
        archive = self.root / "java.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("plugin.json", raw)
        self.plan["package"] = {"archive": {"path": str(archive), "sha256": inputs.sha256(archive)},
                                "requires": copy.deepcopy(self.manifest["requires"]), "manifestSha256": hashlib.sha256(raw).hexdigest()}

    def test_preflight_keeps_full_requires_and_every_product_case_pending(self):
        result = acceptance.preflight(self.plan, {key: [level] for key, level in inputs.REQUIRES.items()})
        self.assertEqual(result["requires"], inputs.REQUIRES)
        self.assertEqual(result["blocked"], ["packageEvidence missing", "workspaceEvidence missing"])
        self.assertFalse(result["runtimeExecuted"])
        self.assertFalse(result["plainJavaPassed"])
        self.assertFalse(result["complete"])
        self.assertEqual(len(result["tests"]), len(inputs.CASES) + len(inputs.PENDING))
        self.assertTrue(all(row["status"] == "skipped" for row in result["tests"]))

    def test_removing_package_trust_cannot_turn_complete_archive_into_a_fixture(self):
        self.manifest["requires"] = dict(inputs.REQUIRES)
        del self.manifest["requires"]["packageTrust"]
        self.package()
        with self.assertRaisesRegex(ValueError, "complete official Java"):
            inputs.validate_plan(self.plan)

    def test_candidate_receipt_is_blocked_even_with_passing_helper_status(self):
        receipt = self.root / "candidate.json"
        receipt.write_bytes(inputs.json_bytes({"status": "passed", "productionTrusted": False,
            "packageSha256": self.plan["package"]["archive"]["sha256"],
            "manifestSha256": self.plan["package"]["manifestSha256"], "evidence": []}))
        self.plan["packageEvidence"] = {"path": str(receipt), "sha256": inputs.sha256(receipt)}
        _, blocked = inputs.validate_plan(self.plan)
        self.assertIn("candidate/incomplete", blocked[0])
        driver = MagicMock()
        with self.assertRaisesRegex(ValueError, "prerequisites blocked"):
            acceptance.run(SimpleNamespace(), driver, MagicMock(), self.plan)
        driver.AppSession.assert_not_called()
        driver.sync_playwright.assert_not_called()

    def test_receipt_cannot_reference_mutated_original_evidence(self):
        evidence = self.root / "evidence.json"
        evidence.write_text("original")
        receipt = self.root / "receipt.json"
        receipt.write_bytes(inputs.json_bytes({"status": "passed", "productionTrusted": True,
            "packageSha256": self.plan["package"]["archive"]["sha256"],
            "manifestSha256": self.plan["package"]["manifestSha256"],
            "evidence": [{"path": str(evidence), "sha256": inputs.sha256(evidence)}]}))
        self.plan["packageEvidence"] = {"path": str(receipt), "sha256": inputs.sha256(receipt)}
        evidence.write_text("changed")
        with self.assertRaisesRegex(ValueError, "input bytes changed"):
            inputs.validate_plan(self.plan)

    def test_changed_real_jdk_identity_fails_before_native_launch(self):
        (Path(self.plan["jdk"]["home"]) / "bin/java.exe").write_bytes(b"replaced")
        with self.assertRaisesRegex(ValueError, "fixed JDK"):
            inputs.validate_plan(self.plan)

    def test_different_final_source_identity_never_starts_product(self):
        driver = MagicMock()
        args = SimpleNamespace(host_identity=self.root / "identity.json", executable=self.root / "host.exe")
        with patch.object(acceptance, "validate_plan", return_value=(self.manifest, [])), \
                patch.object(acceptance, "source_capabilities", return_value={key: [value] for key, value in inputs.REQUIRES.items()}), \
                patch.object(acceptance, "verify_host", return_value={"sourceInventory": {"source": "another"}}):
            with self.assertRaisesRegex(ValueError, "source/config/x64 identity"):
                acceptance.run(args, driver, MagicMock(), self.plan)
        driver.AppSession.assert_not_called()

    def test_stale_evidence_is_preserved_before_starting_any_suite_owner(self):
        plan = self.root / "plan.json"
        plan.write_bytes(inputs.json_bytes(self.plan))
        evidence = self.root / "existing-evidence"
        evidence.mkdir()
        sentinel = evidence / "suite-owner.json"
        sentinel.write_text("original evidence", encoding="utf-8")
        arguments = ["java_workflow_acceptance.py", "--plan", str(plan), "--report", str(self.root / "report.json"),
                     "--artifact-root", str(evidence)]
        for key in ("host-identity", "executable", "run-image", "app-local-data", "app-roaming-data", "webview-data"):
            arguments.extend(["--" + key, str(self.root / key)])
        with patch.object(sys, "argv", arguments):
            with self.assertRaises(SystemExit) as error:
                acceptance.main()
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "original evidence")
        self.assertFalse((self.root / "report.json").exists())

    def test_graceful_cleanup_precedes_playwright_teardown_after_start_failure(self):
        events = []
        image = self.root / "image"
        image.mkdir()
        args = SimpleNamespace(host_identity=self.root / "identity.json", executable=image / "host.exe", run_image=image,
                               plan=self.root / "inputs/plan.json", artifact_root=self.root / "runtime-evidence",
                               app_local_data=self.root / "local", app_roaming_data=self.root / "roaming", webview_data=self.root / "webview2")
        driver = MagicMock(owned_processes={}, ACCEPTANCE_IDENTIFIER="controlled")
        session = driver.AppSession.return_value
        session.start.side_effect = RuntimeError("original start failure")
        session.stop.side_effect = lambda **kwargs: events.append("graceful-stop")
        driver.sync_playwright.return_value.__exit__.side_effect = lambda *args: events.append("playwright-exit")
        def remove(path, parent, name):
            self.assertIn(path, (args.app_local_data, args.app_roaming_data, args.webview_data))
            if path.exists():
                shutil.rmtree(path)
        driver.safe_remove_owned_directory.side_effect = remove
        reporter = SimpleNamespace(step=lambda *args, **kwargs: nullcontext())
        identity = {"sourceInventory": self.plan["sourceInventory"], "configSha256": "fixed"}
        with patch.object(acceptance, "validate_plan", return_value=(self.manifest, [])), \
                patch.object(acceptance, "source_capabilities", return_value={key: [value] for key, value in inputs.REQUIRES.items()}), \
                patch.object(acceptance, "verify_host", return_value=identity), \
                patch.object(acceptance, "source_inventory", return_value=self.plan["sourceInventory"]), \
                patch.object(acceptance, "sha256", return_value="fixed"), \
                patch.object(acceptance, "runtime_paths"), \
                patch.object(acceptance, "require_x64_executable"), \
                patch.object(acceptance, "snapshot_resources", return_value={}):
            with self.assertRaisesRegex(RuntimeError, "original start failure"):
                acceptance.run(args, driver, reporter, self.plan)
        self.assertEqual(events, ["graceful-stop", "playwright-exit"])
        self.assertFalse(args.app_local_data.exists())
        self.assertFalse(args.app_roaming_data.exists())

    def test_saved_disk_bytes_without_product_save_notification_are_insufficient(self):
        source = Path("C:/example/src/Main.java")
        content = inputs.java_source("saved")
        save = {"sequence": 4, "command": "save_document_file", "args": {"path": str(source), "content": content},
                "settled": True, "value": {"status": "saved"}}
        sync = core(3, "lsp.syncDocument", {"uri": "file:///C:/example/src/Main.java", "text": content}, {"documentVersion": 2})
        calls = [save, sync]
        self.assertIsNone(inputs.saved_and_synced(calls, source, content, "java-session"))
        notified = core(5, "lsp.saveDocument", {"uri": "file:///C:/example/src/Main.java", "text": content}, {})
        calls.append(notified)
        observed = inputs.saved_and_synced(calls, source, content, "java-session")
        self.assertEqual(observed["documentVersion"], 2)
        notified["core"]["payload"]["sessionId"] = "previous-workspace"
        self.assertIsNone(inputs.saved_and_synced(calls, source, content, "java-session"))

    def test_prepare_completion_must_match_operation_session_saved_source_and_order(self):
        source = Path("C:/example/src/Main.java")
        request = core(8, "java.prepareLaunch", {"sourcePath": str(source), "mainClass": "Main"}, {"operationId": "actual-operation"})
        completion = {"type": "requestCompleted", "operationId": "old-operation", "result": {"kind": "ready", "target": {"classPaths": ["classes"]}}}
        drain = core(9, "lsp.waitEvents", {}, {"events": [completion]})
        observe = lambda: inputs.completed_preparation([request, drain], source, "Main", "java-session", 6, "ready")
        self.assertIsNone(observe())
        completion["operationId"] = "actual-operation"
        drain["core"]["payload"]["sessionId"] = "old-workspace"
        self.assertIsNone(observe())
        drain["core"]["payload"]["sessionId"] = "java-session"
        self.assertEqual(observe()["operationId"], "actual-operation")
        self.assertIsNone(inputs.completed_preparation([request, drain], source, "Main", "java-session", 8, "ready"))
        request["core"]["payload"]["sourcePath"] = "C:/other/src/Main.java"
        self.assertIsNone(observe())

    def test_actual_compile_failure_cannot_pass_as_ready(self):
        source = Path("C:/example/src/Main.java")
        request = core(1, "java.prepareLaunch", {"sourcePath": str(source), "mainClass": "Main"}, {"operationId": "build"})
        drain = core(2, "lsp.waitEvents", {}, {"events": [{"type": "requestCompleted", "operationId": "build",
                                                       "result": {"kind": "buildFailed", "failure": {"code": "javaBuildFailed"}}}]})
        with self.assertRaisesRegex(AssertionError, "actual java.prepareLaunch"):
            inputs.completed_preparation([request, drain], source, "Main", "java-session", 0, "ready")
        observed = inputs.completed_preparation([request, drain], source, "Main", "java-session", 0, "buildFailed")
        self.assertEqual(observed["result"]["failure"]["code"], "javaBuildFailed")

    def test_ready_requires_real_plugin_owned_server_for_this_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / "plugin"
            package.mkdir()
            start = core(1, "lsp.startServer", {"pluginId": inputs.PLUGIN_ID, "rootUri": "file:///C:/example",
                         "executablePath": str(package / "runtime/java.exe"), "arguments": [str(package / "launcher.jar")]}, {"sessionId": "java-session"})
            ready = core(2, "lsp.waitEvents", {}, {"events": [{"type": "stateChanged", "state": "ready"}]})
            self.assertIsNotNone(inputs.ready_session([start, ready], Path("C:/example"), package))
            self.assertIsNone(inputs.ready_session([start, ready], Path("C:/other"), package))
            start["core"]["payload"]["executablePath"] = "C:/host/java.exe"
            start["core"]["payload"]["arguments"] = ["C:/host/launcher.jar"]
            with self.assertRaisesRegex(AssertionError, "admitted plugin resources"):
                inputs.ready_session([start, ready], Path("C:/example"), package)

    def test_dropped_or_unparseable_ipc_is_a_failure(self):
        for value in ({"calls": [], "dropped": 1, "errors": []}, {"calls": [], "dropped": 0, "errors": ["decode"]}):
            with self.assertRaisesRegex(AssertionError, "dropped"):
                inputs.assert_observer(value)

    def test_actual_launch_must_consume_selected_jdk_workspace_and_jdt_paths(self):
        launch = {"executable": "C:/jdk/bin/java.exe", "workingDirectory": "C:/example",
                  "arguments": ["-cp", "C:/example/bin;C:/dependency/a.jar", "Main"]}
        target = {"classPaths": ["C:/example/bin", "C:/dependency/a.jar"], "modulePaths": []}
        inputs.assert_actual_launch(launch, target, Path("C:/example"), Path("C:/jdk"))
        for changed in ({**launch, "executable": "node.exe"}, {**launch, "workingDirectory": "C:/old"},
                        {**launch, "arguments": ["-cp", "C:/stale/classes", "Main"]}):
            with self.assertRaises(AssertionError):
                inputs.assert_actual_launch(changed, target, Path("C:/example"), Path("C:/jdk"))

    def test_observer_preserves_real_callback_values_and_restores_transport(self):
        result = subprocess.run(["node", "--test", "--test-timeout=5000", str(Path(__file__).with_name("java_workflow_observer.test.mjs"))],
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=8)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        return int(not result.wasSuccessful())
    if args.report is None:
        parser.error("--report is required")
    rows = []
    deadline = time.monotonic() + 120
    for name in unittest.defaultTestLoader.getTestCaseNames(JavaWorkflowHelperTests):
        started = time.monotonic()
        status, details, code = "passed", "", None
        command = [sys.executable, "-B", str(Path(__file__).resolve()), "--case", "JavaWorkflowHelperTests." + name]
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Java helper suite exhausted its 120-second deadline")
            result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=min(10, remaining))
            code = result.returncode
            if code:
                status, details = "failed", result.stdout + result.stderr
        except (subprocess.TimeoutExpired, TimeoutError) as error:
            status, details = "timeout", str(error)
        duration = round((time.monotonic() - started) * 1000, 3)
        if duration >= 10_000:
            status = "timeout"
        rows.append({"name": name, "suite": "plugin-host-acceptance / java-workflow-helpers-only", "status": status,
                     "durationMs": duration, "maxMs": 10_000, "details": details, "command": command, "exitCode": code})
        print(f"{status.upper()} {name} ({duration} ms) {details}", flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(inputs.json_bytes({"runner": "acceptance", "warnMs": 2000, "maxMs": 10_000,
                                              "complete": False, "runtimeExecuted": False, "tests": rows}))
    return int(any(row["status"] != "passed" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
