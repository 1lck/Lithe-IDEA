#!/usr/bin/env python3
"""Deterministic driver self-checks, explicitly separate from product acceptance."""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
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

    def test_controlled_package_contains_the_exact_reviewable_lsp_fixture(self):
        self.assertEqual(self.plan["serverSha256"], fixture.sha256(fixture.SERVER))
        for asset in self.plan["archives"].values():
            with zipfile.ZipFile(self.root / asset["path"]) as archive:
                manifest = json.loads(archive.read("plugin.json"))
                self.assertEqual(archive.read("server/fake-lsp-server.mjs"), fixture.SERVER.read_bytes())
            self.assertEqual(manifest["permissions"], ["languageServer.launch"])
            self.assertEqual(manifest["requires"]["languageServers"], 1)
            self.assertEqual(manifest["requires"]["serverProcess"], 1)
            self.assertEqual(manifest["languageServers"][0]["launch"],
                             {"kind": "runtime", "tool": "node", "entry": "server/fake-lsp-server.mjs"})

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
        page.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        stop = Mock()
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, reporter, Mock(return_value=(page, Mock())), stop)
        def fail_install(_):
            (args.run_image / "illegal-runtime-write").write_bytes(b"mutation")
            raise RuntimeError("controlled install failure")
        lane.install = fail_install
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "read-only resource mutation"):
                lane.run()
        self.assertTrue(any(".stop()" in call.args[0] for call in page.evaluate.call_args_list))
        stop.assert_called_once_with()
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
        page.evaluate.return_value = second.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        driver = Mock()
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        stop = Mock()
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, Reporter(), Mock(return_value=(page, Mock())), stop)
        lane.second = second
        lane.install = Mock(side_effect=RuntimeError("install failed"))
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "install failed"):
                lane.run()
        for observer in (page, second):
            self.assertTrue(any(".stop()" in call.args[0] for call in observer.evaluate.call_args_list))
        stop.assert_called_once_with()
        def first_failed(expression):
            raise RuntimeError("closed first window")
        page.evaluate.side_effect = first_failed
        second.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "closed first window"):
            lane.stop_observers()
        self.assertTrue(any(".stop()" in call.args[0] for call in second.evaluate.call_args_list))

    def test_native_shutdown_failure_is_reported_and_final_resource_hashes_include_shutdown_writes(self):
        from acceptance_driver import Reporter
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence",
                               run_image=self.directory / "image", app_local_data=self.directory / "app",
                               settings_functions_host_identity=self.directory / "identity.json", executable=self.directory / "host.exe")
        args.run_image.mkdir()
        page, driver, reporter = Mock(), Mock(), Reporter()
        page.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        def stop():
            self.assertTrue(any(".stop()" in call.args[0] for call in page.evaluate.call_args_list))
            (args.run_image / "shutdown-write").write_bytes(b"forbidden")
            raise RuntimeError("native graceful quit failed")
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, reporter, Mock(return_value=(page, Mock())), stop)
        for name in ("install", "public_search_clear", "explicit_save", "two_windows", "reload", "lifecycle"):
            setattr(lane, name, Mock())
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "read-only resource mutation"):
                lane.run()
        self.assertEqual([row["status"] for row in reporter.tests], ["passed"] * 7 + ["failed", "failed"])
        self.assertIn("native graceful quit failed", reporter.tests[-2]["details"])
        self.assertIn("shutdown-write", reporter.tests[-1]["details"])

    def test_failed_shutdown_cannot_pass_resource_invariance_when_hashes_match(self):
        from acceptance_driver import Reporter
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence",
                               run_image=self.directory / "image", app_local_data=self.directory / "app",
                               settings_functions_host_identity=self.directory / "identity.json", executable=self.directory / "host.exe")
        args.run_image.mkdir()
        page, driver, reporter = Mock(), Mock(), Reporter()
        page.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        stop = Mock(side_effect=RuntimeError("native graceful quit failed"))
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, reporter, Mock(return_value=(page, Mock())), stop)
        for name in ("install", "public_search_clear", "explicit_save", "two_windows", "reload", "lifecycle"):
            setattr(lane, name, Mock())
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "native shutdown did not complete"):
                lane.run()
        self.assertEqual([row["status"] for row in reporter.tests[-2:]], ["failed", "failed"])
        self.assertIn("native graceful quit failed", reporter.tests[-2]["details"])

    def test_observer_pending_deadline_is_failed_and_does_not_skip_the_other_window(self):
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence")
        driver, page, second = Mock(), Mock(), Mock()
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, Mock(), Mock(), Mock())
        lane.page, lane.second = page, second
        page.evaluate.return_value = {"calls": [{"settled": False}], "dropped": 0, "pending": 1, "originalInvokeRestored": True}
        second.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        with self.assertRaisesRegex(RuntimeError, "unsettled native calls"):
            lane.stop_observers()
        self.assertTrue(any(".stop()" in call.args[0] for call in second.evaluate.call_args_list))
        self.assertTrue(any(call.args[1].get("pending") == 1 for call in driver.write_json.call_args_list))

    def test_real_javascript_observer_drains_late_replies_and_bounds_unsettled_calls(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node is required by the acceptance helper CI lane")
        script = r"""
const assert=require('node:assert/strict'), vm=require('node:vm');
const source=JSON.parse(require('node:fs').readFileSync(0,'utf8'));
function setup() {
  const timers=new Map(), callbacks=new Map(), requests=[]; let sequence=0;
  const nativeFetch=function(...args){requests.push(args);return Promise.resolve('native response');};
  const window={fetch:nativeFetch,location:{href:'http://tauri.localhost/'}};
  const internals={};
  Object.defineProperty(window,'__TAURI_INTERNALS__',{value:internals});
  Object.defineProperty(internals,'callbacks',{value:callbacks});
  Object.defineProperty(internals,'invoke',{value:function(command,args={}) {
    return new Promise((resolve,reject)=>{
      const ok=++sequence, error=++sequence;
      callbacks.set(ok,value=>{callbacks.delete(ok);callbacks.delete(error);resolve(value);});
      callbacks.set(error,value=>{callbacks.delete(ok);callbacks.delete(error);reject(value);});
      window.fetch('http://ipc.localhost/'+command,{body:JSON.stringify(args),
        headers:new Headers({'Tauri-Callback':String(ok),'Tauri-Error':String(error)})});
    });
  }});
  vm.runInNewContext('('+source+')()', {window,URL,
    setTimeout:(callback,ms)=>{assert.equal(ms,10000);timers.set(++sequence,callback);return sequence;},
    clearTimeout:id=>timers.delete(id)});
  const reply=(index,failed,value)=>{
    const options=requests[index][1];
    callbacks.get(Number(options.headers.get(failed?'Tauri-Error':'Tauri-Callback')))(value);
  };
  return {window,timers,callbacks,requests,reply,nativeFetch,state:window.__litheSettingsAcceptance};
}
(async()=>{
  const passthrough=setup();
  for(const input of ['/relative-resource',new URL('http://tauri.localhost/resource'),{url:'http://tauri.localhost/request'},'http://[invalid']) {
    assert.equal(await passthrough.window.fetch(input),'native response');
    assert.equal(passthrough.requests.at(-1)[0],input);
  }
  assert.equal(passthrough.state.calls.length,0);await passthrough.state.stop();
  const normal=setup(), internals=normal.window.__TAURI_INTERNALS__, original=internals.invoke;
  assert.equal(Object.getOwnPropertyDescriptor(internals,'invoke').writable,false);
  const unobserved=internals.invoke('unobserved',{value:42}); normal.reply(0,false,42);
  assert.equal(await unobserved,42);
  const succeeded=internals.invoke('declarative_plugins_success',{value:'draft'}).then(value=>assert.equal(value,'late result'));
  const failed=internals.invoke('declarative_plugins_failure').then(()=>assert.fail('failure became success'),error=>assert.equal(error,'late error'));
  let finished=false;
  const stopping=normal.state.stop().then(result=>{finished=true;return result;});
  assert.equal(internals.invoke,original);assert.equal(normal.window.fetch,normal.nativeFetch);
  await Promise.resolve(); assert.equal(finished,false);
  normal.reply(1,false,'late result'); normal.reply(2,true,'late error');
  await Promise.all([succeeded,failed]);
  const final=await stopping;
  assert.equal(final.originalInvokeRestored,true); assert.equal(final.pending,0);
  assert.equal(final.calls.length,2); assert.ok(final.calls.every(call=>call.settled));
  assert.equal(final.calls[0].args.value,'draft');
  assert.equal(final.calls[0].value,'late result'); assert.equal(final.calls[1].error,'late error');
  assert.equal(normal.callbacks.size,0);assert.equal(normal.timers.size,0);
  const stalled=setup();
  const outstanding=stalled.window.__TAURI_INTERNALS__.invoke('declarative_plugins_stalled');
  try {
    const stop=stalled.state.stop();
    assert.equal(stalled.timers.size,1);
    [...stalled.timers.values()][0](); // Advance injected deadline; never sleep.
    const timed=await stop;
    assert.equal(timed.originalInvokeRestored,true); assert.equal(timed.pending,1);
    assert.equal(timed.calls[0].settled,false); assert.equal(stalled.timers.size,0);
  } finally {stalled.reply(0,false,null);await outstanding;}
  const changed=setup(), replacement=()=>{};
  changed.window.fetch=replacement;
  await assert.rejects(changed.state.stop(),/native invoke changed/);
  assert.equal(changed.window.fetch,replacement);
})().catch(error=>{console.error(error);process.exitCode=1;});
"""
        result = subprocess.run([node, "-e", script], input=json.dumps(acceptance.OBSERVER),
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_pending_registration_keeps_existing_failures(self):
        name = "controlled-settings / trusted-install-review"
        reporter = SimpleNamespace(tests=[{"name": name, "status": "failed"}])
        acceptance.record_unreached_cases(reporter, self.plan)
        self.assertEqual(sum(row["name"] == name for row in reporter.tests), 1)
        self.assertEqual(reporter.tests[0]["status"], "failed")

    def test_search_baseline_failure_saves_partial_evidence_and_disposes_input(self):
        # Helper evidence covers failure/cleanup only, never keyboard acceptance.
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence")
        driver, page = Mock(), Mock()
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, Mock(), Mock(), Mock())
        lane.page = page
        lane.details = Mock()
        handle = page.locator.return_value.get_by_role.return_value.element_handle.return_value
        handle.evaluate.return_value = {"value": "persisted stale filter"}
        with self.assertRaisesRegex(AssertionError, "search baseline"):
            lane.public_search_clear()
        handle.dispose.assert_called_once_with()
        page.keyboard.insert_text.assert_not_called()
        page.keyboard.down.assert_not_called()
        page.keyboard.up.assert_not_called()
        path, evidence = driver.write_json.call_args.args
        self.assertEqual(path.name, "public-search-clear-default-activation.json")
        self.assertNotIn("passed", evidence)
        self.assertEqual(evidence["snapshots"]["before"]["value"], "persisted stale filter")

    def test_search_failure_is_registered_and_native_finally_cleanup_still_runs(self):
        from acceptance_driver import Reporter
        args = SimpleNamespace(settings_functions_fixture_root=self.root, artifact_root=self.directory / "evidence",
                               run_image=self.directory / "image", app_local_data=self.directory / "app",
                               settings_functions_host_identity=self.directory / "identity.json", executable=self.directory / "host.exe")
        args.run_image.mkdir()
        page, driver, reporter, stop = Mock(), Mock(), Reporter(), Mock()
        driver.run_bounded_process.return_value = SimpleNamespace(returncode=0, stdout="v22.0.0")
        page.evaluate.return_value = {"calls": [], "dropped": 0, "pending": 0, "originalInvokeRestored": True}
        lane = acceptance.SettingsFunctionsAcceptance(driver, args, reporter, Mock(return_value=(page, Mock())), stop)
        lane.install = Mock()
        lane.public_search_clear = Mock(side_effect=AssertionError("browser default activation failed"))
        lane.explicit_save = Mock()
        with patch.object(acceptance, "verify_host", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(AssertionError, "browser default activation failed"):
                lane.run()
        acceptance.record_unreached_cases(reporter, self.plan)
        rows = [row for row in reporter.tests if row["name"] == "controlled-settings / public-search-clear-default-activation"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "failed")
        lane.explicit_save.assert_not_called()
        stop.assert_called_once_with()
        self.assertTrue(any(".stop()" in call.args[0] for call in page.evaluate.call_args_list))


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
