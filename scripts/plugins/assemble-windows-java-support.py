#!/usr/bin/env python3
"""Assemble an unsigned Windows Java candidate from pinned, offline cache inputs.

No downloads, tool execution, signature substitution or installed resource writes.
The receipt records provenance; it never authenticates a package or admits it.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import tarfile
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("Plugins/win/Official/JavaSupport")
REQUIRES = {"languages": 1, "languageServers": 1, "serverProcess": 1,
            "settings": 2, "projectGenerators": 1, "packageTrust": 1}
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENTRIES = 100_000


def check_deadline(deadline):
    if time.monotonic() >= deadline:
        raise TimeoutError("Windows Java assembly exceeded its deadline")


def plain_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError(f"Expected a regular file, not a link/reparse point: {path}")


def digest(path, deadline):
    plain_file(path)
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            check_deadline(deadline)
            value.update(chunk)
    return value.hexdigest()


def safe_name(name):
    # Archive paths must have one unambiguous Windows interpretation even when
    # assembly tests run on another platform. No links are ever extracted.
    if "\\" in name or ":" in name or "\x00" in name or name.startswith("/"):
        raise ValueError(f"Unsafe archive path: {name}")
    parts = name.rstrip("/").split("/")
    if parts and parts[0] == ".":
        parts = parts[1:]
    if not parts:
        return None
    for part in parts:
        if not part or part in {".", ".."} or part.rstrip(". ") != part or any(ord(c) < 32 for c in part):
            raise ValueError(f"Unsafe archive path: {name}")
        if re.fullmatch(r"(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])", part.split(".")[0]):
            raise ValueError(f"Reserved Windows archive path: {name}")
    return PurePosixPath(*parts)


def extract(archive, destination, deadline):
    seen = set()
    total = 0

    def write_entry(name, directory, size, stream):
        nonlocal total
        check_deadline(deadline)
        relative = safe_name(name)
        if relative is None:
            return
        key = str(relative).casefold()
        if key in seen:
            raise ValueError(f"Duplicate Windows archive path: {name}")
        seen.add(key)
        if len(seen) > MAX_ENTRIES or size < 0 or total + size > MAX_EXPANDED_BYTES:
            raise ValueError("Archive expansion exceeds the assembly limit")
        total += size
        target = destination.joinpath(*relative.parts)
        if directory:
            target.mkdir(parents=True, exist_ok=True)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        copied = 0
        with target.open("xb") as output:
            while chunk := stream.read(1024 * 1024):
                check_deadline(deadline)
                copied += len(chunk)
                if copied > size:
                    raise ValueError("Archive entry exceeded its declared size")
                output.write(chunk)
        if copied != size:
            raise ValueError("Archive entry was truncated")

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for entry in source.infolist():
                mode = entry.external_attr >> 16
                if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in {0, stat.S_IFREG, stat.S_IFDIR}):
                    raise ValueError(f"Archive link or special entry: {entry.filename}")
                with source.open(entry) as stream:
                    write_entry(entry.filename, entry.is_dir(), entry.file_size, stream)
    else:
        with tarfile.open(archive, "r:gz") as source:
            for entry in source:
                if not entry.isdir() and not entry.isfile():
                    raise ValueError(f"Archive link or special entry: {entry.name}")
                stream = source.extractfile(entry) if entry.isfile() else None
                try:
                    write_entry(entry.name, entry.isdir(), entry.size, stream)
                finally:
                    if stream is not None:
                        stream.close()


def copy_tree(source, destination, deadline):
    check_deadline(deadline)
    info = source.lstat()
    if source.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError(f"Source link/reparse point: {source}")
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=False)
        for child in sorted(source.iterdir()):
            copy_tree(child, destination / child.name, deadline)
    else:
        plain_file(source)
        check_deadline(deadline)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def pe_machine(path):
    plain_file(path)
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:2] != b"MZ":
            raise ValueError(f"Runtime is not a Windows PE image: {path}")
        stream.seek(struct.unpack_from("<I", header, 60)[0])
        header = stream.read(6)
    if len(header) != 6 or header[:4] != b"PE\0\0":
        raise ValueError(f"Runtime has no PE signature: {path}")
    return struct.unpack_from("<H", header, 4)[0]


def read_json(path):
    plain_file(path)
    return json.loads(path.read_text(encoding="utf-8-sig"))


def file_inventory(root, deadline):
    """Hash regular files without following Windows aliases or reparse points."""
    files, names = {}, set()
    total = 0

    def visit(directory):
        nonlocal total
        check_deadline(deadline)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError(f"Expected a plain directory: {directory}")
        for child in sorted(directory.iterdir()):
            check_deadline(deadline)
            name = child.relative_to(root).as_posix()
            if str(safe_name(name)) != name or name.casefold() in names:
                raise ValueError(f"Ambiguous Windows package path: {name}")
            names.add(name.casefold())
            if len(names) > MAX_ENTRIES:
                raise ValueError("Package inventory exceeds the entry limit")
            info = child.lstat()
            if stat.S_ISDIR(info.st_mode):
                visit(child)
            else:
                plain_file(child)
                total += info.st_size
                if total > MAX_EXPANDED_BYTES:
                    raise ValueError("Package inventory exceeds the byte limit")
                files[name] = digest(child, deadline)

    visit(root)
    return files


def assemble(root, architecture, output, deadline):
    root, output = root.resolve(), output.absolute()
    allowed = root / ".artifacts/windows-java-support"
    if not output.resolve().is_relative_to(allowed.resolve()) or output.resolve() == allowed.resolve():
        raise ValueError("Output must be a new child of .artifacts/windows-java-support")
    if output.exists():
        raise ValueError("Output already exists; assembly never overwrites a package")
    source = root / SOURCE
    source_files = file_inventory(source, deadline)
    source_manifests = {name: digest(root / name, deadline) for name in
                        ("third_party/jdtls/manifest.json", "third_party/jdk/manifest.json")}
    manifest = read_json(source / "plugin.json")
    policy = read_json(source / "language-server.json")
    if manifest.get("requires") != REQUIRES or manifest.get("pluginAPIVersion") != 3:
        raise ValueError("Windows Java manifest must retain its complete API/requirements")
    if manifest.get("id") != "dev.lithe.plugin.java-support" or policy.get("sourceManifests") != ["third_party/jdtls/manifest.json", "third_party/jdk/manifest.json"]:
        raise ValueError("Windows Java identity and fixed source manifests must be retained")
    if manifest.get("vendor", {}).get("signatureRequirement") != "publisherPackage" or manifest["vendor"].get("bundledSignatureRequirement") != "sameTeamAsHost":
        raise ValueError("Windows Java origin policy was changed")
    if policy["platform"] != "windows" or architecture not in policy["architectures"]:
        raise ValueError("Unsupported Windows Java architecture")
    target = policy["architectures"][architecture]
    jdt = read_json(root / "third_party/jdtls/manifest.json")
    jdk = read_json(root / "third_party/jdk/manifest.json")
    platform = jdk["platforms"][target["jdkPlatform"]]
    inputs, cached_paths = [], []

    def cached(cache, name, expected, url):
        path = root / ".artifacts" / cache / name
        if not re.fullmatch("[0-9a-f]{64}", expected) or digest(path, deadline) != expected:
            raise ValueError(f"Pinned input SHA-256 mismatch: {path.name}")
        if not url.startswith("https://"):
            raise ValueError("Pinned inputs require HTTPS provenance")
        inputs.append({"name": name, "sha256": expected, "url": url})
        cached_paths.append((path, expected))
        return path

    def safe_version(value):
        return re.sub(r"[^A-Za-z0-9._-]", "_", value)

    jdt_archive = cached("jdtls-downloads", f"jdtls-{safe_version(jdt['version'])}-{jdt['archiveSHA256']}.tar.gz", jdt["archiveSHA256"], jdt["archiveURL"])
    jdk_archive = cached("jdk-downloads", f"jdk-{safe_version(jdk['version'])}-{target['jdkPlatform']}-{platform['sha256']}.zip", platform["sha256"], platform["url"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".assemble-", dir=output.parent) as scratch:
        scratch = Path(scratch)
        package = scratch / "package"
        package.mkdir()
        language = package / "language-server"
        language.mkdir()
        jdt_tree, jdk_tree = scratch / "jdt", scratch / "jdk"
        extract(jdt_archive, jdt_tree, deadline)
        extract(jdk_archive, jdk_tree, deadline)
        for name in ("plugins", "features"):
            copy_tree(jdt_tree / name, language / name, deadline)
        config = language / "configuration" / architecture
        config.mkdir(parents=True)
        copy_tree(jdt_tree / target["configuration"] / "config.ini", config / "config.ini", deadline)
        copy_tree(jdk_tree / platform["jdkRoot"], package / "runtime" / architecture, deadline)
        runtime = package / "runtime" / architecture
        for required in ("bin/java.exe", "lib/modules", "release", "legal/java.base/LICENSE"):
            plain_file(runtime / required)
        native = sorted(path for path in runtime.rglob("*") if path.suffix.lower() in {".exe", ".dll"})
        for image in native:
            check_deadline(deadline)
            if pe_machine(image) != target["peMachine"]:
                raise ValueError(f"Runtime PE architecture mismatch: {image.name}")
        for name in ("plugin.json", "language-server.json", "templates"):
            copy_tree(source / name, package / name, deadline)
        copy_tree(root / "third_party/jdtls/manifest.json", language / "manifest.json", deadline)
        copy_tree(root / "third_party/jdk/manifest.json", runtime / "manifest.json", deadline)

        def fixed_file(name, version, hash_key, url_key, destination):
            expected = jdt[hash_key]
            path = cached("jdtls-downloads", f"{name}-{safe_version(jdt[version])}-{expected}{'.jar' if hash_key == 'lombokSHA256' else '.txt'}", expected, jdt[url_key])
            copy_tree(path, language / destination, deadline)

        license_file = cached("jdtls-downloads", f"EPL-2.0-{jdt['licenseSHA256']}.txt", jdt["licenseSHA256"], jdt["licenseURL"])
        copy_tree(license_file, language / "LICENSE-EPL-2.0.txt", deadline)
        fixed_file("lombok", "lombokVersion", "lombokSHA256", "lombokURL", "lombok/lombok.jar")
        fixed_file("lombok-MIT", "lombokVersion", "lombokLicenseSHA256", "lombokLicenseURL", "lombok/LICENSE-MIT.txt")
        fixed_file("java-debug-EPL-1.0", "javaDebugServerVersion", "javaDebugLicenseSHA256", "javaDebugLicenseURL", "java-debug/LICENSE-EPL-1.0.txt")
        fixed_file("java-test-MIT", "javaTestExtensionVersion", "javaTestLicenseSHA256", "javaTestLicenseURL", "java-test/LICENSE-MIT.txt")
        for tool, version_key, prefix in (("java-debug", "javaDebugExtensionVersion", "javaDebug"), ("java-test", "javaTestExtensionVersion", "javaTest")):
            expected = jdt[f"{prefix}ArchiveSHA256"]
            base = f"vscode-{tool}-{safe_version(jdt[version_key])}-{expected}"
            extension = ".zip" if (root / ".artifacts/jdtls-downloads" / f"{base}.zip").exists() else ".vsix"
            archive = cached("jdtls-downloads", base + extension, expected, jdt[f"{prefix}ArchiveURL"])
            extracted = scratch / tool
            extract(archive, extracted, deadline)
            if tool == "java-debug":
                name = f"com.microsoft.java.debug.plugin-{jdt['javaDebugServerVersion']}.jar"
                origin = extracted / "extension/server" / name
                if digest(origin, deadline) != jdt["javaDebugPluginSHA256"]:
                    raise ValueError("Java Debug bundle SHA-256 mismatch")
                copy_tree(origin, language / "java-debug" / name, deadline)
            else:
                extension_manifest = read_json(extracted / "extension/package.json")
                names = []
                for declared in extension_manifest["contributes"]["javaExtensions"]:
                    relative = safe_name(declared)
                    if relative is None:
                        raise ValueError("Java Test bundle path is empty")
                    origin = extracted / "extension" / Path(*relative.parts)
                    # Keep the upstream bundle list and avoid replacing a bundle
                    # already owned by this JDT distribution.
                    if (language / "plugins" / origin.name).exists():
                        continue
                    if origin.name.casefold() in {name.casefold() for name in names}:
                        raise ValueError("Java Test declares duplicate bundle names")
                    copy_tree(origin, language / "java-test/extensions" / origin.name, deadline)
                    names.append(origin.name)
                if not names:
                    raise ValueError("Java Test declares no extension bundles")
                (language / "java-test/extensions.txt").write_text("\n".join(names) + "\n", encoding="utf-8")
                for name, expected_hash in ((f"extensions/com.microsoft.java.test.plugin-{jdt['javaTestPluginVersion']}.jar", jdt["javaTestPluginSHA256"]), ("runner/com.microsoft.java.test.runner-jar-with-dependencies.jar", jdt["javaTestRunnerSHA256"])):
                    destination = language / "java-test" / name
                    if name.startswith("runner/"):
                        copy_tree(extracted / "extension/server" / Path(name).name, destination, deadline)
                    if digest(destination, deadline) != expected_hash:
                        raise ValueError("Java Test plugin/runner SHA-256 mismatch")
        server = manifest["languageServers"][0]
        for declared in (server["launch"]["entry"], server["launch"]["packagedRuntime"].replace("${arch}", architecture), server["hostIntegration"]["resources"]["testRunner"]):
            plain_file(package / declared)
        files = file_inventory(package, deadline)
        # The receipt describes one frozen set of inputs, including files read
        # earlier in the build. Recheck before atomic publication, not at launch.
        if file_inventory(source, deadline) != source_files or any(
                digest(root / name, deadline) != expected for name, expected in source_manifests.items()):
            raise ValueError("Source inputs changed during assembly")
        if any(digest(path, deadline) != expected for path, expected in cached_paths):
            raise ValueError("Cached inputs changed during assembly")
        for name, expected in source_files.items():
            if name in {"plugin.json", "language-server.json"} or name.startswith("templates/"):
                if files.get(name) != expected:
                    raise ValueError("Source copy changed during assembly")
        if (files["language-server/manifest.json"] != source_manifests["third_party/jdtls/manifest.json"]
                or files[f"runtime/{architecture}/manifest.json"] != source_manifests["third_party/jdk/manifest.json"]):
            raise ValueError("Source manifests changed during assembly")
        receipt = {"schemaVersion": 1, "status": "unsigned-candidate", "platform": "windows", "architecture": architecture,
                   "pluginId": manifest["id"], "version": manifest["version"], "requires": manifest["requires"],
                   "sourceManifests": source_manifests,
                   "inputs": inputs, "runtimeImages": [path.relative_to(package).as_posix() for path in native], "files": files}
        (package / "windows-java-inputs.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        check_deadline(deadline)
        os.replace(package, output)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", choices=("x86_64", "arm64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, choices=range(1, 1201), default=300, metavar="1..1200")
    args = parser.parse_args()
    receipt = assemble(ROOT, args.architecture, args.output, time.monotonic() + args.timeout_seconds)
    print(json.dumps({"output": str(args.output.absolute()), "status": receipt["status"], "files": len(receipt["files"])}))


if __name__ == "__main__":
    main()
