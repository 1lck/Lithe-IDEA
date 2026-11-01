#!/usr/bin/env python3
"""Offline build preparation checks; never invokes Cargo, Tauri or a product."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import tarfile
import time
import zipfile
from pathlib import Path

from acceptance_driver import OwnedProcess, process_exit_proven, run_bounded_process, wait_until
from acceptance_driver_test import run_case
from vcs_move_diagnostic import WindowsJob, supervised

ROOT = Path(__file__).resolve().parents[3]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    tests = []
    process_cleanup = []
    archive_jobs = []
    scratch = None
    deadline = time.monotonic() + 180
    try:
        with tempfile.TemporaryDirectory(prefix="lithe-build-preflight-") as temporary:
            root = Path(temporary)
            scratch = root
            scripts = root / "scripts/windows/build"
            scripts.mkdir(parents=True)
            prepares = root / "scripts/windows/prepare"
            prepares.mkdir(parents=True)
            resources = root / "scripts/resources"
            resources.mkdir(parents=True)
            app = root / "windows/tauri"
            (app / "src-tauri").mkdir(parents=True)
            (app / "src/extensions/bundled").mkdir(parents=True)
            native = root / "native"
            native.mkdir()
            # Node is an offline native stand-in: it implements --version and
            # can be found by spawnSync when named bun.exe. No Bun install runs.
            shutil.copyfile(shutil.which("node"), native / "bun.exe")
            version = run_bounded_process([str(native / "bun.exe"), "--version"], 5).stdout.strip()
            package = app / "package.json"
            package.write_text(json.dumps({"packageManager": "bun@" + version}), encoding="utf-8")
            for name in ("windows-build-preflight.ps1", "build-windows.ps1", "install-windows-frontend-dependencies.ps1", "invoke-windows-tauri-build.ps1", "prepare-jdtls.ps1", "windows-tree-sitter-proxy.cjs"):
                directory = "scripts/windows/prepare" if name.startswith("prepare-") else "scripts/windows/build"
                shutil.copyfile(ROOT / directory / name, (prepares if name.startswith("prepare-") else scripts) / name)
            powershell = shutil.which("pwsh")

            def jdtls_fixture(name, *, corrupt_archive=False):
                fixture = root / name
                fixture_scripts = fixture / "scripts/windows/prepare"
                fixture_scripts.mkdir(parents=True)
                shutil.copyfile(prepares / "prepare-jdtls.ps1", fixture_scripts / "prepare-jdtls.ps1")
                jdt = fixture / "third_party/jdtls"
                jdt.mkdir(parents=True)
                jdk = fixture / "third_party/jdk"
                jdk.mkdir(parents=True)
                (jdk / "manifest.json").write_text('{"version":"21.0.0"}', encoding="utf-8")
                cache = fixture / ".artifacts/jdtls-downloads"
                cache.mkdir(parents=True)
                manifest = json.loads((ROOT / "third_party/jdtls/manifest.json").read_text(encoding="utf-8"))
                # All payloads are tiny, locally generated fixture bytes. The
                # real preparation script still checks every declared SHA.
                manifest.update(version="1-fixture", lombokVersion="1", javaDebugExtensionVersion="1",
                                javaDebugServerVersion="1", javaTestExtensionVersion="1", javaTestPluginVersion="1")
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                    for filename in ("bin/jdtls.ps1", "bin/jdtls.bat", "plugins/org.eclipse.equinox.launcher_fixture.jar",
                                     "config_mac/config.ini", "config_win/config.ini"):
                        data = b"offline fixture\n"
                        entry = tarfile.TarInfo(filename)
                        entry.size = len(data)
                        archive.addfile(entry, io.BytesIO(data))
                archive_bytes = b"not a gzip archive\n" if corrupt_archive else payload.getvalue()
                archive_path = fixture / "absolute archive with spaces.tar.gz"
                archive_path.write_bytes(archive_bytes)
                manifest["archiveSHA256"] = hashlib.sha256(archive_bytes).hexdigest()

                def cached(field, filename, data):
                    digest = hashlib.sha256(data).hexdigest()
                    manifest[field + "SHA256"] = digest
                    manifest[field + "URL"] = "https://offline.invalid/not-requested"
                    (cache / filename.format(hash=digest)).write_bytes(data)

                cached("license", "EPL-2.0-{hash}.txt", b"fixture EPL")
                cached("lombok", "lombok-1-{hash}.jar", b"fixture lombok")
                cached("lombokLicense", "lombok-MIT-1-{hash}.txt", b"fixture lombok MIT")
                debug_plugin = b"fixture debug plugin"
                manifest["javaDebugPluginSHA256"] = hashlib.sha256(debug_plugin).hexdigest()
                debug_zip = io.BytesIO()
                with zipfile.ZipFile(debug_zip, "w") as archive:
                    archive.writestr("extension/server/com.microsoft.java.debug.plugin-1.jar", debug_plugin)
                cached("javaDebugArchive", "vscode-java-debug-1-{hash}.zip", debug_zip.getvalue())
                cached("javaDebugLicense", "java-debug-EPL-1.0-1-{hash}.txt", b"fixture debug EPL")
                test_plugin, test_runner = b"fixture test plugin", b"fixture test runner"
                manifest["javaTestPluginSHA256"] = hashlib.sha256(test_plugin).hexdigest()
                manifest["javaTestRunnerSHA256"] = hashlib.sha256(test_runner).hexdigest()
                test_zip = io.BytesIO()
                with zipfile.ZipFile(test_zip, "w") as archive:
                    archive.writestr("extension/package.json", json.dumps({"contributes": {"javaExtensions": ["./server/com.microsoft.java.test.plugin-1.jar"]}}))
                    archive.writestr("extension/server/com.microsoft.java.test.plugin-1.jar", test_plugin)
                    archive.writestr("extension/server/com.microsoft.java.test.runner-jar-with-dependencies.jar", test_runner)
                cached("javaTestArchive", "vscode-java-test-1-{hash}.zip", test_zip.getvalue())
                cached("javaTestLicense", "java-test-MIT-1-{hash}.txt", b"fixture test MIT")
                (jdt / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                fake_tar = fixture / "fake GNU tar"
                fake_tar.mkdir()
                # An executable named tar.exe at the front of PATH must never
                # be launched. Node without its normal arguments rejects -xzf.
                shutil.copyfile(native / "bun.exe", fake_tar / "tar.exe")
                return fixture

            def jdtls_job(fixture, code, expected=0):
                remaining = min(25, deadline-time.monotonic())
                assert remaining > 0, "preflight suite deadline exhausted"
                script = fixture / "case.ps1"
                script.write_text("""$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
