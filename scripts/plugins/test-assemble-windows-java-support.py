#!/usr/bin/env python3
"""Offline assembly regressions; tiny fake archives never leave their test root."""

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import sys
import tarfile
import tempfile
import time
import traceback
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("windows_java_assembly", Path(__file__).with_name("assemble-windows-java-support.py"))
ASSEMBLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSEMBLY)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def zip_bytes(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return output.getvalue()


def pe(machine):
    output = bytearray(70)
    output[:2] = b"MZ"
    struct.pack_into("<I", output, 60, 64)
    output[64:68] = b"PE\0\0"
    struct.pack_into("<H", output, 68, machine)
    return output


class Fixture:
    def __init__(self, root, architecture="x86_64", wrong_machine=False):
        self.root = root
        self.architecture = architecture
        self.output = root / ".artifacts/windows-java-support/candidate"
        source = root / ASSEMBLY.SOURCE
        shutil.copytree(ROOT / ASSEMBLY.SOURCE, source)
        jdt = json.loads((ROOT / "third_party/jdtls/manifest.json").read_text())
        jdk = json.loads((ROOT / "third_party/jdk/manifest.json").read_text())
        policy = json.loads((source / "language-server.json").read_text())
        platform_name = policy["architectures"][architecture]["jdkPlatform"]
        platform = jdk["platforms"][platform_name]
        jdt_cache = root / ".artifacts/jdtls-downloads"
        jdk_cache = root / ".artifacts/jdk-downloads"
        jdt_cache.mkdir(parents=True)
        jdk_cache.mkdir(parents=True)
        safe = lambda value: ASSEMBLY.re.sub(r"[^A-Za-z0-9._-]", "_", value)

        def write_pinned(content, name, hash_key):
            jdt[hash_key] = sha(content)
            path = jdt_cache / name.format(hash=jdt[hash_key])
            path.write_bytes(content)

        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode="w:gz") as archive:
            launcher = json.loads((source / "plugin.json").read_text())["languageServers"][0]["launch"]["entry"]
            for name in (launcher.removeprefix("language-server/"), "features/fixture.feature", "config_win/config.ini", "config_win_arm/config.ini"):
                data = b"fixture"
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        write_pinned(tar.getvalue(), f"jdtls-{safe(jdt['version'])}-{{hash}}.tar.gz", "archiveSHA256")
        for name, version, hash_key, content in (
            ("EPL-2.0", None, "licenseSHA256", b"fixture EPL"),
            ("lombok", "lombokVersion", "lombokSHA256", b"fixture lombok"),
            ("lombok-MIT", "lombokVersion", "lombokLicenseSHA256", b"fixture MIT"),
            ("java-debug-EPL-1.0", "javaDebugServerVersion", "javaDebugLicenseSHA256", b"fixture debug EPL"),
            ("java-test-MIT", "javaTestExtensionVersion", "javaTestLicenseSHA256", b"fixture test MIT"),
        ):
            suffix = ".jar" if hash_key == "lombokSHA256" else ".txt"
            version_part = f"-{safe(jdt[version])}" if version else ""
            write_pinned(content, name + version_part + "-{hash}" + suffix, hash_key)
        debug = b"fixture debug jar"
        jdt["javaDebugPluginSHA256"] = sha(debug)
        debug_zip = zip_bytes({f"extension/server/com.microsoft.java.debug.plugin-{jdt['javaDebugServerVersion']}.jar": debug})
        write_pinned(debug_zip, f"vscode-java-debug-{safe(jdt['javaDebugExtensionVersion'])}-{{hash}}.zip", "javaDebugArchiveSHA256")
        test, runner = b"fixture test bundle", b"fixture test runner"
        test_name = f"com.microsoft.java.test.plugin-{jdt['javaTestPluginVersion']}.jar"
        jdt["javaTestPluginSHA256"], jdt["javaTestRunnerSHA256"] = sha(test), sha(runner)
        test_zip = zip_bytes({"extension/package.json": json.dumps({"contributes": {"javaExtensions": [f"./server/{test_name}"]}}),
                              f"extension/server/{test_name}": test,
                              "extension/server/com.microsoft.java.test.runner-jar-with-dependencies.jar": runner})
        write_pinned(test_zip, f"vscode-java-test-{safe(jdt['javaTestExtensionVersion'])}-{{hash}}.zip", "javaTestArchiveSHA256")
        machine = policy["architectures"][architecture]["peMachine"]
        runtime_zip = zip_bytes({f"{platform['jdkRoot']}/{name}": content for name, content in {
            "bin/java.exe": pe(0x14C if wrong_machine else machine), "bin/server/jvm.dll": pe(machine),
            "lib/modules": b"fixture modules", "release": b'JAVA_VERSION="21.0.1"\n', "legal/java.base/LICENSE": b"fixture GPL"}.items()})
        platform["sha256"] = sha(runtime_zip)
        self.runtime_archive = jdk_cache / f"jdk-{safe(jdk['version'])}-{platform_name}-{platform['sha256']}.zip"
        self.runtime_archive.write_bytes(runtime_zip)
        for name, manifest in (("jdtls", jdt), ("jdk", jdk)):
            path = root / "third_party" / name / "manifest.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(manifest), encoding="utf-8")

    def assemble(self):
        return ASSEMBLY.assemble(self.root, self.architecture, self.output, time.monotonic() + 10)


def raises(kind, pattern, action):
    try:
        action()
    except kind as error:
        assert pattern in str(error), str(error)
    else:
        raise AssertionError(f"Expected {kind.__name__}: {pattern}")


