"""Offline injected process ownership and deadline regression tests."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import os
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("diagnostic", Path(__file__).with_name("vcs_move_diagnostic.py"))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


def controlled_inputs(root):
    return {key: str(root / key) for key in diagnostic.INPUT_KEYS}


def closed_job():
    return {"activeProcesses": 0, "jobTerminated": True}


class ControlledOwner:
    def __init__(self, result=0, error=None, cleanup_error=None):
        self.result, self.error, self.cleanup_error = result, error, cleanup_error
        self.events = []

    def run(self, command, seconds, log):
        self.events.extend(["assigned-before-release", "root", "descendant"])
        if self.error:
            raise self.error
        return self.result

    def close(self):
        self.events.extend(["terminate-job", "verify-zero-descendants"])
        if self.cleanup_error:
            raise self.cleanup_error
        return {"activeProcesses": 0}


class OwnershipTests(unittest.TestCase):
    def run_owner(self, owner):
        ticks = iter([1.0, 1.125])
        return diagnostic.supervised(["controlled-executor"], 5, "unused.log", lambda: owner, lambda: next(ticks))

    def test_exception_and_assertion_failure_clean_entire_owned_tree(self):
        for error in (RuntimeError("executor exception"), AssertionError("endpoint assertion")):
            with self.subTest(error=str(error)):
                owner = ControlledOwner(error=error)
                row = self.run_owner(owner)
                self.assertEqual(row["status"], "failed")
                self.assertEqual(row["durationMs"], 125)
                self.assertEqual(owner.events[-2:], ["terminate-job", "verify-zero-descendants"])

    def test_case_watchdog_and_nonzero_exit_are_failures(self):
        for owner in (ControlledOwner(error=TimeoutError("case hard deadline")), ControlledOwner(result=1)):
            row = self.run_owner(owner)
            self.assertEqual(row["status"], "failed")
            self.assertEqual(row["cleanup"]["activeProcesses"], 0)

    def test_cleanup_failure_cannot_be_counted_as_pass(self):
        row = self.run_owner(ControlledOwner(cleanup_error=TimeoutError("survivor")))
        self.assertEqual(row["status"], "failed")
        self.assertIn("survivor", row["cleanupError"])

    def test_owner_creation_exception_is_reported_without_losing_outer_cleanup(self):
        def unavailable():
            raise RuntimeError("job unavailable")
        row = diagnostic.supervised(["controlled"], 1, "unused", unavailable)
        self.assertEqual(row["status"], "failed")
        self.assertEqual(row["cleanup"], {"notStarted": True})

    def test_readonly_svn_fixture_cleanup_stays_inside_owned_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "owned"
            root.mkdir()
            revision = root / "revision"
            revision.write_bytes(b"fixed revision")
            os.chmod(revision, 0o444)
            self.assertTrue(diagnostic.remove_owned_tree(root))
            self.assertTrue(Path(directory).exists())

    def test_suite_budget_caps_each_case_and_stops_before_next_spawn(self):
        self.assertEqual(diagnostic.budget(100, 45, lambda: 90), 10)
        self.assertEqual(diagnostic.budget(100, 45, lambda: 0), 45)
        with self.assertRaises(TimeoutError):
            diagnostic.budget(100, 45, lambda: 100)

    def test_input_gate_rejects_missing_or_relative_inputs_before_execution(self):
        with self.assertRaises(ValueError):
            diagnostic.verify_inputs({}, "unused", "unused")
        with self.assertRaises(ValueError):
            diagnostic.verify_inputs(dict.fromkeys(("node", "provider", "sdk", "sourceIdentity", "svnZip", "svnRoot", "gate", "gateSource"), "relative"), "unused", "unused")

    def test_outer_suite_finally_removes_temporary_state_after_executor_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs.json"
            inputs.write_text(json.dumps(controlled_inputs(root)))
            owned = root / "owned"
            owned.mkdir()
            output = root / "evidence"
            argv = ["diagnostic", "--inputs", str(inputs), "--output", str(output)]
            with patch.object(sys, "argv", argv), patch.object(diagnostic.os, "name", "nt"), \
                 patch.object(diagnostic.tempfile, "mkdtemp", return_value=str(owned)), \
                 patch.object(diagnostic, "supervised", side_effect=AssertionError("injected assertion")):
                with self.assertRaises(AssertionError):
                    diagnostic.main()
            self.assertFalse(owned.exists())
            self.assertTrue((output / "cleanup.json").exists())
            self.assertTrue((output / "timing.junit.xml").exists())

    def test_case_timeout_records_unknown_refresh_and_post_cleanup_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, output = root / "inputs.json", root / "evidence"
            inputs.write_text(json.dumps(controlled_inputs(root)))
            events = []

            def executor(command, seconds, log, owner):
                if "--verify" in command:
                    diagnostic.write_json(output / "identity.json", {"verified": True, "files": [], "runtimeFiles": []})
                    return {"status": "passed", "exitCode": 0, "durationMs": 1, "cleanup": closed_job()}
                if "--snapshot" in command:
                    events.append("recover-only-after-owned-tree-cleanup")
                    return {"status": "passed", "exitCode": 0, "durationMs": 1, "cleanup": closed_job()}
                events.append("timeout-and-owned-tree-cleanup")
                return {"status": "failed", "exitCode": 124, "durationMs": 1, "cleanup": closed_job()}

            with patch.object(sys, "argv", ["diagnostic", "--inputs", str(inputs), "--output", str(output)]), \
                 patch.object(diagnostic.os, "name", "nt"), patch.object(diagnostic, "supervised", side_effect=executor):
                self.assertEqual(diagnostic.main(), 1)
            rows = __import__('json').loads((output / "timing.json").read_text())["tests"]
            self.assertEqual(rows[1]["operationOutcome"], "unknown")
            self.assertTrue(rows[1]["refreshRequired"])
            self.assertEqual(events, ["timeout-and-owned-tree-cleanup", "recover-only-after-owned-tree-cleanup"])
            self.assertTrue(__import__('json').loads((output / "cleanup.json").read_text())["removed"])

    def test_cleanup_unproven_skips_recovery_and_retains_owned_working_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, output, owned = root / "inputs.json", root / "evidence", root / "owned"
            inputs.write_text(json.dumps(controlled_inputs(root)))
            owned.mkdir()
            commands = []

            def executor(command, seconds, log, owner):
                commands.append(command)
                if "--verify" in command:
                    diagnostic.write_json(output / "identity.json", {"verified": True, "files": [], "runtimeFiles": []})
                    return {"status": "passed", "exitCode": 0, "durationMs": 1, "cleanup": closed_job()}
                return {"status": "failed", "exitCode": 124, "durationMs": 1,
                        "cleanupError": "job cleanup survivors: 1", "cleanup": {"activeProcesses": 1}}

            with patch.object(sys, "argv", ["diagnostic", "--inputs", str(inputs), "--output", str(output)]), \
                 patch.object(diagnostic.os, "name", "nt"), \
                 patch.object(diagnostic.tempfile, "mkdtemp", return_value=str(owned)), \
                 patch.object(diagnostic, "supervised", side_effect=executor), \
                 patch.object(diagnostic, "remove_owned_tree") as remove:
                self.assertEqual(diagnostic.main(), 1)
            remove.assert_not_called()
            self.assertFalse(any("--snapshot" in command for command in commands))
            report = json.loads((output / "timing.json").read_text())
            self.assertEqual(report["tests"][1]["afterUnavailable"], "cleanup-unproven")
            cleanup = json.loads((output / "cleanup.json").read_text())
            self.assertFalse(cleanup["removed"])
            self.assertIn("cleanup-unproven", cleanup["retained"])
            self.assertTrue(owned.exists())

    def test_output_overlap_is_rejected_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs.json"
            values = controlled_inputs(root)
            inputs.write_text(json.dumps(values))
            for key in ("provider", "sdk", "svnRoot"):
                fixed = Path(values[key])
                fixed.mkdir()
                output = fixed / "new-evidence"
                with self.subTest(key=key), \
                     patch.object(sys, "argv", ["diagnostic", "--inputs", str(inputs), "--output", str(output)]), \
                     patch.object(diagnostic.os, "name", "nt"), patch.object(diagnostic, "supervised") as execute:
                    with self.assertRaisesRegex(ValueError, "overlaps fixed input"):
                        diagnostic.main()
                execute.assert_not_called()
                self.assertEqual(list(fixed.iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows junction identity")
    def test_output_junction_alias_cannot_write_inside_fixed_input(self):
        import _winapi
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            values = controlled_inputs(root)
            source, alias = Path(values["provider"]), root / "alias"
            source.mkdir()
            _winapi.CreateJunction(str(source), str(alias))
            try:
                with self.assertRaisesRegex(ValueError, "overlaps fixed input"):
                    diagnostic.validate_output(values, root / "inputs.json", alias / "new-evidence")
                self.assertEqual(list(source.iterdir()), [])
            finally:
                alias.rmdir()

    def test_final_hash_mismatch_and_read_error_are_failed_in_all_reports(self):
        for failure in (None, OSError("input read failed")):
            with self.subTest(readError=failure is not None), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                inputs, output = root / "inputs.json", root / "evidence"
                inputs.write_text(json.dumps(controlled_inputs(root)))

                def executor(command, seconds, log, owner):
                    if "--verify" in command:
                        receipt = {"verified": True, "files": [{"path": str(root / "fixed"), "sha256": "expected"}], "runtimeFiles": []}
                    else:
                        receipt = {"status": "diagnosis-matched", "safetyPass": False}
                    diagnostic.write_json(output / ("identity.json" if "--verify" in command else log.stem + ".json"), receipt)
                    return {"status": "passed", "exitCode": 0, "durationMs": 1, "cleanup": closed_job()}

                with patch.object(sys, "argv", ["diagnostic", "--inputs", str(inputs), "--output", str(output)]), \
                     patch.object(diagnostic.os, "name", "nt"), patch.object(diagnostic, "supervised", side_effect=executor), \
                     patch.object(diagnostic, "digest", side_effect=failure, return_value="changed"):
                    self.assertEqual(diagnostic.main(), 1)
                rows = json.loads((output / "timing.json").read_text())["tests"]
                self.assertEqual(rows[-1]["name"], "input-immutability")
                self.assertEqual(rows[-1]["status"], "failed")
                self.assertFalse(json.loads((output / "cleanup.json").read_text())["inputBytesUnchanged"])
                suite = diagnostic.ET.parse(output / "timing.junit.xml").getroot()
                self.assertEqual(suite.get("failures"), "1")
                self.assertIsNotNone(suite.find("testcase[@name='input-immutability']/failure"))
                self.assertIn("input-immutability", (output / "timing.html").read_text())

    @unittest.skipUnless(os.name == "nt", "Windows kernel job integration")
    def test_native_job_cleans_descendant_after_root_exit(self):
        # Child signals readiness over a pipe; no sleep-based synchronization.
        # Parent exits first. The retained job still owns the waiting descendant.
        child = "import threading; print('ready',flush=True); threading.Event().wait(30)"
        root = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c'," + repr(child) + "],stdout=subprocess.PIPE); assert p.stdout.readline().strip()==b'ready'"
        directory = tempfile.mkdtemp()
        try:
            row = diagnostic.supervised([sys.executable, "-c", root], 5, Path(directory) / "native.log", diagnostic.WindowsJob)
            self.assertEqual(row["status"], "passed", row)
            self.assertEqual(row["cleanup"]["activeProcesses"], 0)
            self.assertGreaterEqual(row["cleanup"]["totalProcesses"], 3)
        finally:
            diagnostic.remove_owned_tree(Path(directory))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case")
    args = parser.parse_args()
    if args.case:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromName(args.case, sys.modules[__name__]))
        print("LITHE_TEST_RESULT=" + json.dumps({"skipped": bool(result.skipped)}), flush=True)
        return 0 if result.wasSuccessful() else 1
    if args.report is None:
        parser.error("--report is required")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for name in unittest.defaultTestLoader.getTestCaseNames(OwnershipTests):
        log = args.report.with_name(args.report.stem + "-" + name + ".log")
        row = diagnostic.supervised([sys.executable, "-B", str(Path(__file__).resolve()), "--case", "OwnershipTests." + name],
                                    10, log, diagnostic.WindowsJob)
        row.update(name=name, suite="plugin-host-acceptance / vcs-move-diagnostic-helpers", maxMs=10000)
        if row["status"] == "passed":
            outcomes = [line for line in log.read_text(encoding="utf-8").splitlines() if line.startswith("LITHE_TEST_RESULT=")]
            if len(outcomes) != 1:
                row.update(status="failed", error="missing child unittest result")
            elif json.loads(outcomes[0].split("=", 1)[1])["skipped"]:
                row["status"] = "skipped"
        if row["durationMs"] >= row["maxMs"]:
            row.update(status="timeout", error="hard case budget exceeded, including job cleanup")
        rows.append(row)
        print(f"{row['status'].upper()} {name} ({row['durationMs']:.0f} ms)", flush=True)
    args.report.write_text(json.dumps({"runner": "acceptance", "warnMs": 2000, "tests": rows}, indent=2) + "\n", encoding="utf-8")
    return 1 if any(row["status"] not in ("passed", "skipped") for row in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
