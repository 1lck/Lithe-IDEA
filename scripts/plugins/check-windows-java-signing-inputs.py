#!/usr/bin/env python3
"""Prepare Windows Java signing handoff; never sign, authenticate or admit a package.

Rebuild from pinned offline inputs using the existing assembler. A before/after
inventory proves byte preservation only. Publisher verification belongs to the
existing LithePluginPackageSigner and the production Windows host.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "windows_java_assembly", Path(__file__).with_name("assemble-windows-java-support.py"))
ASSEMBLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSEMBLY)
ROOT = Path(__file__).resolve().parents[2]
SIGNATURE = "lithe-plugin-signature.json"
RECEIPT = "windows-java-inputs.json"
# Freeze the existing trust implementation and release description as handoff
# inputs; this tool has no copy of the canonical signing payload or public keys.
RELEASE_INPUTS = (
    "Plugins/marketplace/official-plugins.json",
    "scripts/plugins/official-plugin-releases.mjs",
    ".github/workflows/release-official-plugins.yml",
    "macos/Tools/LithePluginPackageSigner/main.swift",
    "macos/Sources/LithePluginPackageSigning/PluginPackageSignature.swift",
    "windows/tauri/src-tauri/src/plugin_host/signature.rs",
)


def release_gaps(root, plugin_id, architecture):
    config = ASSEMBLY.read_json(root / RELEASE_INPUTS[0])
    entry = next((item for item in config["plugins"] if item["id"] == plugin_id), None)
    gaps = []
    if entry is None:
        return ["official-release-entry-missing"]
    if entry.get("releaseEnabled") is False:
        gaps.append("official-release-disabled")
    if entry.get("packageDirectory") != ASSEMBLY.SOURCE.as_posix():
        gaps.append("official-release-package-directory-is-not-windows")
    platform = {"x86_64": "windows-x64", "arm64": "windows-arm64"}[architecture]
    if not any(platform in asset["platforms"] for asset in entry.get("assets", [])):
        gaps.append("official-release-windows-asset-missing")
    return gaps


def difference(expected, actual):
    return {"added": sorted(actual.keys() - expected.keys()),
            "removed": sorted(expected.keys() - actual.keys()),
            "changed": sorted(name for name in expected.keys() & actual.keys()
                              if expected[name] != actual[name])}


def require_equal(expected, actual, label):
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        raise ValueError(f"{label}: expected file inventory objects")
    delta = difference(expected, actual)
    if any(delta.values()):
        raise ValueError(f"{label}: {json.dumps(delta, sort_keys=True)}")


def check(root, candidate, phase, baseline, deadline):
    root, candidate = root.resolve(), candidate.absolute()
    allowed = root / ".artifacts/windows-java-support"
    if (candidate != candidate.resolve() or not candidate.is_relative_to(allowed)
            or candidate == allowed):
        raise ValueError("Candidate must be a plain child of this worktree's .artifacts/windows-java-support")
    if phase not in {"before-signing", "after-signing"}:
        raise ValueError("Unknown signing handoff phase")
    if (phase == "after-signing") != (baseline is not None):
        raise ValueError("Only after-signing requires a before-signing baseline")
    before = ASSEMBLY.file_inventory(candidate, deadline)
    signed = SIGNATURE in before
    if signed != (phase == "after-signing"):
        raise ValueError("before-signing requires unsigned input; after-signing requires a signature document")
    receipt = ASSEMBLY.read_json(candidate / RECEIPT)
    if (not isinstance(receipt, dict) or receipt.get("schemaVersion") != 1 or receipt.get("status") != "unsigned-candidate"
            or receipt.get("platform") != "windows" or receipt.get("architecture") not in {"x86_64", "arm64"}):
        raise ValueError("Unsupported Windows Java candidate receipt")
    architecture = receipt["architecture"]
    files = {name: value for name, value in before.items() if name != SIGNATURE}
    require_equal(receipt["files"], {name: value for name, value in files.items() if name != RECEIPT},
                  "Candidate differs from its receipt")
    release_paths = {name: root / name for name in RELEASE_INPUTS}
    release_paths.update({"scripts/plugins/assemble-windows-java-support.py": Path(ASSEMBLY.__file__),
                          "scripts/plugins/check-windows-java-signing-inputs.py": Path(__file__)})
    release_inputs = {name: ASSEMBLY.digest(path, deadline) for name, path in release_paths.items()}
    if baseline is not None:
        if (not isinstance(baseline, dict) or baseline.get("schemaVersion") != 1 or baseline.get("kind") != "windows-java-signing-handoff"
                or baseline.get("phase") != "before-signing" or baseline.get("inputCheck") != "passed"
                or baseline.get("architecture") != architecture):
            raise ValueError("Expected a successful before-signing baseline for the same architecture")
        require_equal(baseline["candidateFiles"], files, "Package changed since before-signing")
        require_equal(baseline["releaseInputs"], release_inputs, "Release inputs changed since before-signing")
    # A mutable receipt is not provenance. Reuse assembly, including archive,
    # license, upstream bundle and PE checks, to independently reconstruct it.
    with tempfile.TemporaryDirectory(prefix=".signing-check-", dir=allowed) as scratch:
        rebuilt = Path(scratch) / "candidate"
        reconstructed = ASSEMBLY.assemble(root, architecture, rebuilt, deadline)
        require_equal(ASSEMBLY.file_inventory(rebuilt, deadline), files,
                      "Candidate differs from pinned offline reconstruction")
    require_equal(before, ASSEMBLY.file_inventory(candidate, deadline), "Candidate changed while checking")
    jdt = ASSEMBLY.read_json(root / "third_party/jdtls/manifest.json")
    jdk = ASSEMBLY.read_json(root / "third_party/jdk/manifest.json")
    policy = ASSEMBLY.read_json(candidate / "language-server.json")
    target = policy["architectures"][architecture]
    gaps = release_gaps(root, reconstructed["pluginId"], architecture)
    require_equal(release_inputs, {name: ASSEMBLY.digest(path, deadline) for name, path in release_paths.items()},
                  "Release inputs changed while checking")
    require_equal(reconstructed["sourceManifests"], {
        name: ASSEMBLY.digest(root / name, deadline) for name in reconstructed["sourceManifests"]},
        "Source manifests changed while checking")
    return {
        "schemaVersion": 1, "kind": "windows-java-signing-handoff", "phase": phase,
        "inputCheck": "passed", "architecture": architecture,
        "pluginId": reconstructed["pluginId"], "version": reconstructed["version"],
        "requires": reconstructed["requires"],
        "originPolicy": "publisherPackage", "candidateFiles": files,
        "sourceManifests": reconstructed["sourceManifests"], "inputs": reconstructed["inputs"],
        "releaseInputs": release_inputs,
        "upstream": {"jdtVersion": jdt["version"], "jdkManifestVersion": jdk["version"],
                     "jdkPlatform": target["jdkPlatform"], "jdkRoot": jdk["platforms"][target["jdkPlatform"]]["jdkRoot"],
                     "peMachine": target["peMachine"], "nativeImageCount": len(reconstructed["runtimeImages"]),
                     "licenseFiles": sorted(name for name in files if "LICENSE" in name or "/legal/" in name)},
        "signatureDocumentPresent": signed,
        "signatureDocumentSHA256": before.get(SIGNATURE),
        "publisherVerification": "not-performed-use-existing-LithePluginPackageSigner",
        "productionAdmission": False, "runtimeExecuted": False,
        "releaseConfigurationGaps": gaps,
        "remainingPublisherActions": [
            "Supply the official private key through the existing signer's stdin in the publisher environment; no key was inspected here.",
            "Run LithePluginPackageSigner on the frozen candidate, then --verify on the signed directory and independently extracted archive.",
            "Run after-signing against this before-signing baseline; only lithe-plugin-signature.json may be added.",
            "Hash the final ZIP using SHA-256 and bind it to the exact release revision, platform and asset name using official-plugin-releases.mjs.",
            "Add and review the Windows release route before any publication; current workflow cannot release this Windows candidate.",
            "Keep production packageTrust closed until the signed complete package and real Windows Java lifecycle are accepted.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--phase", choices=("before-signing", "after-signing"), required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, choices=range(1, 1201), default=300, metavar="1..1200")
    args = parser.parse_args()
    report = args.report.absolute()
    if (not report.resolve().is_relative_to(ROOT / ".artifacts")
            or report.resolve().is_relative_to(args.candidate.resolve()) or report.exists()):
        parser.error("Report must be a new .artifacts file outside the candidate")
    deadline = time.monotonic() + args.timeout_seconds
    try:
        result = check(ROOT, args.candidate, args.phase,
                       ASSEMBLY.read_json(args.baseline) if args.baseline else None, deadline)
        code = 0
    except (ValueError, OSError, KeyError, TypeError, TimeoutError) as error:
        result = {"schemaVersion": 1, "kind": "windows-java-signing-handoff", "phase": args.phase,
                  "inputCheck": "failed", "productionAdmission": False,
                  "publisherVerification": "not-performed", "runtimeExecuted": False, "error": str(error)}
        code = 1
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open("x", encoding="utf-8") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps({"inputCheck": result["inputCheck"], "productionAdmission": False, "report": str(report)}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
