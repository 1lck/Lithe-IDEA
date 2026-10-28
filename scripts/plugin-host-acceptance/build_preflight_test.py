#!/usr/bin/env python3
"""Offline build preparation checks; never invokes Cargo, Tauri or a product."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from acceptance_driver import OwnedProcess, process_exit_proven, run_bounded_process, wait_until
from acceptance_driver_test import run_case

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    tests = []
    process_cleanup = []
    scratch = None
    deadline = time.monotonic() + 180
    try:
        with tempfile.TemporaryDirectory(prefix="lithe-build-preflight-") as temporary:
            root = Path(temporary)
            scratch = root
            scripts = root / "scripts"
            scripts.mkdir()
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
            for name in ("windows-build-preflight.ps1", "build-windows.ps1", "install-windows-frontend-dependencies.ps1", "invoke-windows-tauri-build.ps1"):
                shutil.copyfile(ROOT / "scripts" / name, scripts / name)
            powershell = shutil.which("pwsh")

            def ps(code, expected=0):
                remaining = min(25, deadline - time.monotonic())
                assert remaining > 0, "preflight suite deadline exhausted"
                script = root / "case.ps1"
                script.write_text("$ErrorActionPreference='Stop'\nSet-Location $PSScriptRoot\n" + code, encoding="utf-8")
                result = run_bounded_process([powershell, "-NoProfile", "-File", str(script)], remaining)
                assert result.returncode == expected, result.stdout + result.stderr
                return result.stdout

            initialize = ". ./scripts/windows-build-preflight.ps1\nInitialize-WindowsNativeBun -RepositoryRoot $PSScriptRoot -NativeBunPath ./native/bun.exe\n"

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
. ./scripts/windows-build-preflight.ps1
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

            wrapper = ". ./scripts/windows-build-preflight.ps1\n$manifest=Join-Path $PSScriptRoot 'windows/tauri/src-tauri/Cargo.toml'\n"

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
& ./scripts/invoke-windows-tauri-build.ps1 -TauriArguments @('fake-only')
if($global:attempt -ne 2){throw 'retry not reached'}
'two-attempts'
"""
                )
                assert "two-attempts" in output and manifest.read_bytes() == original

            def installer_budget_reaches_each_owned_worker():
                (scripts / "invoke-windows-bun-install.ps1").write_text("""
param([switch]$NoCache,[int]$TimeoutSeconds)
@{timeout=$TimeoutSeconds;retry=[bool]$NoCache} | ConvertTo-Json -Compress | Add-Content (Join-Path $PSScriptRoot '../attempts.jsonl')
if(-not $NoCache){exit 1}
exit 0
""", encoding="utf-8")
                (scripts / "verify-download-cache.mjs").write_text("process.exit(0);\n", encoding="utf-8")
                for argument, budget in (("", 300), ("-InstallTimeoutSeconds 741", 741)):
                    attempts = root / "attempts.jsonl"
                    attempts.unlink(missing_ok=True)
                    ps(initialize + f"& ./scripts/install-windows-frontend-dependencies.ps1 {argument}")
                    records = [json.loads(line) for line in attempts.read_text(encoding="utf-8-sig").splitlines()]
                    assert records == [{"timeout": budget, "retry": False}, {"timeout": budget, "retry": True}]

            def real_install_job_deadline_reaps_fake_bun_tree():
                worker = (ROOT / "scripts/invoke-windows-bun-install.ps1").read_text(encoding="utf-8-sig")
                # Keep the actual existing Job/deadline owner. Substitute only
                # the Bun command with an offline fixture that waits for IPC.
                worker = worker.replace('$ErrorActionPreference = "Stop"', '$ErrorActionPreference = "Stop"\nfunction bun { & node (Join-Path $PSScriptRoot "../fake-bun.cjs") }', 1)
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
                    (scripts / name).write_text("Write-Output $PSScriptRoot\n", encoding="utf-8")
                (scripts / "install-windows-frontend-dependencies.ps1").write_text("param([int]$InstallTimeoutSeconds)\n$InstallTimeoutSeconds | Set-Content (Join-Path $PSScriptRoot '../build-budget.txt')\n", encoding="utf-8")
                ps("""
function global:rustup { $global:LASTEXITCODE=0 }
function global:bun { $global:LASTEXITCODE=1 }
try { & ./scripts/build-windows.ps1 -NativeBunPath ./native/bun.exe -InstallTimeoutSeconds 741; throw 'unexpected build success' }
catch { if($_ -notmatch 'frontend type check failed'){throw} }
"""
                )
                assert (root / "build-budget.txt").read_text(encoding="utf-8-sig").strip() == "741"

            def acceptance_wires_budget_and_orders_native_before_reuse():
                # Parse the actual acceptance call (without executing any
                # formal build/guards) and execute it against a recording stub.
                entry = ROOT / "scripts/test-windows-declarative-plugin-host.ps1"
                code = r"""
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors}
$call=$ast.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -match '^& .*scripts/build-windows.ps1'},$true)
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
                assert source.index("Initialize-WindowsNativeBun -RepositoryRoot") < source.index('"scripts/reuse-worktree-resources.mjs"')

            for name, case in (
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
                                                      "ownedProcesses": process_cleanup}}, indent=2) + "\n", encoding="utf-8")
    return int(any(test["status"] != "passed" for test in tests))


if __name__ == "__main__":
    raise SystemExit(main())
