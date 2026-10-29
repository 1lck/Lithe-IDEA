#!/usr/bin/env python3
"""Complete disposable unsigned API3 ui:1 package; never a signed-package proxy."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

from build_fixture import ROOT, confined, json_bytes, ordinary_tree, write_archive
from settings_functions_fixture import sha256, source_revision
from web_bridge_fallback_fixture import source_inventory as host_source_inventory

PLUGIN_ID = "io.github.lithe-acceptance.literal-text"
WINDOW_ID = PLUGIN_ID + ".window"
DISPLAY_NAME = "Lithe Literal Text Acceptance"


def source_inventory() -> dict:
    deadline = time.monotonic() + 300
    inventory = host_source_inventory(deadline=deadline)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("full text-window source inventory exceeded 300 seconds")
    result = subprocess.run(["git", "ls-files", "-z", "--", "third_party"], cwd=ROOT,
                            capture_output=True, check=True, timeout=min(15, remaining))
    def bounded_hash(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError("full text-window source inventory exceeded 300 seconds")
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    return digest.hexdigest()
                digest.update(chunk)
    for name in result.stdout.decode().split("\0"):
        if name and (ROOT / name).is_file():
            inventory[name] = bounded_hash(ROOT / name)
    for name in ("text_window_fixture.py", "text_window_acceptance.py", "text_window_acceptance_test.py"):
        # ROOT is canonical; resolve a SUBST/alias import before deriving its key.
        path = Path(__file__).resolve().with_name(name)
        inventory[path.relative_to(ROOT).as_posix()] = bounded_hash(path)
    return dict(sorted(inventory.items()))


def literal_text(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
            or parsed.path != "/literal-probe" or parsed.query or parsed.fragment or parsed.username):
        raise ValueError("probe must be one owned loopback HTTP endpoint")
    return ("中文与换行\n单双引号：' \" & 实体：&lt;script&gt; &amp; &#39;\n"
            "<script>window.__literalExecuted=true;alert('literal');"
            f"fetch('{endpoint}');window.lithe.request('ui.setState',{{state:{{injected:true}}}});</script>\n"
            f"</pre><img src=\"{endpoint}\"><iframe src=\"{endpoint}\"></iframe>\n"
            f"<a href='{endpoint}' download>download</a><script src='{endpoint}'></script>\n"
            f"fetch(\"{endpoint}\"); window.open('{endpoint}'); https://example.invalid/literal\n"
            "<pre>最后一行\n")


def declaration(endpoint: str) -> dict:
    return {"schemaVersion": 2, "id": PLUGIN_ID, "displayName": DISPLAY_NAME,
            "version": "1.0.0", "pluginAPIVersion": 3, "requires": {"ui": 1},
            "vendor": {"id": "io.github.lithe-acceptance", "displayName": "Unsigned controlled fixture",
                       "signatureRequirement": "none"},
            "permissions": ["ui.contribute"], "activationEvents": ["onView:" + WINDOW_ID],
            "languages": [], "ui": {"toolWindows": [{"id": WINDOW_ID, "title": DISPLAY_NAME,
                "placement": "right", "order": 300, "text": literal_text(endpoint)}]}}


def check_output(root: Path) -> None:
    parent = ROOT / ".artifacts/plugin-host-acceptance"
    if parent.resolve() not in root.resolve().parents or not root.resolve().relative_to(parent.resolve()).parts[0].startswith("text-window-fixture"):
        raise ValueError("use a run-owned text-window-fixture below .artifacts/plugin-host-acceptance")
    for path in (root, *root.parents):
        if path.is_symlink() or path.is_junction():
            raise ValueError("fixture path cannot traverse a link")


def generate(root: Path, endpoint: str) -> dict:
    check_output(root)
    manifest = declaration(endpoint)
    revision = source_revision()
    inventory = source_inventory()
    root.mkdir(parents=True, exist_ok=False)
    archive = root / "literal-text.zip"
    write_archive(archive, {"plugin.json": json_bytes(manifest)})
    (root / "workspace").mkdir()
    plan = {"schemaVersion": 1, "kind": "controlled-unsigned-ui1-literal-text", "pluginId": PLUGIN_ID,
            "sourceCommit": revision, "sourceInventory": inventory,
            "generatorSha256": sha256(Path(__file__)), "endpoint": endpoint,
            "archive": {"path": archive.name, "sha256": sha256(archive)}, "requires": {"ui": 1}}
    (root / "plan.json").write_bytes(json_bytes(plan))
    return plan


def load_plan(root: Path) -> dict:
    check_output(root)
    ordinary_tree(root)
    plan = json.loads((root / "plan.json").read_text(encoding="utf-8"))
    expected = {"schemaVersion": 1, "kind": "controlled-unsigned-ui1-literal-text", "pluginId": PLUGIN_ID,
                "sourceCommit": source_revision(), "sourceInventory": source_inventory(),
                "generatorSha256": sha256(Path(__file__)), "endpoint": plan["endpoint"],
                "archive": {"path": "literal-text.zip", "sha256": sha256(root / "literal-text.zip")}, "requires": {"ui": 1}}
    if plan != expected:
        raise ValueError("fixture source/manifest/archive identity changed")
    with zipfile.ZipFile(confined(root, plan["archive"]["path"])) as archive:
        if archive.namelist() != ["plugin.json"] or archive.read("plugin.json") != json_bytes(declaration(plan["endpoint"])):
            raise ValueError("complete controlled fixture content changed")
    return plan


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--endpoint", required=True)
    args = parser.parse_args()
    print(json.dumps(generate(args.output, args.endpoint), indent=2))
