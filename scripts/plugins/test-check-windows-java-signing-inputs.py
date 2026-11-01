#!/usr/bin/env python3
"""Deterministic signing preparation tests. No signer, key, JVM or network use."""

import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import traceback
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK = load("signing_inputs", "check-windows-java-signing-inputs.py")
FIXTURES = load("assembly_tests", "test-assemble-windows-java-support.py")


def run_tests(report):
    tests = []

    def case(name, action, architecture="x86_64"):
        started = time.monotonic()
        try:
            with tempfile.TemporaryDirectory(prefix="lithe-java-signing-test-") as scratch:
                fixture = FIXTURES.Fixture(Path(scratch), architecture)
                for name_ in CHECK.RELEASE_INPUTS:
                    destination = fixture.root / name_
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name_, destination)
                fixture.assemble()
                action(fixture)
            status, detail = "passed", ""
        except Exception:
            status, detail = "failed", traceback.format_exc()
        tests.append({"name": name, "suite": "Windows Java signing preparation", "status": status,
                      "durationMs": (time.monotonic() - started) * 1000, "maxMs": 15000, "details": detail})
        print(f"{status}: {name}", flush=True)

    def check(fixture, phase="before-signing", baseline=None):
        return CHECK.check(fixture.root, fixture.output, phase, baseline, time.monotonic() + 10)

    def write(fixture, name, transform, rewrite_receipt=False):
        path = fixture.output / name
        value = json.loads(path.read_text())
        transform(value)
        path.write_text(json.dumps(value), encoding="utf-8")
        if rewrite_receipt:
            receipt = fixture.output / CHECK.RECEIPT
            value = json.loads(receipt.read_text())
            value["files"][name] = FIXTURES.sha(path.read_bytes())
            receipt.write_text(json.dumps(value), encoding="utf-8")

    def prepared(fixture):
        before = CHECK.ASSEMBLY.file_inventory(fixture.output, time.monotonic() + 2)
        result = check(fixture)
        assert result["inputCheck"] == "passed"
        assert result["requires"] == FIXTURES.ASSEMBLY.REQUIRES
        assert result["originPolicy"] == "publisherPackage"
        assert result["releaseConfigurationGaps"] == ["official-release-disabled"]
        assert not result["productionAdmission"] and not result["runtimeExecuted"]
        assert not result["signatureDocumentPresent"]
        assert result["architecture"] == fixture.architecture
        assert CHECK.ASSEMBLY.file_inventory(fixture.output, time.monotonic() + 2) == before
        assert not list(fixture.output.parent.glob(".signing-check-*"))

    def forged_receipt(fixture):
        path = fixture.output / "language-server/plugins" / Path(json.loads((fixture.output / "plugin.json").read_text())["languageServers"][0]["launch"]["entry"]).name
        path.write_bytes(b"forged launcher")
        write(fixture, CHECK.RECEIPT, lambda receipt: receipt["files"].update({path.relative_to(fixture.output).as_posix(): FIXTURES.sha(path.read_bytes())}))
        FIXTURES.raises(ValueError, "pinned offline reconstruction", lambda: check(fixture))
        assert not list(fixture.output.parent.glob(".signing-check-*"))

    def unverified_signature(fixture):
        baseline = check(fixture)
        # A deliberately invalid signature is not authenticated by this tool.
        # Production key/signature rejection remains the existing verifier's job.
        (fixture.output / CHECK.SIGNATURE).write_text('{"keyID":"fixture-untrusted","signature":"invalid"}')
        result = check(fixture, "after-signing", baseline)
        assert result["inputCheck"] == "passed" and result["signatureDocumentPresent"]
        assert result["publisherVerification"] == "not-performed-use-existing-LithePluginPackageSigner"
        assert not result["productionAdmission"]
        assert result["candidateFiles"] == baseline["candidateFiles"]

    def post_sign_mutation(fixture):
        baseline = check(fixture)
        (fixture.output / CHECK.SIGNATURE).write_text("unverified fixture")
        write(fixture, "plugin.json", lambda manifest: manifest.update(version="9.9.9"), True)
        FIXTURES.raises(ValueError, "changed since before-signing", lambda: check(fixture, "after-signing", baseline))

    def release_mutation(fixture):
        baseline = check(fixture)
        (fixture.output / CHECK.SIGNATURE).write_text("unverified fixture")
        (fixture.root / CHECK.RELEASE_INPUTS[-1]).write_text("changed verifier")
        FIXTURES.raises(ValueError, "Release inputs changed", lambda: check(fixture, "after-signing", baseline))

    def changed_during_check(fixture):
        original = CHECK.ASSEMBLY.assemble

        def mutate(*args):
            receipt = original(*args)
            (fixture.output / "late-file").write_text("late change")
            return receipt

        with patch.object(CHECK.ASSEMBLY, "assemble", mutate):
            FIXTURES.raises(ValueError, "Candidate changed while checking", lambda: check(fixture))

    def manifest_changed_during_check(fixture):
        original = CHECK.ASSEMBLY.assemble

        def mutate(*args):
            receipt = original(*args)
            path = fixture.root / "third_party/jdtls/manifest.json"
            path.write_text(path.read_text() + "\n")
            return receipt

        with patch.object(CHECK.ASSEMBLY, "assemble", mutate):
            FIXTURES.raises(ValueError, "Source manifests changed while checking", lambda: check(fixture))

    def phases(fixture):
        FIXTURES.raises(ValueError, "requires a before-signing baseline", lambda: check(fixture, "after-signing"))
        FIXTURES.raises(ValueError, "requires a signature document", lambda: check(fixture, "after-signing", {}))
        (fixture.output / CHECK.SIGNATURE).write_text("unverified fixture")
        FIXTURES.raises(ValueError, "requires unsigned input", lambda: check(fixture))
        FIXTURES.raises(ValueError, "successful before-signing baseline", lambda: check(fixture, "after-signing", {}))
        FIXTURES.raises(ValueError, "successful before-signing baseline", lambda: check(fixture, "after-signing", []))

    def cli_report(fixture):
        path = fixture.root / ".artifacts/failed-signing-check.json"
        (fixture.output / CHECK.RECEIPT).write_text("[]")
        arguments = ["check", "--candidate", str(fixture.output), "--phase", "before-signing", "--report", str(path)]
        with patch.object(CHECK, "ROOT", fixture.root), patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()):
            assert CHECK.main() == 1
            assert json.loads(path.read_text())["inputCheck"] == "failed"
            saved = path.read_bytes()
            with contextlib.redirect_stderr(io.StringIO()):
                FIXTURES.raises(SystemExit, "2", CHECK.main)
            assert path.read_bytes() == saved
        arguments[-1] = str(fixture.output / "must-not-be-written.json")
        with patch.object(CHECK, "ROOT", fixture.root), patch.object(sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()):
            FIXTURES.raises(SystemExit, "2", CHECK.main)
        assert not (fixture.output / "must-not-be-written.json").exists()

    def deadline(fixture):
        FIXTURES.raises(TimeoutError, "deadline", lambda: CHECK.check(fixture.root, fixture.output, "before-signing", None, time.monotonic() - 1))
        assert not list(fixture.output.parent.glob(".signing-check-*"))

    def fail_manifest(fixture, transform):
        write(fixture, "plugin.json", transform, True)
        FIXTURES.raises(ValueError, "pinned offline reconstruction", lambda: check(fixture))

    case("full offline candidate is prepared without production admission or mutation", prepared)
    case("ARM64 synthetic handoff preserves its distinct Windows JDK and PE identity", prepared, "arm64")
    for capability in FIXTURES.ASSEMBLY.REQUIRES:
        case(f"cannot remove required capability {capability} even by rewriting receipt",
             lambda fixture, capability=capability: fail_manifest(fixture, lambda manifest: manifest["requires"].pop(capability)))
    case("publisher policy cannot be downgraded with a rewritten receipt",
         lambda fixture: fail_manifest(fixture, lambda manifest: manifest["vendor"].update(signatureRequirement="sameTeamAsHost")))
    case("forged inventory cannot replace a pinned upstream launcher", forged_receipt)
    case("untrusted or invalid signature never becomes publisher verification or admission", unverified_signature)
    case("post-sign content and receipt changes fail frozen baseline", post_sign_mutation)
    case("post-sign release tool changes fail frozen baseline", release_mutation)
    case("candidate mutation during reconstruction is detected", changed_during_check)
    case("upstream manifest mutation after reconstruction cannot change report provenance", manifest_changed_during_check)
    case("unsigned signed and baseline phases cannot be confused", phases)
    case("CLI preserves failed evidence and refuses report writes into candidate or old reports", cli_report)
    case("expired monotonic deadline leaves no signing reconstruction", deadline)
    case("extra file absent from receipt is rejected",
         lambda fixture: ((fixture.output / "extra").write_text("extra"), FIXTURES.raises(ValueError, "differs from its receipt", lambda: check(fixture))))
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"runner": "python", "warnMs": 1000, "maxMs": 15000, "tests": tests}, indent=2) + "\n", encoding="utf-8")
    return int(any(test["status"] != "passed" or test["durationMs"] >= test["maxMs"] for test in tests))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / ".artifacts/test-stability/windows-java-signing-inputs.json")
    raise SystemExit(run_tests(parser.parse_args().report))