$env:LITHE_JDTLS_ROOT=''
$env:LITHE_JDTLS_ARCHIVE=Join-Path $PSScriptRoot 'absolute archive with spaces.tar.gz'
$env:PATH=(Join-Path $PSScriptRoot 'fake GNU tar')+[IO.Path]::PathSeparator+$env:PATH
function global:Invoke-WebRequest { throw 'offline fixture attempted a download' }
""" + code, encoding="utf-8")
                log = fixture / "job.log"
                row = supervised([powershell, "-NoProfile", "-File", str(script)], remaining, log, WindowsJob)
                archive_jobs.append({"fixture": fixture.name, **row})
                output = log.read_text(encoding="utf-8", errors="replace")
                assert row.get("cleanup", {}).get("jobTerminated") is True and row["cleanup"]["activeProcesses"] == 0, row
                assert row.get("exitCode") == expected and row.get("status") == ("passed" if expected == 0 else "failed"), output
                return output

            def native_tar_ignores_path_and_extracts_absolute_space_paths():
                fixture = jdtls_fixture("JDT success with spaces")
                output = jdtls_job(fixture, """
$fake=Join-Path $PSScriptRoot 'fake GNU tar/tar.exe'
if((Get-Command tar.exe).Source -ne $fake){throw 'fixture did not prepend fake GNU tar'}
& ./scripts/windows/prepare/prepare-jdtls.ps1 -OutputDirectory (Join-Path $PSScriptRoot '.artifacts/JDT output with spaces')
""")
                target = fixture / ".artifacts/JDT output with spaces"
                assert (target / "config_win/config.ini").read_bytes() == b"offline fixture\n", output
                assert "-javaagent:" in (target / "bin/jdtls.ps1").read_text()
                assert (target / "java-test/extensions.txt").read_text().strip() == "com.microsoft.java.test.plugin-1.jar"
                assert str(target) in output

            def failed_native_tar_preserves_error_and_stops_copy():
                fixture = jdtls_fixture("JDT corrupt with spaces", corrupt_archive=True)
                output = jdtls_job(fixture, """
