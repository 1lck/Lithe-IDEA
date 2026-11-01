#!/usr/bin/env python3
"""Disposable non-provider build packages derived from the canonical fixtures.

This module packages inputs, not a manifest validator or build interpreter.
Only the real install path/Core validates them. Generated community packages
are explicitly unsigned; hostIntegration keeps its official-signature prerequisite.
No input is installed, served, downloaded or executed by this generator.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CONTRACTS = ROOT / "shared/contracts/plugins/v1/fixtures"
TOOL = Path(__file__).with_name("fake-build-tool.mjs")
PREFIX = "io.github.lithe-acceptance.build"
VARIANTS = (
    ("static-project", "build-static-file.plugin.json", "projectFile"),
    ("stdout-environment", "build-command-stdout.plugin.json", "environment"),
    ("output-command", "build-command-output-file.plugin.json", "command"),
    ("stdout-runtime", "build-command-stdout.plugin.json", "runtime"),
    ("output-setting", "build-command-output-file.plugin.json", "setting"),
    ("output-legacy", "build-command-output-file.plugin.json", "executableSetting"),
)
COMMAND = "lithe-build-acceptance.cmd"
TOOL_RELATIVE = ".lithe-acceptance/fake-build-tool.mjs"

def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def ordinary_tree(root: Path) -> dict[str, str]:
    """Compare exact bytes and refuse links, including directory junctions."""
    if root.is_symlink() or root.is_junction():
        raise ValueError("acceptance resource root cannot be a link")
    root = root.resolve(strict=True)
    result = {}
    directories = [root]
    while directories:
        for path in sorted(directories.pop().iterdir()):
            if path.is_symlink() or path.is_junction():
                raise ValueError("acceptance resources must be ordinary files/directories")
            if path.is_dir():
                directories.append(path)
            elif path.is_file():
                if root not in path.resolve(strict=True).parents:
                    raise ValueError("acceptance resource escaped its root")
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                result[path.relative_to(root).as_posix()] = digest.hexdigest()
    return result


def declaration(variant: str, marker: str) -> tuple[dict, str, str]:
    _, source_name, candidate = next(item for item in VARIANTS if item[0] == variant)
    source = json.loads((CONTRACTS / source_name).read_text(encoding="utf-8"))
    manifest = copy.deepcopy(source)
    manifest.update(id=f"{PREFIX}.{variant}", displayName=f"Lithe Build Acceptance {variant}", version="1.0.0")
    manifest["vendor"] = {"id": "io.github.lithe-acceptance", "displayName": "Unsigned acceptance fixture",
                          "signatureRequirement": "none"}
    system = manifest["buildSystems"][0]
    system["displayName"] = manifest["displayName"]
    # The source declaration still owns maps, filters, report locations and
    # option semantics. Only deterministic test-tool discovery is substituted.
    invocation = system["invocation"]
    invocation.pop("runtimeDependencies", None)
    invocation.pop("environmentInputs", None)
    invocation["version"] = {"arguments": ["--version"], "pattern": r"Lithe Build Acceptance (\d+\.\d+\.\d+)"}
    invocation["minimumVersion"] = "1.0.0"
    executable = {"projectFile": {"kind": "projectFile", "path": f".lithe-acceptance/{COMMAND}"},
                  "environment": {"kind": "environment", "variable": "LITHE_ACCEPTANCE_TOOL_HOME", "path": f"bin/{COMMAND}"},
                  "command": {"kind": "command", "command": COMMAND},
                  "runtime": {"kind": "runtime", "runtime": "node"},
                  "setting": {"id": "selected", "kind": "setting", "settingID": "toolPath"},
                  "executableSetting": {"kind": "command", "command": COMMAND}}[candidate]
    invocation["executables"] = [executable]
    invocation["globalArguments"] = ["--fixture-marker", marker, *invocation.get("globalArguments", [])]
    reports = json.loads((CONTRACTS / "build-command-output-file.plugin.json").read_text(encoding="utf-8"))["buildSystems"][0]["test"]["results"]
    system["test"]["results"] = copy.deepcopy(reports)
    if "dependencies" not in system:
        system["dependencies"] = copy.deepcopy(json.loads((CONTRACTS / "build-command-stdout.plugin.json").read_text(encoding="utf-8"))["buildSystems"][0]["dependencies"])
    if candidate == "environment":
        invocation["environmentInputs"] = ["LITHE_ACCEPTANCE_TOOL_HOME"]
    if candidate in ("setting", "executableSetting"):
        manifest["requires"]["settings"] = 2
        manifest["settings"] = [{"id": "toolPath", "type": "file", "title": "Fixture tool",
                                 "default": "", "scope": "global", "effect": "reload",
                                 "page": {"buildSystemID": system["id"]}}]
        # A following working command is a trap: configured failure must be terminal.
        if candidate == "setting":
            manifest["requires"]["executableResolution"] = 1
            invocation["executables"].append({"kind": "command", "command": COMMAND})
        else:
            manifest["requires"]["buildSystems"] = 2
            invocation["executableSetting"] = "toolPath"
    if candidate == "runtime":
        invocation["runtimeDependencies"] = [{"id": "node", "minimumVersion": "18.0.0"}]
        invocation["version"]["pattern"] = r"v(\d+\.\d+\.\d+)"
        invocation["minimumVersion"] = "18.0.0"
        invocation["globalArguments"] = [TOOL_RELATIVE, *invocation.get("globalArguments", [])]
    return manifest, source_name, candidate


def write_archive(path: Path, files: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data)


def generate_fixture(output: Path) -> dict:
    # Disposable run inputs have no reusable cache identity. Never clear a
    # previous run, share node_modules/target, or write an installed resource.
    if output.is_symlink() or output.is_junction():
        raise ValueError("fixture output cannot be a link")
    output.mkdir(parents=True, exist_ok=False)
    packages = output / "packages"
    packages.mkdir()
    tools = output / "tools with spaces" / "bin"
    tools.mkdir(parents=True)
    tool_data = TOOL.read_bytes()
    (tools / TOOL.name).write_bytes(tool_data)
    variants = []
    for variant, _, _ in VARIANTS:
        workspace = output / "workspaces" / variant
        workspace.mkdir(parents=True)
        (workspace / ".lithe-acceptance").mkdir()
        (workspace / ".lithe-acceptance" / TOOL.name).write_bytes(tool_data)
        (workspace / "nested").mkdir()
        (workspace / "src").mkdir()
        (workspace / "src/main.rs").write_text("fn main() {}\n", encoding="utf-8")
        (workspace / "src/main.go").write_text("package main\nfunc main() {}\n", encoding="utf-8")
        (workspace / "src/Main.java").write_text("class Main {}\n", encoding="utf-8")
        (workspace / "acceptance.build.txt").write_text("saved-before-build\n", encoding="utf-8")
        (workspace / "Cargo.toml").write_text('[package]\nname="fixture-app"\nversion="1.0.0"\n[features]\nweb=[]\n', encoding="utf-8")
        (workspace / "go.mod").write_text("module fixture-app\n\ngo 1.21\n", encoding="utf-8")
        (workspace / "build.gradle").write_text("// deterministic controlled acceptance input\n", encoding="utf-8")
        (workspace / "settings.gradle").write_text("rootProject.name='fixture-app'\n", encoding="utf-8")
        archives = {}
        for marker in ("a", "b"):
            manifest, source, candidate = declaration(variant, marker)
            archive = packages / f"{variant}-{marker}.zip"
            write_archive(archive, {"plugin.json": json_bytes(manifest), "fixture-marker.txt": (marker + "\n").encode(),
                                    "lithe-model.init.gradle": b"// Fake tool consumes this declared input; never a Gradle implementation.\n"})
            archives[marker] = {"path": archive.relative_to(output).as_posix(),
                                "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        wrapper = f'@echo off\r\nnode "%~dp0fake-build-tool.mjs" --fixture-marker a %*\r\n'.encode()
        (workspace / ".lithe-acceptance" / COMMAND).write_bytes(wrapper)
        variants.append({"id": variant, "pluginId": manifest["id"], "displayName": manifest["displayName"],
                         "buildSystemId": manifest["buildSystems"][0]["id"], "sourceFixture": source,
                         "sourceSha256": hashlib.sha256((CONTRACTS / source).read_bytes()).hexdigest(),
                         "candidate": candidate, "requires": manifest["requires"],
                         "workspace": workspace.relative_to(output).as_posix(), "archives": archives})
    (tools / COMMAND).write_bytes(f'@echo off\r\nnode "%~dp0fake-build-tool.mjs" --fixture-marker a %*\r\n'.encode())
    official = output / "workspaces" / "host-integration"
    official.mkdir()
    (official / "pom.xml").write_text('<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>'
                                     '<groupId>fixture</groupId><artifactId>acceptance</artifactId><version>1.0.0</version></project>\n', encoding="utf-8")
    plan = {"schemaVersion": 1, "variants": variants, "tools": "tools with spaces/bin",
            "trust": "unsigned third-party disk import; real native review/approval required",
            "hostIntegration": {"sourceFixture": "build-host-integration.plugin.json", "workspace": "workspaces/host-integration",
                                "prerequisite": "A genuine official publisher-signed Maven plugin archive and installed JDK/Maven; never generate or trust an acceptance key."}}
    (output / "plan.json").write_bytes(json_bytes(plan))
    return plan


def load_plan(root: Path) -> dict:
    plan = json.loads((root / "plan.json").read_text(encoding="utf-8"))
    if (plan.get("schemaVersion") != 1 or len(plan.get("variants", [])) != len(VARIANTS)
            or {v.get("id") for v in plan.get("variants", [])} != {v[0] for v in VARIANTS}):
        raise ValueError("unsupported or incomplete build fixture plan")
    for variant in plan["variants"]:
        expected, source, candidate = declaration(variant["id"], "a")
        if (variant["pluginId"] != expected["id"] or variant["requires"] != expected["requires"]
                or variant["displayName"] != expected["displayName"] or variant["workspace"] != f"workspaces/{variant['id']}"
                or variant["sourceFixture"] != source or variant["candidate"] != candidate
                or variant["sourceSha256"] != hashlib.sha256((CONTRACTS / source).read_bytes()).hexdigest()):
            raise ValueError("fixture plan no longer matches its canonical source")
        if set(variant["archives"]) != {"a", "b"}:
            raise ValueError("both same-version package snapshots are required")
        for marker, asset in variant["archives"].items():
            path = confined(root, asset["path"])
            if marker not in ("a", "b") or hashlib.sha256(path.read_bytes()).hexdigest() != asset["sha256"]:
                raise ValueError("fixture archive digest changed")
            with zipfile.ZipFile(path) as archive:
                if json.loads(archive.read("plugin.json")) != declaration(variant["id"], marker)[0]:
                    raise ValueError("fixture manifest changed")
    ordinary_tree(root)
    return plan


def tool_script(root: Path, variant: dict) -> Path:
    # Project-file and runtime declarations use the workspace script; external
    # candidates run the script beside their shared, generated cmd wrapper.
    relative = (f"{variant['workspace']}/{TOOL_RELATIVE}"
                if variant["candidate"] in ("projectFile", "runtime")
                else f"tools with spaces/bin/{TOOL.name}")
    return confined(root, relative)


def confined(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or relative.startswith("/") or "\\" in relative or re.match(r"^[A-Za-z]:", relative):
        raise ValueError("fixture paths must be relative POSIX paths")
    path = Path(relative)
    if path.is_absolute() or any(part in ("", ".", "..") for part in relative.split("/")):
        raise ValueError("fixture paths cannot traverse")
    target = root.resolve() / path
    cursor = target
    while cursor != root.resolve():
        if cursor.is_symlink() or cursor.is_junction():
            raise ValueError("fixture paths cannot contain links")
        if cursor.parent == cursor:
            raise ValueError("fixture path is not below its root")
        cursor = cursor.parent
    if root.resolve() not in target.resolve(strict=True).parents:
        raise ValueError("fixture path escaped its root")
    return target.resolve(strict=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    print(json.dumps(generate_fixture(arguments.output), indent=2))
