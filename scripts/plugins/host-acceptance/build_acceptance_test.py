#!/usr/bin/env python3
"""Bounded offline helper checks; these never count as native build acceptance."""

from __future__ import annotations

import argparse
import ast
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import build_acceptance as acceptance
import build_fixture as fixture


class BuildHelperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lithe-build-helper-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "fixture"
        self.plan = fixture.generate_fixture(self.root)

    def test_deterministic_archives_and_source_identity(self):
        other = self.directory / "second"
        second = fixture.generate_fixture(other)
        self.assertEqual(self.plan, second)
        for variant in self.plan["variants"]:
            for marker, archive in variant["archives"].items():
                first, another = (root / archive["path"] for root in (self.root, other))
                self.assertEqual(first.read_bytes(), another.read_bytes())
                self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), archive["sha256"])
                with zipfile.ZipFile(first) as package:
                    manifest = json.loads(package.read("plugin.json"))
                    expected, source, _ = fixture.declaration(variant["id"], marker)
                    self.assertEqual(manifest, expected)
                    self.assertEqual(variant["sourceSha256"], hashlib.sha256((fixture.CONTRACTS / source).read_bytes()).hexdigest())
                    self.assertEqual(manifest["vendor"]["signatureRequirement"], "none")
                    self.assertEqual(manifest["permissions"], ["process.build"])
                    self.assertNotIn("lithe-plugin-signature.json", package.namelist())
        fixture.load_plan(self.root)

    def test_five_candidate_sources_and_legacy_adapter_are_inputs_only(self):
        candidates = set()
        for variant in self.plan["variants"]:
            declaration, _, kind = fixture.declaration(variant["id"], "a")
            candidates.add(kind)
            system = declaration["buildSystems"][0]
            self.assertNotIn("provider", system)
            self.assertNotIn("buildProviders", declaration)
            invocation = system["invocation"]
            if kind == "executableSetting":
                self.assertEqual(invocation["executableSetting"], "toolPath")
                self.assertEqual(declaration["requires"]["buildSystems"], 2)
            else:
                self.assertEqual(invocation["executables"][0]["kind"], kind)
            if kind == "setting":
                self.assertEqual(invocation["executables"][1]["kind"], "command")
                self.assertEqual(declaration["settings"][0]["scope"], "global")
                self.assertEqual(declaration["requires"]["executableResolution"], 1)
            if kind == "runtime":
                self.assertEqual(invocation["runtimeDependencies"], [{"id": "node", "minimumVersion": "18.0.0"}])
        self.assertEqual(candidates, {"projectFile", "environment", "command", "runtime", "setting", "executableSetting"})

    def test_existing_decoder_maps_and_outputfile_templates_remain_canonical(self):
        for variant in self.plan["variants"]:
            manifest, source, _ = fixture.declaration(variant["id"], "a")
            original = json.loads((fixture.CONTRACTS / source).read_text(encoding="utf-8"))["buildSystems"][0]
            system = manifest["buildSystems"][0]
            self.assertEqual(system.get("model"), original.get("model"))
            self.assertEqual(system.get("diagnostics"), original.get("diagnostics"))
            self.assertEqual(system.get("sync"), original.get("sync"))
            self.assertEqual(system.get("tasks"), original.get("tasks"))
            if "dependencies" in original:
                self.assertEqual(system["dependencies"], original["dependencies"])

    def test_same_version_replacement_changes_reviewed_bytes(self):
        for variant in self.plan["variants"]:
            self.assertNotEqual(variant["archives"]["a"]["sha256"], variant["archives"]["b"]["sha256"])
            a, b = (fixture.declaration(variant["id"], marker)[0] for marker in ("a", "b"))
            self.assertEqual(a["id"], b["id"])
            self.assertEqual(a["version"], b["version"])
            self.assertNotEqual(a["buildSystems"][0]["invocation"]["globalArguments"], b["buildSystems"][0]["invocation"]["globalArguments"])

    def test_existing_directory_is_never_cleared_or_overwritten(self):
        before = fixture.ordinary_tree(self.root)
        with self.assertRaises(FileExistsError):
            fixture.generate_fixture(self.root)
        self.assertEqual(fixture.ordinary_tree(self.root), before)

    def test_path_traversal_absolute_drive_and_empty_values_are_refused(self):
        for path in ("../escape", "/absolute", "C:/fixture", "C:relative", "x\\escape", "", "a/./b", "a//b"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                fixture.confined(self.root, path)
        self.assertEqual(fixture.confined(self.root, "packages").name, "packages")

    def test_archive_digest_and_manifest_changes_are_refused(self):
        archive = self.root / self.plan["variants"][0]["archives"]["a"]["path"]
        archive.write_bytes(archive.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "digest"):
            fixture.load_plan(self.root)

    def test_manifest_tamper_is_not_blessed_by_changing_the_recorded_digest(self):
        variant = self.plan["variants"][0]
        asset = variant["archives"]["a"]
        archive = self.root / asset["path"]
        with zipfile.ZipFile(archive) as source:
            files = {name: source.read(name) for name in source.namelist()}
        document = json.loads(files["plugin.json"])
        document["permissions"].append("ui.web")
        files["plugin.json"] = fixture.json_bytes(document)
        archive.unlink()
        fixture.write_archive(archive, files)
        asset["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.root / "plan.json").write_bytes(fixture.json_bytes(self.plan))
        with self.assertRaisesRegex(ValueError, "manifest"):
            fixture.load_plan(self.root)

    def test_incomplete_archives_or_source_revision_are_refused(self):
        variant = self.plan["variants"][0]
        variant["archives"].pop("b")
        (self.root / "plan.json").write_bytes(fixture.json_bytes(self.plan))
        with self.assertRaisesRegex(ValueError, "both"):
            fixture.load_plan(self.root)
        variant["sourceSha256"] = "0" * 64
        (self.root / "plan.json").write_bytes(fixture.json_bytes(self.plan))
        with self.assertRaisesRegex(ValueError, "canonical"):
            fixture.load_plan(self.root)

    def test_host_integration_never_gets_an_unsigned_official_archive(self):
        self.assertIn("official publisher-signed", self.plan["hostIntegration"]["prerequisite"])
        names = [path.name for path in (self.root / "packages").glob("*.zip")]
        self.assertFalse(any("maven" in name or "host-integration" in name for name in names))
        self.assertTrue((self.root / "workspaces/host-integration/pom.xml").is_file())

    def test_closed_capabilities_register_every_case_as_pending(self):
        capabilities = {"languages": [1], "settings": [1, 2], "ui": [1, 2]}
        rows = acceptance.planned_cases(self.plan, capabilities)
        self.assertEqual(len(rows), len(fixture.VARIANTS) * len(acceptance.STEPS) + 2)
        self.assertTrue(all(row["status"] == "skipped" and row["durationMs"] == 0 and "Not executed" in row["details"] for row in rows))
        self.assertIn("Closed source prerequisites", rows[0]["details"])

    def test_source_capability_reader_fails_closed_on_nonliteral_implementation(self):
        source = self.directory / "source/windows/tauri/src-tauri/src/plugin_host"
        source.mkdir(parents=True)
        (source / "mod.rs").write_text("pub fn host_capabilities() -> Value { from_config() }")
        with self.assertRaises(ValueError):
            acceptance.source_capabilities(self.directory / "source")

    def test_partial_capability_does_not_enable_settings_or_legacy(self):
        capabilities = {"buildSystems": [1], "settings": [1, 2]}
        legacy = next(variant for variant in self.plan["variants"] if variant["candidate"] == "executableSetting")
        setting = next(variant for variant in self.plan["variants"] if variant["candidate"] == "setting")
        self.assertEqual(acceptance.missing_capabilities(legacy["requires"], capabilities), ["buildSystems:2"])
        self.assertEqual(acceptance.missing_capabilities(setting["requires"], capabilities), ["executableResolution:1"])

    def test_pending_registration_never_overwrites_a_real_failure(self):
        failed = {"name": "static-project / install-review", "status": "failed", "details": "native failure"}
        reporter = SimpleNamespace(tests=[failed])
        acceptance.record_unreached_cases(reporter, self.plan, {})
        acceptance.record_unreached_cases(reporter, self.plan, {})
        self.assertEqual(reporter.tests[0], failed)
        self.assertEqual(len({row["name"] for row in reporter.tests}), len(reporter.tests))

    def test_closed_build_lane_never_starts_product_or_calls_ipc(self):
        args = SimpleNamespace(build_fixture_root=self.root, artifact_root=self.directory / "artifacts",
                               build_official_maven_package=None)
        driver, restart = Mock(), Mock()
        reporter = SimpleNamespace(tests=[])
        with patch.object(acceptance, "source_capabilities", return_value={}):
            lane = acceptance.BuildAcceptance(driver, args, reporter, restart)
        lane.run()
        restart.assert_not_called()
        driver.invoke.assert_not_called()
        self.assertTrue(reporter.tests)
        self.assertTrue(all(row["status"] == "skipped" for row in reporter.tests))

    def test_arguments_require_fixture_root_for_official_package(self):
        parser = argparse.ArgumentParser()
        acceptance.add_arguments(parser)
        plain = parser.parse_args([])
        acceptance.validate_arguments(parser, plain)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            acceptance.validate_arguments(parser, parser.parse_args(["--build-official-maven-package", "official.zip"]))

    def test_tool_environment_uses_isolated_paths_with_spaces_and_always_restores(self):
        keys = ("PATH", "LITHE_ACCEPTANCE_TOOL_HOME")
        before = {key: os.environ.get(key) for key in keys}
        with self.assertRaises(RuntimeError):
            with acceptance.tool_environment(self.root):
                self.assertEqual(os.environ["PATH"].split(os.pathsep)[0], str(self.root / "tools with spaces/bin"))
                self.assertEqual(os.environ["LITHE_ACCEPTANCE_TOOL_HOME"], str(self.root / "tools with spaces"))
                raise RuntimeError("controlled failure")
        self.assertEqual({key: os.environ.get(key) for key in keys}, before)

    def test_gate_failure_releases_only_its_owned_workspace_control(self):
        workspace = self.root / self.plan["variants"][0]["workspace"]
        gate = acceptance.FixtureGate(workspace, "task")
        with self.assertRaises(RuntimeError):
            with gate:
                data = json.loads(gate.control.read_text())
                self.assertEqual(data, {"holdAction": "task", "token": gate.token})
                raise RuntimeError("controlled failure")
        self.assertFalse(gate.control.exists())
        self.assertTrue(gate.release.is_file())
        self.assertTrue((workspace / "Cargo.toml").is_file())
        with self.assertRaises(ValueError):
            acceptance.FixtureGate(workspace, "arbitrary-program")

    def test_events_require_new_completed_records_and_exact_workspace(self):
        workspace = (self.root / self.plan["variants"][0]["workspace"]).resolve()
        path = workspace / ".lithe-acceptance/events.jsonl"
        row = {"workspace": str(workspace), "event": "started", "pid": 12}
        # Real logs are one compact JSON document per completed line.
        path.write_text(json.dumps(row) + "\n", encoding="utf-8")
        offset = acceptance.event_offset(workspace)
        self.assertEqual(acceptance.events_after(workspace, offset), [])
        with path.open("ab") as stream:
            stream.write(json.dumps(row).encode())
        self.assertEqual(acceptance.events_after(workspace, offset), [])
        with path.open("ab") as stream:
            stream.write(b"\n")
        self.assertEqual(acceptance.events_after(workspace, offset), [row])
        with path.open("ab") as stream:
            stream.write((json.dumps({**row, "workspace": "unrelated"}) + "\n").encode())
        with self.assertRaises(ValueError):
            acceptance.events_after(workspace, offset)
        path.write_text("", encoding="utf-8")
        with self.assertRaises(ValueError):
            acceptance.events_after(workspace, offset)

    def test_all_six_native_identity_fields_isolate_late_events(self):
        review = {"operationId": "operation-a", "pluginId": "fixture.plugin", "buildSystemId": "fixture",
                  "root": ".", "workspaceRoot": "C:/fixture", "generation": 1}
        event = {**review, "type": "chunk", "stream": "stdout", "text": "one"}
        self.assertEqual(acceptance.matching_events([event], review), [event])
        for key in acceptance.IDENTITY:
            changed = {**event, key: 2 if key == "generation" else "foreign"}
            self.assertEqual(acceptance.matching_events([changed], review), [])
        del review["operationId"]
        with self.assertRaises(ValueError):
            acceptance.matching_events([event], review)

    def test_terminal_is_single_final_and_for_the_exact_operation(self):
        review = dict(zip(acceptance.IDENTITY, ("op", "plugin", "system", ".", "C:/fixture", 1)))
        chunk = {**review, "type": "chunk", "text": "log"}
        terminal = {**review, "type": "terminal", "terminal": {"kind": "cancelled"}}
        self.assertEqual(acceptance.assert_ordered_terminal([chunk, terminal], review, "cancelled"), [chunk, terminal])
        for events in ([terminal, chunk], [chunk], [terminal, terminal], [{**terminal, "operationId": "old"}]):
            with self.assertRaises(AssertionError):
                acceptance.assert_ordered_terminal(events, review, "cancelled")

    def test_installed_tree_snapshots_detect_added_removed_and_changed_bytes(self):
        package = self.directory / "readonly-package"
        package.mkdir()
        (package / "resource").write_bytes(b"before")
        before = fixture.ordinary_tree(package)
        (package / "resource").write_bytes(b"after")
        self.assertNotEqual(fixture.ordinary_tree(package), before)
        (package / "resource").write_bytes(b"before")
        self.assertEqual(fixture.ordinary_tree(package), before)
        (package / "events.jsonl").write_text("runtime write")
        self.assertNotEqual(fixture.ordinary_tree(package), before)

    def test_process_cleanup_never_terminates_a_pid_without_a_retained_owner(self):
        driver = Mock()
        dead, alive = Mock(pid=10), Mock(pid=20)
        dead.running.return_value = False
        alive.running.return_value = True
        driver.owned_processes = {10: dead, 20: alive}
        args = SimpleNamespace(build_fixture_root=self.root, artifact_root=self.directory / "evidence", build_official_maven_package=None)
        lane = acceptance.BuildAcceptance(driver, args, SimpleNamespace(tests=[]), Mock())
        lane.owned_handles = {10: dead, 20: alive}
        with self.assertRaisesRegex(AssertionError, "forced cleanup"):
            lane.cleanup_owned()
        driver.terminate_process_tree.assert_called_once_with(20, timeout_seconds=5)
        self.assertEqual(lane.owned_handles, {})

    def test_fixture_pid_record_requires_the_exact_workspace_script(self):
        workspace = (self.root / self.plan["variants"][0]["workspace"]).resolve()
        script = workspace / ".lithe-acceptance/fake-build-tool.mjs"
        self.assertTrue(acceptance.fixture_command_matches(f'node "{script}" --fixture-child', script))
        for command in (f'node "{script}.other"', f'node "{script.parent}/not-fake-build-tool.mjs"', 'node unrelated.mjs'):
            self.assertFalse(acceptance.fixture_command_matches(command, script))

    def test_process_capture_matches_each_declared_tool_location(self):
        driver = Mock()
        args = SimpleNamespace(build_fixture_root=self.root, artifact_root=self.directory / "evidence", build_official_maven_package=None)
        lane = acceptance.BuildAcceptance(driver, args, SimpleNamespace(tests=[]), Mock())
        lane.session = SimpleNamespace(root_owner=SimpleNamespace(pid=1))
        for variant in self.plan["variants"]:
            with self.subTest(candidate=variant["candidate"]):
                workspace = (self.root / variant["workspace"]).resolve()
                local = workspace / fixture.TOOL_RELATIVE
                external = self.root / "tools with spaces/bin" / fixture.TOOL.name
                script, unrelated = ((local, external) if variant["candidate"] in ("projectFile", "runtime")
                                     else (external, local))
                self.assertEqual(fixture.tool_script(self.root, variant), script)
                owner = Mock(pid=12)
                driver.process_tree.return_value = [{"ProcessId": 12, "CommandLine": f'node "{script}" --fixture-child'}]
                driver.capture_owned_tree.return_value = [owner]
                lane.variant, lane.workspace = variant, workspace
                events = [{"event": "started", "pid": 12, "action": "task"}]
                with patch.object(acceptance, "events_after", return_value=events):
                    self.assertEqual(lane.capture_fixture_processes(0), [owner])
                    driver.process_tree.return_value[0]["CommandLine"] = f'node "{unrelated}" --fixture-child'
                    with self.assertRaisesRegex(AssertionError, "matching application-descendant"):
                        lane.capture_fixture_processes(0)

    def test_cleanup_refuses_a_reused_pid_and_keeps_actual_old_handle_authority(self):
        old, replacement = Mock(pid=20), Mock(pid=20)
        old.running.return_value = True
        driver = Mock(owned_processes={20: replacement})
        args = SimpleNamespace(build_fixture_root=self.root, artifact_root=self.directory / "evidence", build_official_maven_package=None)
        lane = acceptance.BuildAcceptance(driver, args, SimpleNamespace(tests=[]), Mock())
        lane.owned_handles = {20: old}
        with self.assertRaisesRegex(AssertionError, "replaced process ownership"):
            lane.cleanup_owned()
        driver.terminate_process_tree.assert_not_called()

    def test_observer_only_transparently_forwards_original_ipc_and_targets_window(self):
        observer = acceptance.OBSERVER
        self.assertIn("original.call(this, command, args, ...rest)", observer)
        self.assertIn("throw error", observer)
        self.assertIn("target = {kind:'Window'", observer)
        self.assertIn("internals.invoke=original", observer)
        self.assertNotIn("plugin:event|emit", observer)
        self.assertNotIn("Browser.close", observer)

    def test_new_driver_has_no_install_record_write_or_signature_tls_bypass(self):
        source = Path(acceptance.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = {node.module or "" for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)}
        self.assertNotIn("http.server", imports)
        self.assertNotIn("ssl", imports)
        for forbidden in ("ignore_https_errors", "check_hostname = False", "CERT_NONE", "Browser.close", "taskkill"):
            self.assertNotIn(forbidden, source)
        writes = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                  and node.func.attr in ("write_text", "write_bytes")]
        self.assertEqual(len(writes), 1, "only the standalone pending report writer belongs here")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case")
    arguments = parser.parse_args()
    if arguments.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(arguments.case, sys.modules[__name__]))
        return 0 if result.wasSuccessful() else 1
    if arguments.report is None:
        parser.error("--report is required")
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(BuildHelperTests):
        started = time.monotonic()
        status, details = "passed", ""
        try:
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "--case", f"BuildHelperTests.{name}"],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
            if result.returncode:
                status, details = "failed", result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            status, details = "timeout", "helper case exceeded its 10 second process deadline"
        duration = round((time.monotonic() - started) * 1000, 3)
        row = {"name": name, "suite": "plugin-host-acceptance / build-helpers", "status": status,
               "durationMs": duration, "maxMs": 10_000, "details": details}
        rows.append(row)
        print(f"{status.upper()} {name} ({duration} ms)", flush=True)
        if details:
            print(details, file=sys.stderr)
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps({"runner": "acceptance", "warnMs": 2_000, "maxMs": 10_000, "tests": rows}, indent=2) + "\n", encoding="utf-8")
    return 1 if any(row["status"] != "passed" for row in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
