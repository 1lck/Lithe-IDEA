#!/usr/bin/env python3
"""Disposable settings-only inputs; never rewrite a published package's requires.

The Node SDK sample is an audited, blocked external prerequisite, not the source
of this deliberately unsigned controlled fixture. No download or SDK execution
occurs here. Use the normal native install review to validate generated ZIPs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path

from build_fixture import ROOT, confined, json_bytes, ordinary_tree, write_archive

PLUGIN_ID = "io.github.lithe-acceptance.settings"
DISPLAY_NAME = "Lithe Settings Acceptance"
LOCK = Path(__file__).with_name("settings_functions_inputs.json")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def declaration(version: str) -> dict:
    # A new test package with its own identity and no executable contributions.
    # It is not a reduced copy of settings-v2 or an external Provider package.
    return {
        "schemaVersion": 2, "id": PLUGIN_ID, "displayName": DISPLAY_NAME,
        "version": version, "pluginAPIVersion": 3,
        "requires": {"languages": 1, "settings": 2},
        "vendor": {"id": "io.github.lithe-acceptance", "displayName": "Unsigned controlled fixture",
                   "signatureRequirement": "none"},
        "permissions": [], "activationEvents": ["onLanguage:lithesettingsaccept"],
        "languages": [{"id": "lithesettingsaccept", "displayName": DISPLAY_NAME,
                       "fileExtensions": ["lithesettingsaccept"]}],
        "settings": [
            {"id": "message", "title": "Acceptance message", "type": "text", "default": "default",
             "scope": "project", "effect": "nextRun", "pattern": ".*", "maxLength": 64},
            {"id": "reload", "title": "Acceptance reload", "type": "text", "default": "default",
             "scope": "project", "effect": "reload", "pattern": ".*", "maxLength": 64,
             "page": {"languageID": "lithesettingsaccept"}, "section": "Acceptance"},
        ],
    }


def check_output_path(output: Path) -> None:
    # Must use the existing run-owned exclusion; no new transferable cache.
    parent = ROOT / ".artifacts/plugin-host-acceptance"
    if parent.resolve() not in output.resolve().parents:
        raise ValueError("fixture output must be below .artifacts/plugin-host-acceptance")
    if not output.resolve().relative_to(parent.resolve()).parts[0].startswith("settings-functions-fixture"):
        raise ValueError("use a dedicated settings-functions-fixture directory, outside resettable run state")
    for path in (output, *output.parents):
        if path.is_symlink() or path.is_junction():
            raise ValueError("fixture output cannot traverse a link or junction")


def source_revision() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                          text=True, check=True, timeout=10).stdout.strip()


def generate(output: Path) -> dict:
    check_output_path(output)
    output.mkdir(parents=True, exist_ok=False)
    archives = {}
    for version in ("1.0.0", "1.1.0"):
        path = output / f"settings-{version}.zip"
        write_archive(path, {"plugin.json": json_bytes(declaration(version)),
                             "fixture-version.txt": (version + "\n").encode()})
        archives[version] = {"path": path.name, "sha256": sha256(path), "version": version}
    for name in ("one", "two"):
        workspace = output / name
        workspace.mkdir()
        (workspace / "acceptance.lithesettingsaccept").write_text("controlled settings input\n", encoding="utf-8")
    revision = source_revision()
    plan = {"schemaVersion": 1, "kind": "controlled-settings-only", "pluginId": PLUGIN_ID,
            "sourceCommit": revision, "generatorSha256": sha256(Path(__file__)),
            "inputLockSha256": sha256(LOCK), "sdk": {"used": False, "reference": json.loads(LOCK.read_text(encoding="utf-8"))},
            "requires": declaration("1.0.0")["requires"], "archives": archives,
            "workspaces": ["one", "two"]}
    (output / "settings-functions-plan.json").write_bytes(json_bytes(plan))
    return plan


def load_plan(root: Path) -> dict:
    # Read every generated input through the existing ordinary-file guard.
    check_output_path(root)
    ordinary_tree(root)
    plan = json.loads((root / "settings-functions-plan.json").read_text(encoding="utf-8"))
    if (plan.get("schemaVersion") != 1 or plan.get("kind") != "controlled-settings-only"
            or plan.get("pluginId") != PLUGIN_ID or plan.get("requires") != declaration("1.0.0")["requires"]
            or plan.get("sourceCommit") != source_revision()
            or plan.get("generatorSha256") != sha256(Path(__file__)) or plan.get("inputLockSha256") != sha256(LOCK)
            or plan.get("sdk") != {"used": False, "reference": json.loads(LOCK.read_text(encoding="utf-8"))}
            or plan.get("workspaces") != ["one", "two"] or set(plan.get("archives", {})) != {"1.0.0", "1.1.0"}):
        raise ValueError("fixture identity changed; regenerate in this worktree")
    for version, asset in plan["archives"].items():
        path = confined(root, asset["path"])
        if asset.get("version") != version or sha256(path) != asset["sha256"]:
            raise ValueError("fixture archive digest/version changed")
        with zipfile.ZipFile(path) as archive:
            if sorted(archive.namelist()) != ["fixture-version.txt", "plugin.json"]:
                raise ValueError("unexpected settings fixture package content")
            if json.loads(archive.read("plugin.json")) != declaration(version):
                raise ValueError("complete settings manifest changed")
    for name in plan["workspaces"]:
        confined(root, name).resolve(strict=True)
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    plan = generate(args.output)
    print(json.dumps(plan, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
