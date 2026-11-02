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
import java_workflow_build as build


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
                         "projectGenerators": [{"id": "java", "fields": [{"id": "buildSystem", "options": [{"value": "maven"}, {"value": "gradle"}]}],
                                                "requirements": [{"buildSystemID": variant, "when": {"field": "buildSystem", "equals": variant}}
                                                                 for variant in ("maven", "gradle")]}],
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
            for entry in ("templates/standard/Main.java", "templates/maven/pom.xml", "templates/gradle/build.gradle", "templates/gradle/settings.gradle"):
                output.writestr(entry, "helper-only template, never generated or executed")
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

    def test_cancelled_java_preparation_rejects_late_success(self):
        source = Path("C:/example/src/Main.java")
        request = core(1, "java.prepareLaunch", {"sourcePath": str(source), "mainClass": "Main"}, {"operationId": "cancelled-op"})
        cancel = core(2, "lsp.cancelOperation", {"operationId": "cancelled-op"}, {})
        drain = core(3, "lsp.waitEvents", {}, {"events": [{"type": "requestCompleted", "operationId": "cancelled-op", "result": {"kind": "ready"}}]})
        with self.assertRaisesRegex(AssertionError, "late result"):
            inputs.completed_preparation([request, cancel, drain], source, "Main", "java-session", 0, "ready")

    def test_generated_operation_binds_variant_form_jdk_and_review_identity(self):
        plan = inputs.variant_plan(self.plan, "gradle")
        prepared = {"sequence": 1, "command": "declarative_plugins_generator_prepare", "settled": True,
                    "args": {"request": {"pluginId": inputs.PLUGIN_ID, "generatorId": "java", "packageIdentity": "full-package",
                        "form": {"projectName": plan["project"]["name"], "values": {"buildSystem": "gradle", "groupId": plan["project"]["groupId"], "artifactId": "workflow"},
                                 "runtimes": {"jdk": {"home": plan["jdk"]["home"], "version": plan["jdk"]["version"]}}}}}, "value": {"id": "actual-review"}}
        generated = {"sequence": 2, "command": "declarative_plugins_generator_generate", "settled": True,
                     "args": {"id": "actual-review"}, "value": {"root": str(self.root)}}
        self.assertIsNotNone(inputs.generated_operation([prepared, generated], plan, self.root))
        generated["args"]["id"] = "older-review"
        self.assertIsNone(inputs.generated_operation([prepared, generated], plan, self.root))
        generated["args"]["id"] = "actual-review"
        prepared["args"]["request"]["form"]["values"]["buildSystem"] = "none"
        with self.assertRaisesRegex(AssertionError, "variant/JDK"):
            inputs.generated_operation([prepared, generated], plan, self.root)

    def test_ready_requires_real_plugin_owned_server_for_this_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / "plugin"
            package.mkdir()
            start = core(1, "lsp.startServer", {"pluginId": inputs.PLUGIN_ID, "rootUri": "file:///C:/example",
                         "executablePath": str(package / "runtime/java.exe"), "arguments": [str(package / "launcher.jar")]}, {"sessionId": "java-session"})
            ready = core(2, "lsp.waitEvents", {}, {"events": [{"type": "stateChanged", "state": "ready"}]})
            self.assertIsNotNone(inputs.ready_session([start, ready], Path("C:/example"), package))
            stopped = core(3, "lsp.waitEvents", {}, {"events": [{"type": "stateChanged", "state": "stopped"}]})
            self.assertIsNone(inputs.ready_session([start, ready, stopped], Path("C:/example"), package))
            self.assertIsNone(inputs.ready_session([start, ready], Path("C:/other"), package))
            start["core"]["payload"]["executablePath"] = "C:/host/java.exe"
            start["core"]["payload"]["arguments"] = ["C:/host/launcher.jar"]
            with self.assertRaisesRegex(AssertionError, "admitted plugin resources"):
                inputs.ready_session([start, ready], Path("C:/example"), package)

    def test_dropped_or_unparseable_ipc_is_a_failure(self):
        for value in ({"calls": [], "dropped": 1, "errors": []}, {"calls": [], "dropped": 0, "errors": ["decode"]}):
            with self.assertRaisesRegex(AssertionError, "dropped"):
                inputs.assert_observer(value)

    def test_variant_inputs_do_not_relabel_plain_receipts_or_source(self):
        self.plan.update(packageEvidence={"plain": True}, workspaceEvidence={"plain": True})
        for variant in ("maven", "gradle"):
            plan = inputs.variant_plan(self.plan, variant)
            self.assertEqual(plan["variant"], variant)
            self.assertEqual(plan["project"]["mainClass"], "org.example.acceptance.Main")
            self.assertEqual(plan["project"]["sourcePath"], "src/main/java/org/example/acceptance/Main.java")
            self.assertNotIn("workspaceEvidence", plan)
            self.assertNotIn("packageEvidence", plan)
            self.assertNotEqual(plan["project"]["name"], self.plan["project"]["name"])
        self.assertIn("workspaceEvidence", self.plan)

    def test_plain_project_cannot_be_relabelled_as_maven_or_gradle(self):
        for variant in ("maven", "gradle"):
            plan = {**self.plan, "schemaVersion": 2, "kind": "windows-java-workflow", "variant": variant}
            with self.assertRaisesRegex(ValueError, "variant project"):
                inputs.validate_plan(plan)

    def test_missing_variant_material_is_blocked_before_any_product_or_worker(self):
        for variant in ("maven", "gradle"):
            plan = inputs.variant_plan(self.plan, variant)
            result = acceptance.preflight(plan, {})
            self.assertEqual(result["variant"], variant)
            self.assertFalse(result["runtimeExecuted"])
            self.assertFalse(result["workflowPassed"])
            self.assertFalse(result["buildPluginPassed"])
            self.assertIn("buildPackage missing", result["blocked"])
            driver = MagicMock()
            with self.assertRaisesRegex(ValueError, "prerequisites blocked"):
                acceptance.run(SimpleNamespace(), driver, MagicMock(), plan)
            driver.AppSession.assert_not_called()
            driver.sync_playwright.assert_not_called()

    def test_missing_real_jdk_is_a_preflight_blocker_not_an_unreported_crash(self):
        plan = inputs.variant_plan(self.plan, "maven")
        del plan["jdk"]
        result = acceptance.preflight(plan, {})
        self.assertTrue(result["blocked"])
        self.assertFalse(result["runtimeExecuted"])

    def test_packaged_main_source_and_launch_are_variant_bound(self):
        source = inputs.java_source("MAVEN_ONLY", package_name="org.example.acceptance")
        self.assertTrue(source.startswith("package org.example.acceptance;\n"))
        target = {"classPaths": ["C:/example/target/classes"]}
        launch = {"executable": "C:/jdk/bin/java.exe", "workingDirectory": "C:/example",
                  "arguments": ["-cp", target["classPaths"][0], "org.example.acceptance.Main"]}
        inputs.assert_actual_launch(launch, target, Path("C:/example"), Path("C:/jdk"), "org.example.acceptance.Main")
        launch["arguments"][-1] = "Main"
        with self.assertRaisesRegex(AssertionError, "selected project"):
            inputs.assert_actual_launch(launch, target, Path("C:/example"), Path("C:/jdk"), "org.example.acceptance.Main")

    def build_package(self, plan, *, variant=None, provider=False):
        variant = variant or plan["variant"]
        required = {"buildSystems": 1, "packageTrust": 1}
        system = {"id": variant, "model": {"source": "command"},
                  "tasks": [{"id": "upstream-build", "displayName": "Build", "scopes": ["workspace"]}]}
        if provider:
            system["provider"] = {"languageServer": "java"}
            required["buildProviders"] = 1
        manifest = {"id": "org.example." + variant, "version": "1.0.0", "displayName": variant, "requires": required,
                    "vendor": {"signatureRequirement": "publisherPackage"}, "buildSystems": [system]}
        archive = self.root / (variant + ".zip")
        raw = inputs.json_bytes(manifest)
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("plugin.json", raw)
        plan["buildPackage"] = {"pluginId": manifest["id"], "buildSystemId": variant,
                                "requires": required, "manifestSha256": hashlib.sha256(raw).hexdigest(),
                                "archive": {"path": str(archive), "sha256": inputs.sha256(archive)}}
        plan["buildTask"] = {"taskId": "upstream-build", "scope": "workspace"}
        return manifest

    def receipt(self, plan, key, **values):
        evidence = self.root / (key + "-original.json")
        evidence.write_text("helper-only original; no product validation claim", encoding="utf-8")
        document = {"status": "passed", "productionTrusted": True, "variant": plan["variant"],
                    "sourceCommit": plan["sourceCommit"], "evidence": [{"path": str(evidence), "sha256": inputs.sha256(evidence)}], **values}
        path = self.root / (key + ".json")
        path.write_bytes(inputs.json_bytes(document))
        plan[key] = {"path": str(path), "sha256": inputs.sha256(path)}
        return document

    def test_build_variant_package_and_requires_must_match_actual_archive(self):
        plan = inputs.variant_plan(self.plan, "maven")
        self.build_package(plan, variant="gradle")
        with self.assertRaisesRegex(ValueError, "independent complete"):
            inputs.validate_plan(plan)
        self.build_package(plan)
        plan["buildPackage"]["requires"] = {"buildSystems": 1}
        with self.assertRaisesRegex(ValueError, "requires identity"):
            inputs.validate_plan(plan)

    def test_old_or_candidate_build_receipt_never_admits_variant(self):
        plan = inputs.variant_plan(self.plan, "gradle")
        self.build_package(plan)
        package = plan["buildPackage"]
        values = {"pluginId": package["pluginId"], "buildSystemId": "gradle", "packageSha256": package["archive"]["sha256"],
                  "manifestSha256": package["manifestSha256"]}
        for changed in ({"variant": "maven"}, {"sourceCommit": "b" * 40}, {"productionTrusted": False}, {"packageSha256": "b" * 64}):
            self.receipt(plan, "buildPackageEvidence", **{**values, **changed})
            self.assertTrue(any("buildPackageEvidence is candidate/incomplete" in item for item in inputs.validate_plan(plan)[1]))

    def test_closed_build_provider_capability_is_reported_independently(self):
        plan = inputs.variant_plan(self.plan, "maven")
        self.build_package(plan, provider=True)
        caps = {key: [value] for key, value in inputs.REQUIRES.items()}
        caps["buildSystems"] = [1]
        result = acceptance.preflight(plan, caps)
        self.assertIn("closed build capability buildProviders:1", result["blocked"])
        self.assertEqual(result["scope"], "maven-runtime-driver")

    def workspace_receipt(self, plan):
        project = plan["project"]
        workspace = self.root / "generated"
        files = {}
        for relative in (*inputs.DESCRIPTORS[plan["variant"]], project["sourcePath"], ".lithe/run/local.json"):
            path = workspace / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(inputs.json_bytes({"toolchain": {"javaHomePath": plan["jdk"]["home"]}}) if relative.endswith(".json") else b"generated-only")
            files[relative] = {"path": str(path), "sha256": inputs.sha256(path)}
        values = {"javaHome": plan["jdk"]["home"], "javaVersion": plan["jdk"]["version"],
                  "javaSha256": plan["jdk"]["javaSha256"], "javacSha256": plan["jdk"]["javacSha256"],
                  "packageSha256": plan["package"]["archive"]["sha256"], "project": project, "generatorId": "java",
                  "workspaceRoot": str(workspace), "generatedFiles": files}
        self.receipt(plan, "workspaceEvidence", **values)
        return values

    def test_workspace_receipt_binds_generated_files_jdk_variant_and_source(self):
        plan = inputs.variant_plan(self.plan, "maven")
        values = self.workspace_receipt(plan)
        self.assertFalse(any("workspaceEvidence" in item for item in inputs.validate_plan(plan)[1]))
        self.receipt(plan, "workspaceEvidence", **{**values, "variant": "gradle"})
        self.assertTrue(any("workspaceEvidence is candidate/incomplete" in item for item in inputs.validate_plan(plan)[1]))
        self.receipt(plan, "workspaceEvidence", **values)
        (Path(values["workspaceRoot"]) / "pom.xml").write_bytes(b"changed after generation")
        with self.assertRaisesRegex(ValueError, "input bytes changed"):
            inputs.validate_plan(plan)

    def test_workspace_receipt_cannot_omit_a_descriptor_or_substitute_external_file(self):
        plan = inputs.variant_plan(self.plan, "gradle")
        values = self.workspace_receipt(plan)
        missing = copy.deepcopy(values)
        del missing["generatedFiles"]["settings.gradle"]
        self.receipt(plan, "workspaceEvidence", **missing)
        self.assertIn("workspaceEvidence missing generated file settings.gradle", inputs.validate_plan(plan)[1])
        external = self.root / "another-build.gradle"
        external.write_bytes(b"another workspace")
        values["generatedFiles"]["build.gradle"] = {"path": str(external), "sha256": inputs.sha256(external)}
        self.receipt(plan, "workspaceEvidence", **values)
        self.assertIn("workspaceEvidence generated file belongs to another workspace", inputs.validate_plan(plan)[1])

    def test_plain_package_receipt_cannot_establish_variant_trust(self):
        plan = inputs.variant_plan(self.plan, "maven")
        package = plan["package"]
        self.receipt(plan, "packageEvidence", variant="plain", packageSha256=package["archive"]["sha256"], manifestSha256=package["manifestSha256"])
        self.assertTrue(any("packageEvidence is candidate/incomplete" in item for item in inputs.validate_plan(plan)[1]))

    def test_even_all_capabilities_and_helper_receipts_never_establish_variant_runtime(self):
        # Byte-bound helper inputs may reach the real runtime driver. They
        # still cannot establish product success without its individual cases.
        for variant in ("maven", "gradle"):
            with self.subTest(variant=variant):
                plan = inputs.variant_plan(self.plan, variant)
                self.build_package(plan)
                package = plan["package"]
                self.receipt(plan, "packageEvidence", packageSha256=package["archive"]["sha256"], manifestSha256=package["manifestSha256"])
                package = plan["buildPackage"]
                self.receipt(plan, "buildPackageEvidence", pluginId=package["pluginId"], buildSystemId=variant,
                             packageSha256=package["archive"]["sha256"], manifestSha256=package["manifestSha256"])
                self.workspace_receipt(plan)
                self.assertEqual(inputs.validate_plan(plan)[1], [])
                caps = {key: [value] for key, value in {**inputs.REQUIRES, "buildSystems": 1}.items()}
                report = acceptance.preflight(plan, caps)
                self.assertEqual(report["blocked"], [])
                self.assertTrue(all(row["name"].startswith(variant + "-java /") for row in report["tests"][:len(inputs.CASES) + len(inputs.BUILD_CASES)]))
                self.assertFalse(report["buildPluginPassed"])
                self.assertFalse(report["runtimeExecuted"])

    def test_build_task_selection_must_exist_in_the_actual_package(self):
        plan = inputs.variant_plan(self.plan, "maven")
        self.build_package(plan)
        for selected in ({}, {"taskId": "guessed-compile", "scope": "workspace"},
                         {"taskId": "upstream-build", "scope": "target"}):
            plan["buildTask"] = selected
            self.assertTrue(any("buildTask must select" in row for row in inputs.validate_plan(plan)[1]))

    def test_variant_report_never_relabels_plain_or_counts_skipped_failed_cleanup(self):
        for variant in ("plain", "maven", "gradle"):
            plan = self.plan if variant == "plain" else inputs.variant_plan(self.plan, variant)
            rows = inputs.pending_rows("helper", variant)
            self.assertFalse(acceptance.workflow_result(plan, rows, True)["workflowPassed"])
            for row in rows:
                row["status"] = "passed"
            result = acceptance.workflow_result(plan, rows, True)
            self.assertTrue(result["workflowPassed"])
            self.assertEqual(result["plainJavaPassed"], variant == "plain")
            self.assertEqual(result["buildPluginPassed"], variant != "plain")
            self.assertFalse(acceptance.workflow_result(plan, rows, False)["workflowPassed"])
            cleanup = next(row for row in rows if row["name"].endswith("product-profile-cleanup"))
            cleanup["status"] = "failed"
            result = acceptance.workflow_result(plan, rows, True)
            self.assertFalse(result["workflowPassed"])
            self.assertFalse(result["buildPluginPassed"])

    def build_review(self):
        plan = inputs.variant_plan(self.plan, "maven")
        self.build_package(plan)
        return plan, {"operationId": "model-actual", "pluginId": plan["buildPackage"]["pluginId"], "buildSystemId": "maven",
                      "root": ".", "workspaceRoot": str(self.root), "generation": 4}

    def test_build_review_requires_every_context_key_before_approval(self):
        plan, review = self.build_review()
        build.assert_review(review, plan, self.root, 4)
        for key, wrong in (("pluginId", inputs.PLUGIN_ID), ("buildSystemId", "gradle"), ("workspaceRoot", "C:/foreign"),
                           ("generation", 3), ("root", "submodule"), ("operationId", "")):
            with self.subTest(key=key), self.assertRaisesRegex(AssertionError, "foreign"):
                build.assert_review({**review, key: wrong}, plan, self.root, 4)

    def test_build_preparation_cannot_adopt_an_automatic_or_another_jdk(self):
        plan, _ = self.build_review()
        for runtimes in ({}, {"java": "C:/automatic-jdk/bin/java.exe"}):
            with self.assertRaisesRegex(AssertionError, "selected JDK"):
                build.assert_selected_runtime({"args": {"runtimeExecutables": runtimes}}, plan)
        build.assert_selected_runtime({"args": {"runtimeExecutables": {"java": str(Path(plan["jdk"]["home"]) / "bin/java.exe")}}}, plan)

    def test_model_failure_and_late_wrong_operation_cannot_complete_an_approved_load(self):
        _, review = self.build_review()
        call = {"sequence": 4, "command": build.EXECUTION_COMMANDS[0], "args": {"operationId": "late-old"},
                "settled": False}
        self.assertIsNone(build.approved_result([call], call["command"], review, 3))
        call["settled"] = True
        with self.assertRaisesRegex(AssertionError, "reviewed operation"):
            build.approved_result([call], call["command"], review, 3)
        call["args"]["operationId"] = review["operationId"]
        call["error"] = "plugin.build.cancelled"
        with self.assertRaisesRegex(AssertionError, "cancelled"):
            build.approved_result([call], call["command"], review, 3)

    def test_build_terminal_cancellation_failure_and_old_generation_do_not_pass(self):
        _, review = self.build_review()
        terminal = {**review, "type": "terminal", "terminal": {"kind": "succeeded", "exitCode": 0}}
        snapshot = {"calls": [], "events": [], "errors": [], "dropped": 0}
        for key, wrong in (("generation", 3), ("operationId", "late-old"), ("pluginId", inputs.PLUGIN_ID), ("root", "old")):
            snapshot["events"] = [{**terminal, key: wrong}]
            self.assertIsNone(build.terminal_events(snapshot, review))
        for kind in ("failed", "failedToStart", "cancelled"):
            snapshot["events"] = [{**terminal, "terminal": {"kind": kind}}]
            with self.assertRaisesRegex(AssertionError, "expected native terminal"):
                build.terminal_events(snapshot, review)
        snapshot["events"] = [terminal]
        self.assertEqual(build.terminal_events(snapshot, review), [terminal])
        snapshot["events"].append({**review, "type": "chunk", "text": "late"})
        with self.assertRaisesRegex(AssertionError, "single expected"):
            build.terminal_events(snapshot, review)

    def test_model_result_cannot_cross_generated_workspace_or_generation(self):
        plan, _ = self.build_review()
        row = {"pluginID": plan["buildPackage"]["pluginId"], "buildSystemID": "maven", "root": "."}
        view = {"workspaceRoot": str(self.root), "generation": 4, "instances": [row]}
        self.assertEqual(build.model_instance(view, plan, self.root, 4), row)
        with self.assertRaisesRegex(AssertionError, "workspace generation"):
            build.model_instance(view, plan, self.root, 5)
        view["instances"] = [{**row, "pluginID": inputs.PLUGIN_ID}]
        with self.assertRaisesRegex(AssertionError, "independently installed"):
            build.model_instance(view, plan, self.root, 4)

    def test_generator_archive_without_variant_templates_cannot_be_relabelled(self):
        plan = inputs.variant_plan(self.plan, "maven")
        raw = inputs.json_bytes(self.manifest)
        with zipfile.ZipFile(self.plan["package"]["archive"]["path"], "w") as output:
            output.writestr("plugin.json", raw)
        plan["package"]["archive"]["sha256"] = inputs.sha256(Path(plan["package"]["archive"]["path"]))
        with self.assertRaisesRegex(ValueError, "variant generator requirements/templates"):
            inputs.validate_plan(plan)

    def test_variant_input_cli_preserves_previous_plan_bytes(self):
        base = self.root / "base.json"
        base.write_bytes(inputs.json_bytes(self.plan))
        output = self.root / "maven-plan.json"
        arguments = ["java_workflow_inputs.py", "--base-plan", str(base), "--variant", "maven", "--output", str(output)]
        with patch.object(sys, "argv", arguments):
            inputs.main()
            before = output.read_bytes()
            with self.assertRaises(FileExistsError):
                inputs.main()
        self.assertEqual(output.read_bytes(), before)
        self.assertEqual(json.loads(before)["variant"], "maven")

    def test_blocked_runtime_cli_writes_report_without_starting_suite_owner(self):
        plan = inputs.variant_plan(self.plan, "gradle")
        path = self.root / "plan.json"
        path.write_bytes(inputs.json_bytes(plan))
        report = self.root / "blocked.json"
        with patch.object(sys, "argv", ["java_workflow_acceptance.py", "--plan", str(path), "--report", str(report)]):
            self.assertEqual(acceptance.main(), 2)
        result = json.loads(report.read_text(encoding="utf-8"))
        self.assertFalse(result["runtimeExecuted"])
        self.assertFalse(report.with_suffix(".worker.log").exists())
        self.assertTrue(all(row["status"] == "skipped" for row in result["tests"]))

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
