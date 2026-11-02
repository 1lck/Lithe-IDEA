#!/usr/bin/env python3
"""Complete unsigned community inputs for the generic native product workflow.

The frozen Mac UI Lab supplies declarations, never executable Swift or an SDK.
Core remains the only model/manifest/result interpreter. These new packages are
controlled inputs, not an external publisher's official acceptance archive.
"""
from __future__ import annotations

import argparse
import copy
import json
import zipfile
from pathlib import Path

from build_fixture import ROOT, confined, json_bytes, ordinary_tree, write_archive
from settings_functions_fixture import sha256, source_revision

PLUGIN_ID = "io.github.lithe-acceptance.native-workflow"
DISPLAY_NAME = "Lithe Native Workflow Acceptance"
REFERENCE = ROOT / "macos/Tests/Fixtures/native-ui-lab/plugin.json"
BACKEND = Path(__file__).with_name("native-workflow-backend.mjs")
TOOL = Path(__file__).with_name("fake-build-tool.mjs")
REQUIRES = {"buildProviders": 1, "buildSystems": 1, "serverProcess": 1, "settings": 2, "ui": 3, "languages": 1, "languageServers": 2}


def declaration(version: str) -> dict:
    reference = json.loads(REFERENCE.read_text(encoding="utf-8"))
    manifest = copy.deepcopy(reference)
    manifest.update(id=PLUGIN_ID, displayName=DISPLAY_NAME, version=version, requires=REQUIRES)
    manifest["vendor"] = {"id": "io.github.lithe-acceptance", "displayName": "Unsigned controlled fixture",
                          "signatureRequirement": "none"}
    system = manifest["buildSystems"][0]
    system.update(id="workflow", displayName="Workflow Provider",
                  detection={"markers": ["workflow.fixture"], "nesting": "outermost"})
    system["invocation"] = {"executables": [{"kind": "runtime", "runtime": "node"}],
                            "runtimeDependencies": [{"id": "node", "minimumVersion": "20.3.0"}],
                            "globalArguments": [".lithe-acceptance/fake-build-tool.mjs"]}
    system["provider"]["launch"]["entry"] = "backend/native-workflow-backend.mjs"
    system["provider"]["arguments"] = ["--state-dir", "${workspaceStateDir}", "--fixture-version", version,
        "--global-message", "${setting:globalMessage}", "--restart-message", "${setting:restartMessage}"]
    system["tasks"] = [{"id": "build", "displayName": "Build", "group": "build",
                        "scopes": ["workspace", "project", "target"],
                        "arguments": ["build", "${userArguments}"]}]
    system["test"] = {"scopes": ["project", "target"], "filters": ["suite", "case"],
        "arguments": ["test", {"value": "${test.suite}", "when": "suiteSelected"},
                      {"value": "${test.case}", "when": "caseSelected"}],
        "results": {"decoder": "junitXml", "reports": ["build/test-results/**/*.xml"]}}
    system["diagnostics"] = {"decoder": "lineMatcher", "patterns": [{
        "regex": r"^(.+\.rs):(\d+):(\d+): (error|warning): (.+)$",
        "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5}]}
    system["sync"] = {"watch": ["workflow.fixture"]}
    manifest["settings"] = [
        {"id": "globalMessage", "title": "Workflow global message", "type": "text", "pattern": ".*", "default": "global-default",
         "scope": "global", "effect": "nextRun", "page": {"buildSystemID": "workflow"}},
        {"id": "projectMessage", "title": "Workflow project message", "type": "text", "pattern": ".*", "default": "project-default",
         "scope": "project", "effect": "nextRun", "page": {"buildSystemID": "workflow"}},
        {"id": "reloadMessage", "title": "Workflow reload message", "type": "text", "pattern": ".*", "default": "reload-default",
         "scope": "project", "effect": "reload", "page": {"buildSystemID": "workflow"}},
        {"id": "restartMessage", "title": "Workflow restart message", "type": "text", "pattern": ".*", "default": "restart-default",
         "scope": "global", "effect": "restart", "page": {"buildSystemID": "workflow"}},
    ]
    manifest["settingActions"] = [{"id": action, "title": title, "function": function,
                                  "confirm": True, "page": {"buildSystemID": "workflow"}}
        for action, title, function in (("inspect", "Inspect workflow", "buttons.inspect"),
                                       ("withdraw", "Withdraw workflow rename", "buttons.withdraw"),
                                       ("restore", "Restore workflow rename", "buttons.restore"))]
    provider = system["provider"]
    manifest["languages"] = [{"id": "workflow-language", "displayName": "Workflow language",
                              "fileExtensions": ["workflow"]}]
    manifest["languageServers"] = [{"languageID": "workflow-language", "launch": provider["launch"],
                                    "arguments": provider["arguments"]}]
    if version == "1.1.0":
        manifest["languageServers"][0]["workspaceConfiguration"] = {"workflow": {"message": "${setting:immediateMessage}"}}
        system["provider"] = {"languageServer": "workflow-language", "executesProjectCode": True, "mayUseNetwork": False}
        manifest["settings"].append({"id": "immediateMessage", "title": "Workflow immediate message",
            "type": "text", "pattern": ".*", "default": "immediate-default", "scope": "project",
            "effect": "immediate", "page": {"buildSystemID": "workflow"}})
    windows = manifest["ui"]["toolWindows"]
    commands = []
    for index, window in enumerate(windows):
        suffix = window["id"].rsplit(".", 1)[1]
        window.update(id=f"{PLUGIN_ID}.{suffix}", title=f"Workflow {suffix}", order=600 + index)
        if "source" in window["native"]:
            window["native"]["source"]["buildSystemID"] = "workflow"
        commands.append({"id": f"{PLUGIN_ID}.open.{suffix}", "title": f"Open workflow {suffix}",
                         "toolWindowID": window["id"], "placements": ["commandPalette", "toolbar"]})
    manifest["ui"]["commands"] = commands
    manifest["activationEvents"] = ["onBuildSystem:workflow", "onLanguage:workflow-language", *["onView:" + w["id"] for w in windows],
                                    *["onCommand:" + command["id"] for command in commands]]
    return manifest


def generate(root: Path) -> dict:
    parent = ROOT / ".artifacts/plugin-host-acceptance"
    if parent.resolve() not in root.resolve().parents or not root.name.startswith("native-workflow-fixture"):
        raise ValueError("use an isolated native-workflow-fixture below .artifacts/plugin-host-acceptance")
    for path in (root, *root.parents):
        if path.is_symlink() or path.is_junction():
            raise ValueError("fixture cannot traverse a link")
    root.mkdir(parents=True, exist_ok=False)
    assets = {}
    for version in ("1.0.0", "1.1.0"):
        archive = root / f"workflow-{version}.zip"
        write_archive(archive, {"plugin.json": json_bytes(declaration(version)),
            "backend/native-workflow-backend.mjs": BACKEND.read_bytes()})
        assets[version] = {"path": archive.name, "sha256": sha256(archive)}
    for name in ("one", "two"):
        workspace = root / name
        (workspace / ".lithe-acceptance").mkdir(parents=True)
        (workspace / "nested").mkdir()
        (workspace / "src").mkdir()
        (workspace / "src/main.rs").write_text("fn main() {}\n", encoding="utf-8")
        (workspace / "workflow.fixture").write_text("controlled Provider input\n", encoding="utf-8")
        (workspace / "acceptance.build.txt").write_text("saved-before-build\n", encoding="utf-8")
        (workspace / ".lithe-acceptance/fake-build-tool.mjs").write_bytes(TOOL.read_bytes())
    plan = {"schemaVersion": 1, "kind": "controlled-native-workflow", "pluginId": PLUGIN_ID,
            "requires": REQUIRES, "sourceCommit": source_revision(), "archives": assets,
            "inputs": {p.relative_to(ROOT).as_posix(): sha256(p) for p in (REFERENCE, BACKEND, TOOL, Path(__file__))},
            "externalOfficialPackage": False, "sdkExecuted": False}
    (root / "native-workflow-plan.json").write_bytes(json_bytes(plan))
    return plan


def load_plan(root: Path) -> dict:
    ordinary_tree(root)
    plan = json.loads((root / "native-workflow-plan.json").read_text(encoding="utf-8"))
    if (plan.get("sourceCommit") != source_revision() or plan.get("requires") != REQUIRES
            or plan.get("kind") != "controlled-native-workflow" or plan.get("pluginId") != PLUGIN_ID
            or plan.get("externalOfficialPackage") is not False or plan.get("sdkExecuted") is not False):
        raise ValueError("fixture source/requirements changed")
    expected_inputs = {p.relative_to(ROOT).as_posix(): sha256(p) for p in (REFERENCE, BACKEND, TOOL, Path(__file__))}
    if plan.get("inputs") != expected_inputs or set(plan.get("archives", {})) != {"1.0.0", "1.1.0"}:
        raise ValueError("fixture input identity changed")
    for version, asset in plan["archives"].items():
        archive = confined(root, asset["path"])
        if sha256(archive) != asset["sha256"]:
            raise ValueError("fixture ZIP changed")
        with zipfile.ZipFile(archive) as package:
            if sorted(package.namelist()) != ["backend/native-workflow-backend.mjs", "plugin.json"] or json.loads(package.read("plugin.json")) != declaration(version) or package.read("backend/native-workflow-backend.mjs") != BACKEND.read_bytes():
                raise ValueError("complete fixture declaration/backend changed")
    return plan


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.output), indent=2))
