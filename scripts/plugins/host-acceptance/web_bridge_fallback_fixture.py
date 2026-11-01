#!/usr/bin/env python3
"""Complete unsigned ui:2 inputs, generated per run and never reused as a cache."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
import zipfile
from pathlib import Path

from build_fixture import ROOT, confined, json_bytes, ordinary_tree, write_archive
from settings_functions_fixture import sha256, source_revision

PLUGIN_ID = "io.github.lithe-acceptance.web-fallback"
WINDOW_ID = PLUGIN_ID + ".window"
DISPLAY_NAME = "Lithe Web Fallback Acceptance"
FILES = {"ui/index.html": b'<!doctype html><html><head><meta charset="utf-8"><title>Controlled web fallback</title></head><body><main>Controlled unsigned ui:2 state bridge fixture</main></body></html>\n'}


def declaration() -> dict:
    return {"schemaVersion": 2, "id": PLUGIN_ID, "displayName": DISPLAY_NAME,
            "version": "1.0.0", "pluginAPIVersion": 3, "requires": {"ui": 2},
            "vendor": {"id": "io.github.lithe-acceptance", "displayName": "Unsigned controlled fixture",
                       "signatureRequirement": "none"},
            "permissions": ["ui.contribute", "ui.web"], "activationEvents": ["onView:" + WINDOW_ID],
            "languages": [], "ui": {"toolWindows": [{"id": WINDOW_ID, "title": DISPLAY_NAME,
                "placement": "right", "order": 300, "web": {"entry": "ui/index.html"}}]}}


def check_output(root: Path) -> None:
    parent = ROOT / ".artifacts/plugin-host-acceptance"
    if parent.resolve() not in root.resolve().parents or not root.resolve().relative_to(parent.resolve()).parts[0].startswith("web-bridge-fallback-fixture"):
        raise ValueError("use a run-owned web-bridge-fallback-fixture below .artifacts/plugin-host-acceptance")
    for path in (root, *root.parents):
        if path.is_symlink() or path.is_junction():
            raise ValueError("fixture path cannot traverse a link")


def generate(root: Path) -> dict:
    check_output(root)
    root.mkdir(parents=True, exist_ok=False)
    archive = root / "web-fallback.zip"
    write_archive(archive, {"plugin.json": json_bytes(declaration()), **FILES})
    (root / "workspace").mkdir()
    plan = {"schemaVersion": 1, "kind": "controlled-unsigned-ui2-web-fallback", "pluginId": PLUGIN_ID,
            "sourceCommit": source_revision(), "generatorSha256": sha256(Path(__file__)),
            "archive": {"path": archive.name, "sha256": sha256(archive)}, "requires": {"ui": 2}}
    (root / "plan.json").write_bytes(json_bytes(plan))
    return plan


def load_plan(root: Path) -> dict:
    check_output(root)
    ordinary_tree(root)
    plan = json.loads((root / "plan.json").read_text(encoding="utf-8"))
    expected = {"schemaVersion": 1, "kind": "controlled-unsigned-ui2-web-fallback", "pluginId": PLUGIN_ID,
                "sourceCommit": source_revision(), "generatorSha256": sha256(Path(__file__)),
                "archive": {"path": "web-fallback.zip", "sha256": sha256(root / "web-fallback.zip")}, "requires": {"ui": 2}}
    if plan != expected:
        raise ValueError("fixture source/manifest/archive identity changed")
    with zipfile.ZipFile(confined(root, plan["archive"]["path"])) as archive:
        files = {"plugin.json": json_bytes(declaration()), **FILES}
        if sorted(archive.namelist()) != sorted(files) or any(archive.read(name) != data for name, data in files.items()):
            raise ValueError("complete controlled fixture content changed")
    return plan


def source_inventory(*, deadline: float | None = None) -> dict:
    # Cover the entire Windows build graph and its contracts/tooling, including
    # root lock/config and third-party inputs. Untracked, non-ignored sources
    # can also be compiled; generated dependencies/outputs follow Git ignores.
    # macOS-only sources are not compiled in this host.
    deadline = deadline if deadline is not None else time.monotonic() + 300
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("full Windows source inventory exceeded 300 seconds")
    result = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--",
                             "windows", "frontend", "rust", "Plugins/win", "shared", "scripts", "third_party",
                             "Cargo.lock", "Cargo.toml", "bun.lock", "bunfig.toml", "package.json"],
                            cwd=ROOT, capture_output=True, check=True, timeout=min(15, remaining))
    inventory = {}
    for name in sorted(result.stdout.decode().split("\0")):
        if name and (ROOT / name).is_file():
            digest = hashlib.sha256()
            with (ROOT / name).open("rb") as stream:
                while True:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("full Windows source inventory exceeded 300 seconds")
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
            inventory[name] = digest.hexdigest()
    return inventory


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    print(json.dumps(generate(parser.parse_args().output), indent=2))
