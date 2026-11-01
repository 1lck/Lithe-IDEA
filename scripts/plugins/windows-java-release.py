#!/usr/bin/env python3
"""Windows Java release route: immutable inputs, offline assembly, existing signer.

No signing implementation or trust keys live here. Rehearsal never reads a key.
Note: .agents/notes/implemented/architecture/2026-10-25-java-plugin-distribution-foundation.md
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SIGNATURE = "lithe-plugin-signature.json"
PLUGIN = "dev.lithe.plugin.java-support"


def run(command, root, deadline, *, input_bytes=None):
    remaining = min(60, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Release route exceeded its local deadline")
    environment = {name: os.environ[name] for name in os.environ if name != "LITHE_PLUGIN_PACKAGE_PRIVATE_KEY"}
    if os.name == "nt" and Path(command[0]).name == "node":
        # Planning spawns Git. Reuse the existing retained Windows process-tree
        # owner instead of killing only Node and abandoning a Git descendant.
        helper = ROOT / "scripts/plugins/host-acceptance/acceptance_driver.py"
        if "release_process_owner" not in sys.modules:
            spec = importlib.util.spec_from_file_location("release_process_owner", helper)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
        owned = [command[0], str((root / command[1]).resolve()), *command[2:]]
        result = sys.modules["release_process_owner"].run_bounded_process(owned, remaining)
        result.stdout = result.stdout.encode("utf-8")
        result.stderr = result.stderr.encode("utf-8")
    elif os.name != "nt":
        # A private POSIX process group owns the signer/planner and descendants.
        process = subprocess.Popen(command, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=environment, start_new_session=True)
        try:
            stdout, stderr = process.communicate(input_bytes, timeout=remaining)
            result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=2)
    else:
        # Native Git plumbing is a bounded leaf on Windows. Publisher signing
        # is admitted only on macOS and never reaches this path.
        result = subprocess.run(command, cwd=root, input=input_bytes, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=remaining, check=False, env=environment)
    if result.returncode:
        diagnostic = ""
        if Path(command[0]).name in {"git", "node"}:
            diagnostic = ": " + result.stderr.decode("utf-8", errors="replace")[-2000:]
        raise ValueError(f"Release tool failed: {Path(command[0]).name} (exit {result.returncode}){diagnostic}")
    return result.stdout


def frozen_plan(root, plan, deadline):
    if not isinstance(plan, dict) or not isinstance(plan.get("revision"), str) or len(plan["revision"]) != 40:
        raise ValueError("Expected a frozen immutable release plan")
    if any(c not in "0123456789abcdef" for c in plan["revision"]):
        raise ValueError("Invalid release revision")
    expected = json.loads(run(["node", "scripts/plugins/official-plugin-releases.mjs", "freeze", PLUGIN, plan["revision"]], root, deadline))
    if expected != plan or plan["id"] != PLUGIN:
        raise ValueError("Plan differs from the immutable revision (assets, sources or metadata replaced)")
    windows = [asset for asset in plan["assets"] if asset["os"] == "windows"]
    if {asset["arch"] for asset in windows} != {"arm64", "x86_64"} or len(windows) != 2:
        raise ValueError("Expected both Windows release architectures")
    return windows


def export_inputs(root, plan, destination, deadline):
    # Git exports raw blob bytes, so CRLF checkout conversion cannot silently
    # change the signed manifest, templates, licenses or build implementation.
    queries = "".join(f"{plan['revision']}:{name}\n" for name in plan["inputFiles"])
    blobs = run(["git", "cat-file", "--batch"], root, deadline, input_bytes=queries.encode("utf-8"))
    offset = 0
    for name, expected in plan["inputFiles"].items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
            raise ValueError("Unsafe frozen input path")
        end = blobs.index(b"\n", offset)
        header = blobs[offset:end].split()
        if len(header) != 3 or header[1] != b"blob":
            raise ValueError("Frozen input is not a Git blob")
        size = int(header[2])
        content = blobs[end+1:end+1+size]
        offset = end+2+size
        if len(content) != size or offset > len(blobs):
            raise ValueError("Truncated frozen Git input")
        if hashlib.sha256(content).hexdigest() != expected:
            raise ValueError(f"Frozen input SHA-256 mismatch: {name}")
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    spec = importlib.util.spec_from_file_location("frozen_java_assembly", destination / "scripts/plugins/assemble-windows-java-support.py")
    assembly = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(assembly)
    return assembly


def fetch_inputs(assembly, source, root, assets, deadline):
    """Explicit network stage, separate from offline assembly. Never replaces cache."""
    for asset in assets:
        for entry in assembly.pinned_inputs(source, asset["arch"], root):
            target = root / ".artifacts" / entry["cache"] / entry["name"]
            if target.parent != target.parent.resolve():
                raise ValueError("Download cache must not traverse directory aliases")
            if target.exists():
                if assembly.digest(target, deadline) != entry["sha256"]:
                    raise ValueError(f"Existing pinned cache is corrupt: {entry['name']}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".release-download-", dir=target.parent) as temporary:
                downloaded = Path(temporary) / "input"
                assembly.check_deadline(deadline)
                with urllib.request.urlopen(entry["url"], timeout=min(30, max(1, deadline - time.monotonic()))) as response:
                    if not response.geturl().startswith("https://"):
                        raise ValueError("Pinned download redirected outside HTTPS")
                    with downloaded.open("xb") as stream:
                        total = 0
                        while chunk := response.read(1024 * 1024):
                            assembly.check_deadline(deadline)
                            total += len(chunk)
                            if total > assembly.MAX_EXPANDED_BYTES:
                                raise ValueError("Pinned download exceeded byte budget")
                            stream.write(chunk)
                if assembly.digest(downloaded, deadline) != entry["sha256"]:
                    raise ValueError("Downloaded input SHA-256 mismatch")
                # Publish atomically and exclusively on this same filesystem.
                # The temporary name is removed on exit; this never links caches
                # between worktrees or overwrites another publisher's file.
                os.link(downloaded, target)
                if assembly.digest(target, deadline) != entry["sha256"]:
                    raise ValueError("Published input SHA-256 mismatch")



def signer_call(signer, package, root, deadline, *, sign=False):
    if sys.platform != "darwin":
        raise ValueError("Official publisher verification requires the existing controlled macOS signer")
    if not signer or not Path(signer).is_file() or Path(signer).name != "LithePluginPackageSigner":
        raise ValueError("Supply the existing LithePluginPackageSigner executable")
    key = None
    if sign:
        key = os.environ.get("LITHE_PLUGIN_PACKAGE_PRIVATE_KEY", "").encode()
        if not key:
            raise ValueError("Official publisher key is unavailable in the controlled environment")
    run([str(Path(signer).resolve()), *([] if sign else ["--verify"]), str(package)], root, deadline, input_bytes=key)


def require_inventory(expected, actual, label):
    if expected != actual:
        raise ValueError(f"{label}: added={sorted(actual.keys()-expected.keys())}, removed={sorted(expected.keys()-actual.keys())}, changed={sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])}")


def make_zip(assembly, package, archive, plugin_id, deadline):
    before = assembly.file_inventory(package, deadline)
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for name in before:
            assembly.check_deadline(deadline)
            info = zipfile.ZipInfo(f"{plugin_id}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            with (package / name).open("rb") as stream, output.open(info, "w") as destination:
                while chunk := stream.read(1024 * 1024):
                    assembly.check_deadline(deadline)
                    destination.write(chunk)
    require_inventory(before, assembly.file_inventory(package, deadline), "Package changed during ZIP assembly")


def verify_zip(assembly, archive, extracted, plan, asset, expected, root, deadline, signer, verify):
    initial_hash = assembly.digest(archive, deadline)
    assembly.extract(archive, extracted, deadline)
    children = list(extracted.iterdir())
    if len(children) != 1 or children[0].name != plan["id"] or not children[0].is_dir():
        raise ValueError("ZIP must contain exactly the planned plugin directory")
    package = children[0]
    actual = assembly.file_inventory(package, deadline)
    unsigned = {name: value for name, value in actual.items() if name != SIGNATURE}
    require_inventory(expected, unsigned, "ZIP differs from pinned offline assembly")
    if actual.get("plugin.json") != asset["manifestSHA256"]:
        raise ValueError("ZIP manifest differs from the tagged platform manifest")
    if verify:
        if SIGNATURE not in actual:
            raise ValueError("Signed release ZIP has no publisher signature")
        verify(signer, package, root, deadline)
    elif SIGNATURE in actual:
        raise ValueError("Unsigned rehearsal cannot accept a signature document")
    require_inventory(actual, assembly.file_inventory(package, deadline), "Verifier changed extracted bytes")
    if initial_hash != assembly.digest(archive, deadline):
        raise ValueError("ZIP changed during independent verification")
    return initial_hash, actual


def execute(root, plan, mode, output, deadline, signer=None, architecture=None, *, verify=signer_call):
    assets = frozen_plan(root, plan, deadline)
    if architecture:
        if mode != "rehearse":
            raise ValueError("Only rehearsal permits an explicitly incomplete architecture selection")
        assets = [asset for asset in assets if asset["arch"] == architecture]
    allowed = root / ".artifacts/windows-java-support"
    output = output.absolute()
    if (output != output.resolve() or not output.is_relative_to(allowed.resolve()) or output == allowed.resolve()
            or (mode != "verify" and output.exists())):
        raise ValueError("Output must be a plain new child of .artifacts/windows-java-support (existing assets only for verify)")
    if mode == "verify" and not output.is_dir():
        raise ValueError("Verify requires a complete existing asset directory")
    allowed.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=allowed) as temporary:
        scratch = Path(temporary)
        source = scratch / "source"
        assembly = export_inputs(root, plan, source, deadline)
        if any(asset["packageDirectory"] != assembly.SOURCE.as_posix() for asset in assets):
            raise ValueError("Windows release packageDirectory does not match the frozen assembler source")
        if mode == "prepare":
            fetch_inputs(assembly, source, root, assets, deadline)
        missing = []
        inputs = {}
        for asset in assets:
            entries = assembly.pinned_inputs(source, asset["arch"], root)
            inputs[asset["arch"]] = entries
            for entry in entries:
                path = root / ".artifacts" / entry["cache"] / entry["name"]
                if not path.exists():
                    missing.append({"architecture": asset["arch"], **entry})
                elif assembly.digest(path, deadline) != entry["sha256"]:
                    raise ValueError(f"Pinned cache SHA-256 mismatch: {entry['name']}")
        result = {"schemaVersion": 1, "kind": "windows-java-release", "mode": mode,
                  "revision": plan["revision"], "tag": plan["tag"], "pluginId": plan["id"], "version": plan["version"],
                  "complete": len(assets) == 2 and not missing, "productionAdmission": False,
                  "publisherVerification": "not-performed", "inputFiles": plan["inputFiles"], "inputs": inputs,
                  "missingInputs": missing, "assets": []}
        if mode in {"preflight", "prepare"}:
            return result
        if missing:
            raise ValueError("Missing pinned offline inputs: " + ", ".join(entry["name"] for entry in missing))
        publish = scratch / "assets"
        publish.mkdir()
        if mode == "verify":
            expected_names = {asset["assetName"] for asset in assets}
            if {path.name for path in output.glob("*.zip")} != expected_names:
                raise ValueError("Expected exactly the complete Windows release asset set")
        for asset in assets:
            package = scratch / asset["arch"] / plan["id"]
            receipt = assembly.assemble(source, asset["arch"], package, deadline, cache_root=root, output_root=root)
            expected = assembly.file_inventory(package, deadline)
            if expected.get("plugin.json") != asset["manifestSHA256"] or receipt["requires"] != asset.get("requires"):
                raise ValueError("Assembly does not match the platform manifest in the immutable plan")
            if mode == "package":
                verify(signer, package, root, deadline, sign=True)
                verify(signer, package, root, deadline)
                signed = assembly.file_inventory(package, deadline)
                if SIGNATURE not in signed:
                    raise ValueError("Signer did not produce a signature document")
                require_inventory(expected, {name: value for name, value in signed.items() if name != SIGNATURE}, "Signer changed original inputs")
            archive = (output if mode == "verify" else publish) / asset["assetName"]
            if mode != "verify":
                make_zip(assembly, package, archive, plan["id"], deadline)
            sha256, files = verify_zip(assembly, archive, scratch / f"extract-{asset['arch']}", plan, asset,
                                      expected, root, deadline, signer, verify if mode != "rehearse" else None)
            result["assets"].append({"assetName": asset["assetName"], "platforms": asset["platforms"],
                "architecture": asset["arch"], "packageDirectory": asset["packageDirectory"],
                "manifestSHA256": asset["manifestSHA256"], "pluginAPIVersion": asset["pluginAPIVersion"], "requires": asset.get("requires"),
                "sha256": sha256, "signatureSHA256": files.get(SIGNATURE), "files": files, "inputs": receipt["inputs"]})
            if mode != "verify":
                (publish / f"{asset['assetName']}.sha256").write_text(sha256 + "\n", encoding="utf-8")
        if mode in {"package", "verify"}:
            result["publisherVerification"] = "verified-existing-signer"
        # Recheck original caches after both architectures. A coherent receipt
        # from the first assembly must not conceal input replacement later.
        for entries in inputs.values():
            for entry in entries:
                if assembly.digest(root / ".artifacts" / entry["cache"] / entry["name"], deadline) != entry["sha256"]:
                    raise ValueError("Pinned inputs changed during release")
        if mode != "verify":
            (publish / "windows-java-release.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            assembly.check_deadline(deadline)
            output.parent.mkdir(parents=True, exist_ok=True)
            os.rename(publish, output)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("preflight", "prepare", "rehearse", "package", "verify"))
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--signer", type=Path)
    parser.add_argument("--architecture", choices=("x86_64", "arm64"))
    parser.add_argument("--timeout-seconds", type=int, choices=range(1, 1201), default=600, metavar="1..1200")
    args = parser.parse_args()
    report, output = args.report.absolute(), args.output.absolute()
    if report.exists() or report != report.resolve() or not report.is_relative_to(ROOT / ".artifacts") or report.is_relative_to(output):
        parser.error("Report must be a new plain .artifacts file outside the output")
    deadline = time.monotonic() + args.timeout_seconds
    try:
        result = execute(ROOT, json.loads(args.plan.read_text(encoding="utf-8-sig")), args.mode, output, deadline, args.signer, args.architecture)
        code = 2 if result["missingInputs"] else 0
    except (ValueError, OSError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError) as error:
        result = {"schemaVersion": 1, "kind": "windows-java-release", "mode": args.mode,
                  "status": "failed", "productionAdmission": False, "publisherVerification": "not-performed", "error": str(error)}
        code = 1
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps({key: result[key] for key in ("mode", "productionAdmission", "publisherVerification")}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