& ./scripts/windows/prepare/prepare-jdtls.ps1 -OutputDirectory (Join-Path $PSScriptRoot '.artifacts/JDT output with spaces')
""", expected=1)
                target = fixture / ".artifacts/JDT output with spaces"
                assert "JDTLS archive extraction failed (native tar exit" in output, output
                # PowerShell may wrap the archive path at spaces in its error
                # rendering; the native diagnostic and script failure stay intact.
                assert "absolute archive with" in output and "spaces.tar.gz" in output and "tar.exe:" in output, output
                for filename in ("LICENSE-EPL-2.0.txt", "manifest.json", "lombok/lombok.jar", "bin/jdtls.ps1"):
                    assert not (target / filename).exists(), filename

            def missing_native_tar_fails_before_mutating_cache_or_output():
                fixture = jdtls_fixture("JDT missing native tar")
                shutil.rmtree(fixture / ".artifacts/jdtls-downloads")
                target = fixture / ".artifacts/JDT output with spaces"
                target.mkdir()
                (target / "keep.txt").write_bytes(b"existing output")
                output = jdtls_job(fixture, """
function global:Test-Path {
    param([string]$LiteralPath,[string]$PathType)
    if($LiteralPath -eq (Join-Path ([Environment]::SystemDirectory) 'tar.exe')){return $false}
    Microsoft.PowerShell.Management\\Test-Path @PSBoundParameters
}
& ./scripts/windows/prepare/prepare-jdtls.ps1 -OutputDirectory (Join-Path $PSScriptRoot '.artifacts/JDT output with spaces')
""", expected=1)
                assert "Native Windows tar was not found:" in output, output
                assert not (fixture / ".artifacts/jdtls-downloads").exists()
                assert (target / "keep.txt").read_bytes() == b"existing output"

            def ps(code, expected=0):
                remaining = min(25, deadline - time.monotonic())
                assert remaining > 0, "preflight suite deadline exhausted"
                script = root / "case.ps1"
                script.write_text("$ErrorActionPreference='Stop'\nSet-Location $PSScriptRoot\n" + code, encoding="utf-8")
                result = run_bounded_process([powershell, "-NoProfile", "-File", str(script)], remaining)
                assert result.returncode == expected, result.stdout + result.stderr
                return result.stdout

            initialize = ". ./scripts/windows/build/windows-build-preflight.ps1\nInitialize-WindowsNativeBun -RepositoryRoot $PSScriptRoot -NativeBunPath ./native/bun.exe\n"

            def native_path_precedes_node_verifier():
                output = ps(initialize + "& node -e \"const r=require('child_process').spawnSync('bun',['--version'],{encoding:'utf8'}); if(r.error||r.status!==0)process.exit(1); console.log(r.stdout.trim())\"\nif($LASTEXITCODE -ne 0){throw 'spawn failed'}")
                assert version in output

            def npm_shim_resolves_native_without_executing_shim():
                shim = root / "shim"
                packaged = shim / "node_modules/bun/bin"
                packaged.mkdir(parents=True)
                tools = root / "node-only"
                tools.mkdir()
                os.link(native / "bun.exe", tools / "node.exe")
                # This hardlink is confined to the disposable fixture. It is
                # never a link to another worktree or a mutable build cache.
                os.link(native / "bun.exe", packaged / "bun.exe")
                (shim / "bun.ps1").write_text("throw 'shim must not execute'\n", encoding="utf-8")
                output = ps("""
