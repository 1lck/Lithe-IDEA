#!/usr/bin/env python3
"""Generate deterministic community disk packages for native host acceptance."""

from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from pathlib import Path


PLUGIN_ID = "io.github.lithe-acceptance.host"
DISPLAY_NAME = "Lithe Host Acceptance"


def manifest(version: str, fixture_version: str) -> dict:
    return {
        "schemaVersion": 2,
        "id": PLUGIN_ID,
        "displayName": DISPLAY_NAME,
        "version": version,
        "pluginAPIVersion": 2,
        "vendor": {
            "id": "io.github.lithe-acceptance",
            "displayName": "Lithe acceptance fixture",
            "signatureRequirement": "none",
        },
        "permissions": ["languageServer.launch"],
        "activationEvents": ["onLanguage:litheaccept"],
        "languages": [
            {
                "id": "litheaccept",
                "displayName": "Lithe Acceptance",
                "fileExtensions": ["litheaccept"],
                "projectFileNames": ["acceptance.litheaccept"],
            }
        ],
        "languageServers": [
            {
                "languageID": "litheaccept",
                "languageIdentifier": "litheaccept",
                "launch": {
                    "kind": "runtime",
                    "tool": "node",
                    "entry": "server/fake-lsp-server.mjs",
                },
                "arguments": [
                    "--stdio",
                    "--state-dir",
                    "${workspaceStateDir}",
                    "--fixture-version",
                    fixture_version,
                ],
            }
        ],
    }


def write_package(
    output_root: Path,
    server_source: Path,
    package_name: str,
    version: str,
    fixture_version: str,
) -> Path:
    package_root = output_root / package_name
    if package_root.exists():
        shutil.rmtree(package_root)
    (package_root / "server").mkdir(parents=True)
    (package_root / "plugin.json").write_text(
        json.dumps(manifest(version, fixture_version), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (package_root / "fixture-version.txt").write_text(f"{fixture_version}\n", encoding="utf-8")
    shutil.copy2(server_source, package_root / "server" / server_source.name)

    archive = output_root / f"{package_name}.zip"
    if archive.exists():
        archive.unlink()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package_zip:
        for source in sorted(path for path in package_root.rglob("*") if path.is_file()):
            relative = source.relative_to(package_root).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package_zip.writestr(info, source.read_bytes())
    return archive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--server", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    server = args.server.resolve()
    if not server.is_file():
        raise SystemExit(f"Fake language server is missing: {server}")
    output.mkdir(parents=True, exist_ok=True)
    packages = {
        "v1_a": write_package(output, server, "host-acceptance-1.0.0-a", "1.0.0", "1.0.0-a"),
        "v1_b": write_package(output, server, "host-acceptance-1.0.0-b", "1.0.0", "1.0.0-b"),
        "v2": write_package(output, server, "host-acceptance-1.1.0", "1.1.0", "1.1.0"),
    }
    print(json.dumps({key: str(value) for key, value in packages.items()}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
