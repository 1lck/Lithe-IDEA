#!/usr/bin/env python3
"""Bounded synthetic release regressions; no JVM, private keys or network."""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import traceback
import zipfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROUTE = load("java_release", "windows-java-release.py")
FIXTURES = load("java_assembly_fixtures", "test-assemble-windows-java-support.py")


class ReleaseFixture:
    def __init__(self, root):
        self.root = root
        self.output = root / ".artifacts/windows-java-support/release"
        FIXTURES.Fixture(root)
        with tempfile.TemporaryDirectory(prefix="lithe-arm-input-") as temporary:
            arm = FIXTURES.Fixture(Path(temporary), "arm64")
            shutil.copyfile(arm.runtime_archive, root / ".artifacts/jdk-downloads" / arm.runtime_archive.name)
            jdk_path = root / "third_party/jdk/manifest.json"
            jdk = json.loads(jdk_path.read_text(encoding="utf-8"))
            jdk["platforms"]["windows-aarch64"] = json.loads((arm.root / "third_party/jdk/manifest.json").read_text(encoding="utf-8"))["platforms"]["windows-aarch64"]
            jdk_path.write_text(json.dumps(jdk), encoding="utf-8")
        config = json.loads((ROOT / "Plugins/marketplace/official-plugins.json").read_text(encoding="utf-8"))
        plugin = config["plugins"][0]
        for name in set([plugin["packageDirectory"], *plugin["inputPaths"], "scripts/plugins/official-plugin-releases.mjs"]):
            destination = root / name
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            if (ROOT / name).is_dir():
                shutil.copytree(ROOT / name, destination)
            else:
                shutil.copyfile(ROOT / name, destination)
        target = root / "Plugins/marketplace/official-plugins.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(config), encoding="utf-8")
        self.command(["git", "init", "--quiet"])
        self.command(["git", "config", "core.autocrlf", "false"])
        self.command(["git", "add", "--", "Plugins", "scripts", "third_party", "macos", ".github", *plugin["inputPaths"]])
        self.command(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Synthetic release inputs"])
        self.plan = json.loads(self.command(["node", "scripts/plugins/official-plugin-releases.mjs", "freeze", ROUTE.PLUGIN]))
        self.signature_calls = []

    def command(self, args):
        return ROUTE.run(args, self.root, time.monotonic() + 15)

    def signer(self, signer, package, root, deadline, *, sign=False):
        # Test double exercises orchestration failures only. It has no key or
        # cryptography and cannot establish real publisher verification.
        self.signature_calls.append((sign, str(package)))
        signature = package / ROUTE.SIGNATURE
        if sign:
            signature.write_text("synthetic-orchestration-only", encoding="utf-8")
        elif signature.read_text(encoding="utf-8") != "synthetic-orchestration-only":
            raise ValueError("Injected verifier rejected bad signature")

    def execute(self, mode="rehearse", plan=None, output=None, **kwargs):
        return ROUTE.execute(self.root, plan or self.plan, mode, output or self.output,
                             time.monotonic() + 20, verify=kwargs.pop("verify", self.signer), **kwargs)

    def clean(self):
        assert not list((self.root / ".artifacts/windows-java-support").glob(".release-*"))
        assert not list(self.root.rglob(".release-download-*"))


def run_tests(report, name_filter=None):
    tests = []

    def case(name, action):
        if name_filter and name_filter not in name:
            return
        started = time.monotonic()
        try:
            with tempfile.TemporaryDirectory(prefix="lithe-java-release-test-") as temporary:
                fixture = ReleaseFixture(Path(temporary))
                try:
                    action(fixture)
                finally:
                    fixture.clean()
            status, details = "passed", ""
        except Exception:
            status, details = "failed", traceback.format_exc()
        tests.append({"name": name, "suite": "Windows Java release orchestration (synthetic inputs)",
                      "status": status, "durationMs": (time.monotonic()-started)*1000, "maxMs": 30000, "details": details})
        print(f"{status}: {name}", flush=True)

    def rehearsal(f):
        with patch.dict(ROUTE.os.environ, {}, clear=False):
            result = f.execute()
        assert result["complete"] and not result["productionAdmission"]
        assert result["publisherVerification"] == "not-performed" and not f.signature_calls
        assert len(result["assets"]) == 2
        again = f.execute(output=f.output.with_name("repeat"))
        assert [a["sha256"] for a in again["assets"]] == [a["sha256"] for a in result["assets"]]
        assert all(a["manifestSHA256"] == a["files"]["plugin.json"] for a in result["assets"])

    def frozen_source(f):
        path = f.root / "Plugins/win/Official/JavaSupport/templates/plain/src/Main.java"
        path.write_bytes(b"today's unrelated source")
        manifest = f.root / "Plugins/win/Official/JavaSupport/plugin.json"
        changed = json.loads(manifest.read_text(encoding="utf-8"))
        changed.update(version="9.0.0", requires={"settings": 99})
        manifest.write_text(json.dumps(changed), encoding="utf-8")
        result = f.execute()
        assert result["assets"][0]["files"]["templates/plain/src/Main.java"] == f.plan["inputFiles"][path.relative_to(f.root).as_posix()]
        f.command(["git", "tag", "frozen-release"])
        tagged = json.loads(f.command(["node", "scripts/plugins/official-plugin-releases.mjs", "freeze", ROUTE.PLUGIN, "frozen-release"]))
        assert tagged == f.plan

    def missing(f):
        next((f.root / ".artifacts/jdk-downloads").glob("*windows-aarch64*")).unlink()
        result = f.execute("preflight")
        assert not result["complete"] and result["missingInputs"][0]["architecture"] == "arm64"
        FIXTURES.raises(ValueError, "Missing pinned offline inputs", f.execute)
        assert not f.output.exists()
        partial = f.execute(architecture="x86_64")
        assert not partial["complete"] and len(partial["assets"]) == 1

    def replaced_plan(f):
        for mutate in (lambda p: p["assets"].pop(), lambda p: p["assets"][-1].update(packageDirectory=p["packageDirectory"]),
                       lambda p: p["assets"][-1]["requires"].update(settings=1), lambda p: p.update(revision="0"*40),
                       lambda p: p["inputFiles"].update({"third_party/jdk/manifest.json": "0"*64})):
            plan = json.loads(json.dumps(f.plan))
            mutate(plan)
            try:
                f.execute(plan=plan)
            except ValueError:
                pass
            else:
                raise AssertionError("Replaced release inputs accepted")
        assert not f.output.exists()

    def corrupt_cache(f):
        next((f.root / ".artifacts/jdk-downloads").glob("*windows-aarch64*")).write_bytes(b"replaced")
        FIXTURES.raises(ValueError, "Pinned cache SHA-256", f.execute)
        assert not f.output.exists()

    def signer_roundtrip(f, aliases=False):
        result = f.execute("package")
        assert len(f.signature_calls) == 6  # sign, directory verify, extracted ZIP verify, per arch
        if aliases:
            for archive in (f.root / ".artifacts/jdtls-downloads").glob("vscode-*.zip"):
                archive.rename(archive.with_suffix(".vsix"))
        assert result["publisherVerification"] == "verified-existing-signer"
        verified = f.execute("verify")
        assert verified["assets"] == result["assets"]
        assert not verified["productionAdmission"]

    def signer_failure(f, mutates=False):
        def signer(*args, **kwargs):
            f.signer(*args, **kwargs)
            if mutates and kwargs.get("sign"):
                (args[1] / "plugin.json").write_text("{}", encoding="utf-8")
            if not mutates and not kwargs.get("sign"):
                raise ValueError("Injected verifier rejected bad signature")
        FIXTURES.raises(ValueError, "Signer changed" if mutates else "bad signature", lambda: f.execute("package", verify=signer))
        assert not f.output.exists()

    def zip_changed(f):
        original = ROUTE.verify_zip
        def tamper(assembly, archive, extracted, *args):
            with zipfile.ZipFile(archive, "a") as output:
                output.writestr(f"{ROUTE.PLUGIN}/extra.jar", b"replaced extraction bytes")
            return original(assembly, archive, extracted, *args)
        with patch.object(ROUTE, "verify_zip", tamper):
            FIXTURES.raises(ValueError, "ZIP differs", f.execute)
        assert not f.output.exists()

    def extracted_changed(f):
        def signer(*args, **kwargs):
            f.signer(*args, **kwargs)
            if "extract-" in str(args[1]):
                (args[1] / "plugin.json").write_bytes(b"changed after verification")
        FIXTURES.raises(ValueError, "Verifier changed extracted bytes", lambda: f.execute("package", verify=signer))
        assert not f.output.exists()

    def swapped_assets(f):
        f.execute("package")
        assets = list(f.output.glob("*.zip"))
        left, right = [path.read_bytes() for path in assets]
        assets[0].write_bytes(right)
        assets[1].write_bytes(left)
        FIXTURES.raises(ValueError, "ZIP differs", lambda: f.execute("verify"))

    def partial_and_unsigned(f):
        f.execute()
        FIXTURES.raises(ValueError, "no publisher signature", lambda: f.execute("verify"))
        next(f.output.glob("*.zip")).unlink()
        FIXTURES.raises(ValueError, "complete Windows release asset set", lambda: f.execute("verify"))

    def pinned_fetch(f):
        target = next((f.root / ".artifacts/jdk-downloads").glob("*windows-aarch64*"))
        original = target.read_bytes()
        target.unlink()

        class Response(io.BytesIO):
            def geturl(self):
                return "https://fixtures.invalid/pinned-input.zip"

        with patch.object(ROUTE.urllib.request, "urlopen", lambda *args, **kwargs: Response(original)):
            prepared = f.execute("prepare")
        assert prepared["complete"] and target.read_bytes() == original
        target.unlink()
        with patch.object(ROUTE.urllib.request, "urlopen", lambda *args, **kwargs: Response(b"wrong input")):
            FIXTURES.raises(ValueError, "Downloaded input SHA-256 mismatch", lambda: f.execute("prepare"))
        assert not target.exists()

    def false_package_source(f):
        source = "Plugins/win/Official/JavaSupport"
        alias = "Plugins/win/Official/OtherJavaSupport"
        shutil.copytree(f.root / source, f.root / alias)
        config_path = f.root / "Plugins/marketplace/official-plugins.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        for asset in config["plugins"][0]["assets"]:
            if asset["platforms"][0].startswith("windows-"):
                asset["packageDirectory"] = alias
        config_path.write_text(json.dumps(config), encoding="utf-8")
        f.command(["git", "add", "Plugins"])
        f.command(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Synthetic source mismatch"])
        plan = json.loads(f.command(["node", "scripts/plugins/official-plugin-releases.mjs", "freeze", ROUTE.PLUGIN]))
        FIXTURES.raises(ValueError, "frozen assembler source", lambda: f.execute(plan=plan))
        assert not f.output.exists()

    def archive_replaced_during_verification(f):
        original = ROUTE.verify_zip
        def replacing(assembly, archive, extracted, *args):
            extract = assembly.extract
            def replace_after_extract(*parameters):
                extract(*parameters)
                with archive.open("ab") as stream:
                    stream.write(b"changed ZIP bytes after independent extraction")
            with patch.object(assembly, "extract", replace_after_extract):
                return original(assembly, archive, extracted, *args)
        with patch.object(ROUTE, "verify_zip", replacing):
            FIXTURES.raises(ValueError, "ZIP changed during independent verification", f.execute)
        assert not f.output.exists()

    def deadlines_and_boundaries(f):
        FIXTURES.raises(TimeoutError, "deadline", lambda: ROUTE.execute(f.root, f.plan, "rehearse", f.output, time.monotonic()-1))
        FIXTURES.raises(ValueError, "plain new child", lambda: f.execute(output=f.root / "installed"))
        FIXTURES.raises(ValueError, "Only rehearsal", lambda: f.execute("package", architecture="x86_64"))

    case("dual architecture unsigned rehearsal is deterministic and never invokes signer", rehearsal)
    case("tagged Git input bytes survive today's source and checkout newline changes", frozen_source)
    case("missing ARM64 blocks full assembly while explicit x64 rehearsal stays incomplete", missing)
    case("missing architecture, mixed platform, downgraded requires and replaced revision/input fail", replaced_plan)
    case("corrupt cached input cannot be replaced or published", corrupt_cache)
    case("sign, directory verify, independent ZIP verify and index-retry verification (injected stub only)", signer_roundtrip)
    case("signed ZIP cache assembly verifies against clean VSIX cache reconstruction (stub signer)", lambda f: signer_roundtrip(f, True))
    case("existing verifier failure rejects package and cleans temporary resources", signer_failure)
    case("signer cannot change any original file or receipt", lambda f: signer_failure(f, True))
    case("changed ZIP extraction bytes fail pinned reconstruction", zip_changed)
    case("verification cannot modify independently extracted files", extracted_changed)
    case("swapped x64 and ARM64 ZIP identities fail", swapped_assets)
    case("unsigned archives and partial published asset sets fail index retry", partial_and_unsigned)
    case("explicit prepare checks pinned downloads and cleans failed download scratch (injected transport)", pinned_fetch)
    case("actual frozen assembler package directory cannot be replaced with an identical manifest alias", false_package_source)
    case("archive byte replacement during independent verification fails", archive_replaced_during_verification)
    case("local deadline and output ownership are enforced", deadlines_and_boundaries)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"runner": "python", "warnMs": 10000, "maxMs": 30000, "tests": tests}, indent=2)+"\n", encoding="utf-8")
    return int(any(test["status"] != "passed" for test in tests))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / ".artifacts/test-stability/windows-java-release.json")
    parser.add_argument("--filter")
    args = parser.parse_args()
    raise SystemExit(run_tests(args.report, args.filter))