. ./scripts/windows/build/windows-build-preflight.ps1
$env:PATH=(Join-Path $PSScriptRoot 'shim')+[IO.Path]::PathSeparator+(Join-Path $PSScriptRoot 'node-only')
Initialize-WindowsNativeBun -RepositoryRoot $PSScriptRoot
& node -e "const r=require('child_process').spawnSync('bun',['--version'],{encoding:'utf8'});if(r.error||r.status)process.exit(1);console.log(r.stdout.trim())"
if($LASTEXITCODE -ne 0){throw 'spawn failed'}
""")
                assert version in output

            def wrong_version_and_missing_native_fail():
                try:
                    package.write_text('{"packageManager":"bun@0.0.0-fixture"}', encoding="utf-8")
                    ps(initialize, expected=1)
                finally:
                    package.write_text(json.dumps({"packageManager": "bun@" + version}), encoding="utf-8")
                ps(initialize.replace("./native/bun.exe", "./missing/bun.exe"), expected=1)

            manifest = app / "src-tauri/Cargo.toml"
            original = b'[package]\r\nname = "fixture"\r\n# \xe4\xb8\xad\xe6\x96\x87\r\n'

            wrapper = ". ./scripts/windows/build/windows-build-preflight.ps1\n$manifest=Join-Path $PSScriptRoot 'windows/tauri/src-tauri/Cargo.toml'\n"

            def unchanged_manifest_is_not_rewritten():
                manifest.write_bytes(original)
                output = ps(wrapper + """
$stamp=[datetime]::new(2001,2,3,4,5,6,[DateTimeKind]::Utc)
[IO.File]::SetLastWriteTimeUtc($manifest,$stamp)
Invoke-TauriWithOriginalManifestBytes $manifest { }
if([IO.File]::GetLastWriteTimeUtc($manifest) -ne $stamp){throw 'unchanged manifest was rewritten'}
'unchanged'
""")
                assert "unchanged" in output and manifest.read_bytes() == original

            def tauri_admitted_conversion_restores_on_success_and_failure():
                manifest.write_bytes(original)
                ps(wrapper + "Invoke-TauriWithOriginalManifestBytes $manifest { $b=[IO.File]::ReadAllText($manifest).Replace(\"`r`n\",\"`n\"); [IO.File]::WriteAllText($manifest,$b) }")
                assert manifest.read_bytes() == original
                # Failure after an admitted conversion keeps the first error.
                output = ps(wrapper + "try { Invoke-TauriWithOriginalManifestBytes $manifest { [IO.File]::WriteAllText($manifest,[IO.File]::ReadAllText($manifest).Replace(\"`r`n\",\"`n\")); throw 'first-build-error' } } catch { if($_ -notmatch 'first-build-error'){throw}; 'first-preserved' }")
                assert "first-preserved" in output and manifest.read_bytes() == original

            def semantic_manifest_edit_is_preserved_and_both_errors_reported():
                for action_failure in (False, True):
                    manifest.write_bytes(original)
                    action = "[IO.File]::WriteAllText($manifest,'semantic-change');" + ("throw 'first-build-error'" if action_failure else "")
                    verify = "if($_ -notmatch 'beyond.*admitted'){throw};"
                    if action_failure:
                        verify += "if($_.Exception -isnot [AggregateException] -or $_ -notmatch 'first-build-error'){throw};"
                    output = ps(wrapper + f"try {{ Invoke-TauriWithOriginalManifestBytes $manifest {{ {action} }}; throw 'unexpected success' }} catch {{ {verify} 'preserved' }}")
                    assert "preserved" in output and manifest.read_bytes() == b"semantic-change"

            def locked_manifest_is_preserved_without_racing_a_read_and_write():
                manifest.write_bytes(original)
                output = ps(wrapper + """
