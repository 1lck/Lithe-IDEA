#!/usr/bin/env python3
"""Bounded offline fixture/driver regressions; never product acceptance."""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

import native_workflow_fixture as fixture
from native_workflow_acceptance import (CASES, preflight, function_receipt, run_receipt,
                                        settings_conflict_receipt, project_reload_receipt)


class NativeWorkflowTests(unittest.TestCase):
    def test_project_reload_requires_the_same_receipt_and_one_successful_approved_model_operation(self):
        receipt = {"pluginId": fixture.PLUGIN_ID, "scope": "project", "project": {"registration": 1},
                   "expectedIdentity": "saved", "expectedPackageIdentity": "package"}
        calls = [{"command": "declarative_plugins_reload_settings", "args": receipt,
                  "settled": True, "value": {"view": {"generation": 2}}},
                 {"command": "declarative_plugins_prepare_settings_reload_model", "args": {"receipt": receipt},
                  "settled": True, "value": {"operationId": "reload-model"}},
                 {"command": "declarative_plugins_build_load_model", "args": {"operationId": "reload-model"},
                  "settled": True, "value": {"model": {"id": "loaded"}}}]
        self.assertEqual(project_reload_receipt(calls)["loaded"], calls[-1])
        for index in range(3):
            for patch in ({"settled": False}, {"error": {"code": "refused"}}, {"value": None}):
                invalid = [dict(row) for row in calls]
                invalid[index].update(patch)
                with self.assertRaisesRegex(AssertionError, "one successful"):
                    project_reload_receipt(invalid)
        for invalid in (calls[:-1], calls + [calls[-1]],
                        [calls[0], calls[1], {**calls[2], "args": {"operationId": "foreign"}}],
                        [calls[0], {**calls[1], "args": {"receipt": {**receipt, "expectedIdentity": "old"}}}, calls[2]]):
            with self.assertRaises(AssertionError):
                project_reload_receipt(invalid)

    def test_saved_settings_require_exact_conflict_and_no_confirmation_before_explicit_retry(self):
        stale = {"command": "declarative_plugins_native_function_prepare", "settled": True,
                 "args": {"request": {"bindingId": "old", "operationId": "old-operation"}},
                 "error": {"code": "plugin.settings.conflict", "message": "changed"}}
        self.assertIs(settings_conflict_receipt([stale]), stale)
        for error in ("[object Object]", {"code": "plugin.function.providerUnavailable"}, None):
            with self.assertRaisesRegex(AssertionError, "exact settings conflict"):
                settings_conflict_receipt([{**stale, "error": error}])
        with self.assertRaisesRegex(AssertionError, "was confirmed"):
            settings_conflict_receipt([stale, {"command": "declarative_plugins_function_confirm"}])
        for calls in ([], [stale, stale], [{**stale, "settled": False}]):
            with self.assertRaisesRegex(AssertionError, "one settled"):
                settings_conflict_receipt(calls)

    def run_evidence(self, testing=False, scope="Target"):
        identity = {"operationId": "one", "pluginId": fixture.PLUGIN_ID, "buildSystemId": "workflow",
                    "root": ".", "workspaceRoot": str(self.root), "generation": 1}
        terminal = {"kind": "failed" if testing else "succeeded", "exitCode": 1 if testing else 0, "message": None}
        selection = {"kind": "test" if testing else "task", "taskId": None if testing else "build",
                     "projectId": None if scope == "Workspace" else "workflow:Workflow project",
                     "targetId": "workflow.test:Workflow tests" if scope == "Target" else None,
                     "modelTaskId": None, "suite": "fixture.Suite" if testing else None,
                     "case": "fails" if testing else None, "userArguments": []}
        calls = [{"command": "declarative_plugins_build_prepare_run", "settled": True,
                  "args": {**{k: identity[k] for k in ("pluginId", "buildSystemId", "root", "workspaceRoot")}, "selection": selection},
                  "value": identity},
                 {"command": "declarative_plugins_build_execute_run", "settled": True,
                  "args": {"operationId": "one"}, "value": terminal}]
        events = [{**identity, "type": "chunk", "stream": "stdout", "text": "controlled task stdout"}]
        if testing:
            events += [{**identity, "type": "diagnostics", "diagnostics": [{"severity": "error", "message": "controlled diagnostic"}]},
                       {**identity, "type": "testResults", "results": {"success": False,
                        "summary": {"total": 1, "passed": 0, "failed": 1, "errors": 0, "skipped": 0},
                        "tests": [{"suite": "fixture.Suite", "case": "fails", "status": "failed", "message": "controlled failure"}]}}]
        events.append({**identity, "type": "terminal", "terminal": terminal})
        return calls, events

    def test_run_receipt_requires_successful_tasks_and_expected_failed_test_decoding(self):
        for testing, scopes in ((False, ("Workspace", "Project", "Target")), (True, ("Project", "Target"))):
            for scope in scopes:
                calls, events = self.run_evidence(testing, scope)
                receipt = run_receipt(calls, events, "Tests" if testing else "build / Build", scope, self.root)
                self.assertEqual(receipt["terminal"]["exitCode"], 1 if testing else 0)

    def test_run_receipt_rejects_failed_to_start_cancelled_and_unexpected_process_failure(self):
        for kind, code in (("failedToStart", None), ("cancelled", None), ("failed", 2), ("succeeded", 1)):
            calls, events = self.run_evidence()
            calls[-1]["value"].update(kind=kind, exitCode=code)
            with self.assertRaisesRegex(AssertionError, "terminal"):
                run_receipt(calls, events, "build / Build", "Target", self.root)

    def test_run_receipt_rejects_missing_test_report_diagnostics_and_wrong_selection(self):
        for event_type in ("testResults", "diagnostics", "terminal"):
            calls, events = self.run_evidence(True)
            with self.assertRaisesRegex(AssertionError, "report|terminal"):
                run_receipt(calls, [e for e in events if e["type"] != event_type], "Tests", "Target", self.root)
        for key in ("projectId", "targetId", "suite", "case"):
            calls, events = self.run_evidence(True)
            calls[0]["args"]["selection"][key] = "another selection"
            with self.assertRaisesRegex(AssertionError, "selector"):
                run_receipt(calls, events, "Tests", "Target", self.root)

    def test_run_receipt_rejects_foreign_operation_duplicate_terminal_and_ipc_failure(self):
        for mutation in (lambda c, e: c[-1]["args"].update(operationId="other"),
                         lambda c, e: e[-1].update(workspaceRoot="other"),
                         lambda c, e: e.append(dict(e[-1])),
                         lambda c, e: c[-1].update(error="native rejected")):
            calls, events = self.run_evidence()
            mutation(calls, events)
            with self.assertRaises(AssertionError):
                run_receipt(calls, events, "build / Build", "Target", self.root)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.root = self.parent / ".artifacts/plugin-host-acceptance/native-workflow-fixture-unit"
        self.revision = patch.object(fixture, "source_revision", return_value="fixture-revision")
        self.revision.start()
        self.addCleanup(self.revision.stop)
        # Preserve the real frozen reference and scripts, but isolate the output.
        self.reference = patch.object(fixture, "ROOT", self.parent)
        self.reference.start()
        self.addCleanup(self.reference.stop)
        for name in ("REFERENCE", "BACKEND", "TOOL"):
            original = getattr(fixture, name)
            local = self.parent / original.name
            local.write_bytes(original.read_bytes())
            replacement = patch.object(fixture, name, local)
            replacement.start()
            self.addCleanup(replacement.stop)
        # __file__ is included in the input inventory too.
        local = self.parent / "native_workflow_fixture.py"
        local.write_bytes(Path(fixture.__file__).read_bytes())
        replacement = patch.object(fixture, "__file__", str(local))
        replacement.start()
        self.addCleanup(replacement.stop)
        fixture.generate(self.root)

    def test_full_package_keeps_requirements_and_frozen_native_controls(self):
        plan = fixture.load_plan(self.root)
        self.assertFalse(plan["externalOfficialPackage"])
        self.assertFalse(plan["sdkExecuted"])
        reference = json.loads(fixture.REFERENCE.read_text(encoding="utf-8"))
        package = fixture.declaration("1.0.0")
        self.assertEqual(package["ui"]["toolWindows"][5]["native"]["controls"], reference["ui"]["toolWindows"][5]["native"]["controls"])
        self.assertEqual(package["requires"], fixture.REQUIRES)
        self.assertEqual(package["vendor"]["signatureRequirement"], "none")
        for version in ("1.0.0", "1.1.0"):
            package = fixture.declaration(version)
            self.assertTrue(package["languages"], "the complete requirements must describe used capabilities")
            self.assertEqual(package["languageServers"][0]["languageID"], package["languages"][0]["id"])
            self.assertIn("onLanguage:" + package["languages"][0]["id"], package["activationEvents"])
            self.assertEqual(package["languageServers"][0]["launch"]["entry"], "backend/native-workflow-backend.mjs")
        self.assertIn("launch", fixture.declaration("1.0.0")["buildSystems"][0]["provider"])

    def test_shared_version_preserves_requirements_and_explicit_language_ownership(self):
        shared = fixture.declaration("1.1.0")
        system = shared["buildSystems"][0]
        self.assertEqual(shared["requires"], fixture.REQUIRES)
        self.assertEqual(system["provider"]["languageServer"], shared["languageServers"][0]["languageID"])
        self.assertNotIn("launch", system["provider"])
        self.assertEqual(shared["languageServers"][0]["launch"]["entry"], "backend/native-workflow-backend.mjs")
        self.assertEqual(shared["languageServers"][0]["workspaceConfiguration"],
                         {"workflow": {"message": "${setting:immediateMessage}"}})
        self.assertEqual({s["effect"] for s in shared["settings"]}, {"immediate", "reload", "restart", "nextRun"})

    def test_test_executable_emits_the_declared_diagnostic_and_junit_failure(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "the controlled executable requires Node")
        workspace = self.root / "one"
        result = subprocess.run([node, str(workspace / ".lithe-acceptance/fake-build-tool.mjs"), "test"],
                                cwd=workspace, capture_output=True, text=True, encoding="utf-8", timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr)
        for version in ("1.0.0", "1.1.0"):
            diagnostics = fixture.declaration(version)["buildSystems"][0]["diagnostics"]
            self.assertEqual(diagnostics["decoder"], "lineMatcher")
            pattern = diagnostics["patterns"][0]
            match = next((match for line in result.stdout.splitlines()
                          if (match := re.search(pattern["regex"], line))), None)
            self.assertIsNotNone(match, "the real executable output must match its manifest")
            self.assertTrue((workspace / match[pattern["file"]]).is_file())
            self.assertEqual(match[pattern["message"]], "controlled diagnostic")
        report = ET.parse(workspace / "build/test-results/test/TEST-fixture.xml").getroot()
        self.assertEqual(report.attrib["failures"], "1")
        self.assertEqual(report.find("testcase/failure").attrib["message"], "controlled failure")

    def test_changed_zip_is_rejected_before_any_product_can_start(self):
        archive = self.root / "workflow-1.0.0.zip"
        archive.write_bytes(archive.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "ZIP changed"):
            fixture.load_plan(self.root)

    def test_plan_cannot_relabel_controlled_input_as_official_or_sdk_execution(self):
        path = self.root / "native-workflow-plan.json"
        plan = json.loads(path.read_text(encoding="utf-8"))
        plan["externalOfficialPackage"] = True
        path.write_text(json.dumps(plan), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "source/requirements changed"):
            fixture.load_plan(self.root)

    def test_partial_version_prerequisites_leave_every_product_step_unexecuted(self):
        report = preflight(fixture.load_plan(self.root), {"ui": [1, 2], "settings": [1, 2], "serverProcess": [1], "languages": [1], "languageServers": [2]})
        self.assertFalse(report["runtimeExecuted"])
        self.assertFalse(report["complete"])
        self.assertEqual(len(report["blocked"]), 3)
        self.assertEqual([row["name"] for row in report["tests"]], list(CASES))
        self.assertTrue(all(row["status"] == "skipped" for row in report["tests"]))

    def test_function_observation_preserves_first_failure_and_operation_identity(self):
        def row(command, value=None, error=None, operation="one"):
            return {"command": "declarative_plugins_function_" + command,
                    "args": {"operationId": operation}, "settled": True,
                    "value": value, "error": error}
        foreign = row("state", {"phase": "succeeded"}, operation="other")
        self.assertIsNone(function_receipt([foreign, row("state", {"phase": "starting"})], "one"))
        failure = row("state", {"phase": "failed", "error": {"code": "plugin.function.staleContext"}})
        with self.assertRaisesRegex(AssertionError, "one.*plugin.function.staleContext"):
            function_receipt([foreign, failure], "one")
        with self.assertRaisesRegex(AssertionError, "native confirm rejected"):
            function_receipt([row("confirm", error="native confirm rejected")], "one")
        with self.assertRaisesRegex(AssertionError, "identity"):
            function_receipt([row("state", {"phase": "succeeded", "context": {"operationId": "other"}})], "one")

    def test_function_observation_requires_terminal_success_after_cleanup(self):
        rows = [{"command": "declarative_plugins_function_state", "args": {"operationId": "one"},
                 "settled": True, "value": {"phase": "running"}}]
        self.assertIsNone(function_receipt(rows, "one"))
        rows.append({"command": "declarative_plugins_function_state", "args": {"operationId": "one"},
                     "settled": True, "value": {"phase": "cleanupFailed", "error": {"code": "plugin.function.cleanupFailed"}}})
        with self.assertRaisesRegex(AssertionError, "cleanupFailed"):
            function_receipt(rows, "one")
        rows[-1]["value"] = {"phase": "succeeded", "context": {"operationId": "one"}, "result": {"message": "peer result"}}
        self.assertEqual(function_receipt(rows, "one")["result"], {"message": "peer result"})

    def test_real_controlled_peer_retains_state_between_action_and_source(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "explicit Node fixture dependency is required")
        messages = [
            {"id": 1, "method": "initialize"},
            {"id": 2, "method": "lithe/function/invoke", "params": {"functionID": "tree.nodes"}},
            {"id": 3, "method": "lithe/function/invoke", "params": {"functionID": "tree.rename", "params": {"selectedID": "root"}}},
            {"id": 4, "method": "lithe/function/invoke", "params": {"functionID": "tree.nodes"}},
            {"id": 5, "method": "lithe/function/invoke", "params": {"functionID": "tree.fail"}},
            {"id": 6, "method": "lithe/function/invoke", "params": {"functionID": "buttons.withdraw"}},
            {"id": "registration-1", "result": None},
            {"id": 7, "method": "lithe/function/invoke", "params": {"functionID": "buttons.restore"}},
            {"id": "registration-2", "result": None},
        ]
        encoded = [json.dumps({"jsonrpc": "2.0", **message}).encode() for message in messages]
        wire = b"".join(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body for body in encoded)
        result = subprocess.run([node, str(fixture.BACKEND), "--state-dir", str(self.parent / "state")],
                                cwd=self.parent, input=wire, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        replies, remaining = [], result.stdout
        while remaining:
            header, body = remaining.split(b"\r\n\r\n", 1)
            length = int(header.split(b":", 1)[1])
            replies.append(json.loads(body[:length]))
            remaining = body[length:]
        self.assertEqual([row["id"] for row in replies], [1, 2, 3, 4, 5, "registration-1", 6, "registration-2", 7])
        self.assertEqual(replies[1]["result"]["nodes"][0]["label"], "Workflow root")
        self.assertEqual(replies[3]["result"]["nodes"][0]["label"], "Workflow root renamed")
        self.assertEqual(replies[4]["error"]["data"]["code"], "workflow.action")
        self.assertEqual(replies[5]["method"], "lithe/function/unregister")
        self.assertEqual(replies[5]["params"], {"ids": ["tree.rename"]})
        self.assertEqual(replies[6]["result"]["message"], "Workflow rename withdrawn")
        self.assertEqual(replies[7]["method"], "lithe/function/register")
        self.assertEqual(replies[8]["result"]["message"], "Workflow rename restored")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case")
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        return int(not result.wasSuccessful())
    if args.report is None:
        parser.error("--report is required")
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(NativeWorkflowTests):
        started = time.monotonic()
        status, details = "passed", ""
        try:
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "--case", "NativeWorkflowTests." + name],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
            if result.returncode:
                status, details = "failed", result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            status, details = "timeout", "native workflow helper exceeded 10 seconds"
        duration = round((time.monotonic() - started) * 1000, 3)
        if duration >= 10_000:
            status = "timeout"
        rows.append({"name": name, "suite": "native-workflow-offline", "status": status,
                     "details": details, "durationMs": duration, "maxMs": 10000})
        print(status, name, details, flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(fixture.json_bytes({"runner": "acceptance", "warnMs": 2000, "maxMs": 10000, "tests": rows}))
    return int(any(row["status"] != "passed" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
