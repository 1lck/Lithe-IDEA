#!/usr/bin/env python3
"""Freeze real build packages, optionally sign a complete controlled Java suite.

No download, JDT assembly, native build, install or product launch occurs here.
Unsigned archives cannot pass native trust. --controlled-java-archive signs a
copy with an ephemeral diagnostic key; A must pin its PUBLIC key in a disposable
source build and restore those bytes after execution. It never changes this tree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from build_fixture import ROOT, json_bytes, ordinary_tree
from java_workflow_inputs import REQUIRES, PLUGIN_ID, archive_entries, sha256, variant_plan
from text_window_fixture import source_inventory


def reference(path):
    return {"path": str(path.resolve(strict=True)), "sha256": sha256(path)}


def inventory(archive):
    with zipfile.ZipFile(archive) as source:
        entries, files = archive_entries(source), {}
        for name, row in entries.items():
            if row.is_dir():
                continue
            if name == 'lithe-plugin-signature.json':
                raise ValueError("never replace an existing package signature")
            with source.open(row) as stream:
                files[name] = hashlib.file_digest(stream, 'sha256').hexdigest()
        if entries['plugin.json'].file_size > 4 * 1024**2:
            raise ValueError("manifest exceeds JSON budget")
        manifest = json.loads(source.read(entries['plugin.json']))
    return manifest, files


def build_packages(output):
    packages = {}
    for variant, name in (("maven", "MavenSupport"), ("gradle", "GradleSupport")):
        directory = ROOT / 'Plugins/win/Official' / name
        before = ordinary_tree(directory)
        archive = output / (variant + '.zip')
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as target:
            for path in sorted(before):
                target.write(directory / path, path)
        if ordinary_tree(directory) != before:
            raise ValueError("build package source changed during freezing")
        packages[variant] = archive
    return packages


def package_input(archive, published=None):
    with zipfile.ZipFile(archive) as source:
        raw = source.read(archive_entries(source)['plugin.json'])
    manifest = json.loads(raw)
    result = {"archive": reference(archive), "manifestSha256": hashlib.sha256(raw).hexdigest(),
              "requires": manifest['requires'], "pluginId": manifest['id']}
    if manifest.get('buildSystems'):
        result['buildSystemId'] = manifest['buildSystems'][0]['id']
    if published is not None:
        result['archive']['path'] = str(published)
    return result


def controlled_packages(output, java_archive, node):
    from vcs_move_diagnostic import WindowsJob, cleanup_proven, supervised
    packages = build_packages(output)
    packages = {'plain': java_archive.resolve(strict=True), **packages}
    before = {key: reference(path) for key, path in packages.items()}
    inputs = []
    for variant, path in packages.items():
        manifest, files = inventory(path)
        if variant == 'plain' and (manifest['id'] != PLUGIN_ID or manifest['requires'] != REQUIRES):
            raise ValueError("controlled suite retains the complete Java candidate requires")
        inputs.append({'pluginId': manifest['id'], 'pluginVersion': manifest['version'], 'files': files})
    (output / 'signer-input.json').write_bytes(json_bytes(inputs))
    result = supervised([str(node), str(Path(__file__).with_name('java_workflow_controlled_signer.mjs')),
                         str(output / 'signer-input.json'), str(output / 'controlled-signatures.json')],
                        15, output / 'signer.log', WindowsJob)
    (output / 'signer-owner.json').write_bytes(json_bytes(result))
    if result['status'] != 'passed' or not cleanup_proven(result):
        raise ValueError("controlled signer failed or cleanup is unproven")
    signed = json.loads((output / 'controlled-signatures.json').read_text(encoding='utf-8'))
    final = {}
    for (variant, path), signature in zip(packages.items(), signed['signatures'], strict=True):
        destination = output / (variant + '-controlled.zip')
        with zipfile.ZipFile(path) as source, zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_STORED) as target:
            for name, entry in archive_entries(source).items():
                if entry.is_dir():
                    target.writestr(name, b'')
                    continue
                # Bounded streaming avoids expanding the full real JDT/JDK into RAM.
                with source.open(entry) as src, target.open(name, 'w') as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
            target.writestr('lithe-plugin-signature.json', json_bytes(signature))
        if reference(path) != before[variant]:
            raise ValueError("source archive changed during controlled signing")
        final[variant] = destination
    return final, {key: signed[key] for key in ('keyId', 'publicKeyBase64')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--controlled-java-archive', type=Path)
    parser.add_argument('--node', type=Path)
    parser.add_argument('--jdk-home', type=Path)
    parser.add_argument('--jdk-version')
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists():
        parser.error('output must be absent; preserve earlier evidence')
    if args.controlled_java_archive and not all((args.node, args.jdk_home, args.jdk_version)):
        parser.error('controlled suite needs explicit Node and fixed real JDK home/version')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Publish only complete input sets; no partially signed package is adopted.
    with tempfile.TemporaryDirectory(prefix='.java-workflow-', dir=output.parent) as scratch:
        staging = Path(scratch)
        if args.controlled_java_archive:
            packages, key = controlled_packages(staging, args.controlled_java_archive, args.node)
        else:
            packages, key = build_packages(staging), None
        document = {'productionTrusted': False, 'packages': {variant: package_input(path, output / path.name) for variant, path in packages.items()}}
        if key:
            revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, timeout=5, check=True, capture_output=True, text=True).stdout.strip()
            home = args.jdk_home.resolve(strict=True)
            base = {'schemaVersion': 2, 'kind': 'windows-java-workflow', 'variant': 'plain',
                'assurance': 'controlled', 'controlledHost': key, 'sourceCommit': revision,
                'sourceInventory': source_inventory(), 'package': document['packages']['plain'],
                'jdk': {'home': str(home), 'version': args.jdk_version,
                        'javaSha256': sha256(home / 'bin/java.exe'), 'javacSha256': sha256(home / 'bin/javac.exe')},
                'project': {'name': 'Java Workflow Plain', 'sourcePath': 'src/Main.java', 'mainClass': 'Main', 'configurationName': 'Main'}}
            for variant in ('plain', 'maven', 'gradle'):
                plan = base if variant == 'plain' else variant_plan(base, variant)
                if variant != 'plain':
                    plan.update(buildPackage=document['packages'][variant], buildTask={'taskId': 'compile' if variant == 'maven' else 'build', 'scope': 'workspace'})
                (staging / (variant + '-plan.json')).write_bytes(json_bytes(plan))
            document['controlledHost'] = key
        (staging / 'package-inputs.json').write_bytes(json_bytes(document))
        staging.rename(output)
    print(str(output / 'package-inputs.json'))


if __name__ == '__main__':
    main()