$held=$null
try {
    try {
        Invoke-TauriWithOriginalManifestBytes $manifest {
            [IO.File]::WriteAllText($manifest,[IO.File]::ReadAllText($manifest).Replace("`r`n","`n"))
            $script:held=[IO.File]::Open($manifest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            throw 'first-build-error'
        }
        throw 'unexpected success'
    } catch {
        if($_.Exception -isnot [AggregateException] -or $_ -notmatch 'first-build-error'){throw}
        if($_.Exception.InnerExceptions[0].InnerException -isnot [IO.IOException]){throw}
        'locked-preserved'
    }
} finally { if($held){$held.Dispose()} }
""")
                assert "locked-preserved" in output and manifest.read_bytes() == original.replace(b"\r\n", b"\n")

            def removed_manifest_is_not_recreated_and_keeps_action_failure():
                manifest.write_bytes(original)
                output = ps(wrapper + """
try {
    Invoke-TauriWithOriginalManifestBytes $manifest { Remove-Item -LiteralPath $manifest; throw 'first-build-error' }
    throw 'unexpected success'
} catch {
    if($_.Exception -isnot [AggregateException] -or $_ -notmatch 'first-build-error'){throw}
    'removed-preserved'
}
if(Test-Path -LiteralPath $manifest){throw 'deleted manifest was recreated'}
""")
                assert "removed-preserved" in output and not manifest.exists()

            def real_tauri_owner_wraps_both_attempts():
                manifest.write_bytes(original)
                output = ps("""
$env:LITHE_CARGO_BUILD_CACHE_RESTORED='true'
$global:attempt=0
function global:bunx {
    $global:attempt++
    $manifest=Join-Path $PSScriptRoot 'windows/tauri/src-tauri/Cargo.toml'
    [IO.File]::WriteAllText($manifest,[IO.File]::ReadAllText($manifest).Replace("`r`n","`n"))
    $global:LASTEXITCODE=if($global:attempt -eq 1){1}else{0}
}
& ./scripts/windows/build/invoke-windows-tauri-build.ps1 -TauriArguments @('fake-only')
if($global:attempt -ne 2){throw 'retry not reached'}
'two-attempts'
"""
                )
                assert "two-attempts" in output and manifest.read_bytes() == original

            def installer_budget_reaches_each_owned_worker():
                (scripts / "invoke-windows-bun-install.ps1").write_text("""
param([switch]$NoCache,[int]$TimeoutSeconds)
@{timeout=$TimeoutSeconds;retry=[bool]$NoCache} | ConvertTo-Json -Compress | Add-Content (Join-Path $PSScriptRoot '../../../attempts.jsonl')
if(-not $NoCache){exit 1}
exit 0
""", encoding="utf-8")
                (resources / "verify-download-cache.mjs").write_text("process.exit(0);\n", encoding="utf-8")
                for argument, budget in (("", 300), ("-InstallTimeoutSeconds 741", 741)):
                    attempts = root / "attempts.jsonl"
                    attempts.unlink(missing_ok=True)
                    ps(initialize + f"& ./scripts/windows/build/install-windows-frontend-dependencies.ps1 {argument}")
                    records = [json.loads(line) for line in attempts.read_text(encoding="utf-8-sig").splitlines()]
                    assert records == [{"timeout": budget, "retry": False}, {"timeout": budget, "retry": True}]

            def real_install_job_deadline_reaps_fake_bun_tree():
                worker = (ROOT / "scripts/windows/build/invoke-windows-bun-install.ps1").read_text(encoding="utf-8-sig")
                # Keep the actual existing Job/deadline owner. Substitute only
                # the Bun command with an offline fixture that waits for IPC.
                worker = worker.replace('$ErrorActionPreference = "Stop"', '$ErrorActionPreference = "Stop"\nfunction bun { & node (Join-Path $PSScriptRoot "../../../fake-bun.cjs") }', 1)
                worker_path = scripts / "owned-worker.ps1"
                worker_path.write_text(worker, encoding="utf-8")
                marker = root / "ready.json"
                (root / "fake-bun.cjs").write_text("""
const {spawn}=require('child_process'),fs=require('fs'),path=require('path');
const child=spawn(process.execPath,['-e',"process.send('ready');process.stdin.resume()"],{stdio:['pipe','ignore','ignore','ipc']});
child.on('message',()=>fs.writeFileSync(path.join(__dirname,'ready.json'),JSON.stringify([process.pid,child.pid])));
process.stdin.resume();
""", encoding="utf-8")
                owners = []
                process = subprocess.Popen([powershell, "-NoProfile", "-File", str(worker_path), "-TimeoutSeconds", "3"],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    wait_until(lambda: marker.exists() or process.poll() is not None, min(10, deadline-time.monotonic()), "fake Bun IPC readiness")
                    assert marker.exists(), "worker exited before fake Bun readiness"
                    for pid in json.loads(marker.read_text(encoding="utf-8")):
                        owner = OwnedProcess.capture(pid)
                        assert owner is not None, "fixture exited before handle retention"
                        owners.append(owner)
                    # Keep stdin open until the real worker's deadline fires.
                    process.wait(timeout=8)
                    stdout, stderr = process.communicate(timeout=2)
                    assert process.returncode == 124, repr((stdout, stderr))
                    assert b"exceeded its 3 second deadline" in stderr
                    wait_until(lambda: all(not owner.running() for owner in owners), 5, "Job-owned fixture exit")
                finally:
                    if process.poll() is None:
                        process.kill()  # Popen retains this exact worker handle.
                        process.wait(timeout=5)  # Job close releases descendants.
                    try:
                        for owner in owners:
                            owner.terminate()
                        wait_until(lambda: all(not owner.running() for owner in owners), 5, "retained fixture cleanup")
                        assert all(process_exit_proven(owner.pid) for owner in owners)
                        process_cleanup.extend({"pid": owner.pid, "creationTime": owner.creation_time,
                                                "signaled": not owner.running()} for owner in owners)
                        process_cleanup.append({"pid": process.pid, "owner": "Popen retained kernel handle",
                                                "exitCode": process.returncode, "exited": process.poll() is not None})
                    finally:
                        for owner in owners:
                            owner.close()
                        for stream in (process.stdin, process.stdout, process.stderr):
                            stream.close()

            def build_budget_reaches_installer():
                for name in ("prepare-jdtls.ps1", "prepare-jdk.ps1", "prepare-conpty.ps1"):
                    (prepares / name).write_text("Write-Output $PSScriptRoot\n", encoding="utf-8")
                (scripts / "install-windows-frontend-dependencies.ps1").write_text("param([int]$InstallTimeoutSeconds)\n$InstallTimeoutSeconds | Set-Content (Join-Path $PSScriptRoot '../../../build-budget.txt')\n", encoding="utf-8")
                ps("""
function global:rustup { $global:LASTEXITCODE=0 }
function global:bun { $global:LASTEXITCODE=1 }
try { & ./scripts/windows/build/build-windows.ps1 -NativeBunPath ./native/bun.exe -InstallTimeoutSeconds 741; throw 'unexpected build success' }
catch { if($_ -notmatch 'frontend type check failed'){throw} }
"""
                )
                assert (root / "build-budget.txt").read_text(encoding="utf-8-sig").strip() == "741"

            def acceptance_wires_budget_and_orders_native_before_reuse():
                # Parse the actual acceptance call (without executing any
                # formal build/guards) and execute it against a recording stub.
                entry = ROOT / "scripts/plugins/test-windows-declarative-plugin-host.ps1"
                code = r"""
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors}
$call=$ast.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -match '^& .*scripts/windows/build/build-windows.ps1'},$true)
if(-not $call){throw 'build call missing'}
$root=$PSScriptRoot; $RustTarget='x86_64-pc-windows-msvc'; $InstallTimeoutSeconds=741
Invoke-Expression $call.Extent.Text
"""
                (scripts / "build-windows.ps1").write_text("param($Configuration,$RustTarget,$InstallTimeoutSeconds)\nif($InstallTimeoutSeconds -ne 741){throw 'acceptance lost budget'}\n", encoding="utf-8")
                # Literal paths are data, passed as script arguments.
                script = root / "entry-check.ps1"
                script.write_text(code, encoding="utf-8")
                result = run_bounded_process([powershell, "-NoProfile", "-File", str(script), str(entry)], min(10, deadline-time.monotonic()))
                assert result.returncode == 0, result.stdout + result.stderr
                source = entry.read_text(encoding="utf-8")
                assert source.index("Initialize-WindowsNativeBun -RepositoryRoot") < source.index('"scripts/resources/reuse-worktree-resources.mjs"')

            for name, case in (
                ("native Windows tar ignores PATH and extracts absolute drive paths with spaces", native_tar_ignores_path_and_extracts_absolute_space_paths),
                ("native tar extraction failure preserves its diagnostic and prevents later copies", failed_native_tar_preserves_error_and_stops_copy),
                ("missing native tar fails before cache or output mutation", missing_native_tar_fails_before_mutating_cache_or_output),
                ("native Bun is inherited by Node spawnSync before cache verification", native_path_precedes_node_verifier),
                ("npm PowerShell shim resolves adjacent native Bun without running shim", npm_shim_resolves_native_without_executing_shim),
                ("wrong Bun version and missing native executable fail closed", wrong_version_and_missing_native_fail),
                ("unchanged manifest bytes and write timestamp remain untouched", unchanged_manifest_is_not_rewritten),
                ("exact CRLF to LF conversion restores bytes after successful and failed actions", tauri_admitted_conversion_restores_on_success_and_failure),
                ("semantic manifest edits survive rejection and preserve the action error", semantic_manifest_edit_is_preserved_and_both_errors_reported),
                ("concurrent manifest reader prevents exclusive restoration without changing bytes", locked_manifest_is_preserved_without_racing_a_read_and_write),
                ("removed manifest is not recreated and the action error remains visible", removed_manifest_is_not_recreated_and_keeps_action_failure),
                ("existing Tauri retry owner restores original manifest bytes", real_tauri_owner_wraps_both_attempts),
                ("installer preserves default and explicit per-attempt budgets through retry", installer_budget_reaches_each_owned_worker),
                ("existing install Job deadline reaps offline fake Bun and IPC child", real_install_job_deadline_reaps_fake_bun_tree),
                ("real build entry passes its explicit budget to installer", build_budget_reaches_installer),
                ("acceptance build call passes budget and initializes native Bun before reuse", acceptance_wires_budget_and_orders_native_before_reuse),
            ):
                run_case(name, case, tests, max_ms=30_000)
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"runner": "acceptance", "warnMs": 5000, "maxMs": 30_000, "tests": tests,
                                          "cleanup": {"scratchPath": str(scratch), "scratchExists": bool(scratch and scratch.exists()),
                                                      "ownedProcesses": process_cleanup, "archiveJobs": archive_jobs}}, indent=2) + "\n", encoding="utf-8")
    return int(any(test["status"] != "passed" for test in tests))


if __name__ == "__main__":
    raise SystemExit(main())