def run_tests(report):
    tests = []

    def case(name, action):
        started = time.monotonic()
        try:
            action()
            status, detail = "passed", ""
        except Exception:
            status, detail = "failed", traceback.format_exc()
        tests.append({"name": name, "suite": "Windows Java offline assembly", "status": status,
                      "durationMs": (time.monotonic() - started) * 1000, "maxMs": 15000, "details": detail})
        print(f"{status}: {name}", flush=True)

    def assembled(architecture):
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch), architecture)
            receipt = fixture.assemble()
            assert receipt["status"] == "unsigned-candidate"
            assert receipt["requires"] == ASSEMBLY.REQUIRES
            assert receipt["architecture"] == architecture
            assert len(receipt["inputs"]) == 9
            assert f"runtime/{architecture}/bin/java.exe" in receipt["files"]
            assert f"language-server/configuration/{architecture}/config.ini" in receipt["files"]
            assert not (fixture.output / "lithe-plugin-signature.json").exists()
            for name, digest in receipt["files"].items():
                assert ASSEMBLY.digest(fixture.output / name, time.monotonic() + 2) == digest
            raises(ValueError, "already exists", fixture.assemble)

    def tamper():
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch))
            fixture.runtime_archive.write_bytes(b"replaced archive")
            raises(ValueError, "SHA-256 mismatch", fixture.assemble)
            assert not fixture.output.exists()

    def wrong_machine():
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch), wrong_machine=True)
            raises(ValueError, "PE architecture mismatch", fixture.assemble)
            assert not fixture.output.exists()
            assert not list(fixture.output.parent.glob(".assemble-*"))

    def full_requirements():
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch))
            path = fixture.root / ASSEMBLY.SOURCE / "plugin.json"
            manifest = json.loads(path.read_text())
            del manifest["requires"]["packageTrust"]
            path.write_text(json.dumps(manifest))
            raises(ValueError, "complete API/requirements", fixture.assemble)

    def fixed_identity():
        for target, field, value in (("plugin.json", "id", "other.java-support"), ("language-server.json", "sourceManifests", ["outside/manifest.json"])):
            with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
                fixture = Fixture(Path(scratch))
                path = fixture.root / ASSEMBLY.SOURCE / target
                changed = json.loads(path.read_text())
                changed[field] = value
                path.write_text(json.dumps(changed))
                raises(ValueError, "fixed source manifests", fixture.assemble)
                assert not fixture.output.exists()

    def archive_escape():
        for name in ("../outside", "C:/outside", "a\\outside", "NUL.txt", "server. "):
            raises(ValueError, "archive path", lambda name=name: ASSEMBLY.safe_name(name))
        with tempfile.TemporaryDirectory(prefix="lithe-java-archive-test-") as scratch:
            root = Path(scratch)
            archive = root / "bad.zip"
            archive.write_bytes(zip_bytes({"Entry.jar": b"one", "entry.jar": b"two"}))
            raises(ValueError, "Duplicate Windows archive path", lambda: ASSEMBLY.extract(archive, root / "out", time.monotonic() + 2))
            tar = root / "link.tar.gz"
            with tarfile.open(tar, "w:gz") as output:
                link = tarfile.TarInfo("server.jar")
                link.type, link.linkname = tarfile.SYMTYPE, "../outside"
                output.addfile(link)
            raises(ValueError, "link or special", lambda: ASSEMBLY.extract(tar, root / "tar-out", time.monotonic() + 2))

    def output_and_deadline():
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch))
            raises(ValueError, "new child", lambda: ASSEMBLY.assemble(fixture.root, "x86_64", fixture.root / "installed", time.monotonic() + 2))
            raises(TimeoutError, "deadline", lambda: ASSEMBLY.assemble(fixture.root, "x86_64", fixture.output, time.monotonic() - 1))

    def input_changed_during_assembly(source_change=False):
        with tempfile.TemporaryDirectory(prefix="lithe-java-assembly-test-") as scratch:
            fixture = Fixture(Path(scratch))
            original = ASSEMBLY.extract

            def replace_after_extract(archive, destination, deadline):
                original(archive, destination, deadline)
                if archive == fixture.runtime_archive:
                    target = fixture.root / ASSEMBLY.SOURCE / "templates/plain/src/Main.java" if source_change else archive
                    target.write_bytes(b"changed after input validation")

            with patch.object(ASSEMBLY, "extract", replace_after_extract):
                raises(ValueError, "changed during assembly", fixture.assemble)
            assert not fixture.output.exists()
            assert not list(fixture.output.parent.glob(".assemble-*"))

    case("x64 candidate keeps complete requires, fixed inputs, licenses and file inventory", lambda: assembled("x86_64"))
    case("ARM64 fixture selects Windows config and PE data without executing it", lambda: assembled("arm64"))
    case("changed cached archive fails before package publication", tamper)
    case("wrong runtime PE architecture fails and removes staging", wrong_machine)
    case("removing packageTrust cannot produce a candidate", full_requirements)
    case("package identity and fixed source manifest list cannot be replaced", fixed_identity)
    case("archive traversal, Windows aliases, duplicate files and symlinks fail closed", archive_escape)
    case("output scope and monotonic deadline are enforced", output_and_deadline)
    case("archive replacement after extraction cannot publish stale provenance", input_changed_during_assembly)
    case("source template replacement during assembly cannot publish mixed inputs", lambda: input_changed_during_assembly(True))
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"runner": "python", "warnMs": 1000, "maxMs": 15000, "tests": tests}, indent=2) + "\n", encoding="utf-8")
    return int(any(test["status"] != "passed" for test in tests))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / ".artifacts/test-stability/windows-java-assembly.json")
    raise SystemExit(run_tests(parser.parse_args().report))
