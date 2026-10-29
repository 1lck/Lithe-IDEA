#!/usr/bin/env python3
"""Opt-in fixed-source SVN counterexample diagnostic, never product acceptance.

Usage: python vcs_move_diagnostic.py --inputs inputs.json --output <new-directory>
Inputs: node, powershell, provider, sdk, sourceIdentity, svnZip, svnRoot, gate, gateSource.
All paths are explicit absolute paths. No downloads, installed-SVN lookup, Cargo,
package signing, production capability change, or automatic working-copy repair.
sourceIdentity is the sealed R16 source-identity.json; gate/gateSource are its
diagnostic SvnGate.exe/C# input, not an upstream or formal Provider package.
The gate is after actual Provider status and before SVN launch; the fixed
Provider's tracked move handler has no destination precheck.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from xml.etree import ElementTree as ET

CASES = ("missing-leaf", "target-file", "target-directory")
PROVIDER = "3a558be049f47a3ebe24ae770faf7999df883c29"
SDK = "54598ae6e0b9fd71a07b77e1fea6917ba8897a6f"
ZIP_HASH = "98bb798dd6c70cc875b9bdacd600594351cf88f0a39a831a5055df061c871bb5"
SOURCE_HASH = "dcc9058e05de3eaa056373457e3d74752b76d22e70e55fa566f799079c37f60d"
GATE_HASH = "171f4006d9f8de03306c5bf3c5d8b73d56b96e596d4b819a0d6e570b61b9f38e"
GATE_SOURCE_HASH = "ec75d153868e3ce7afa576a9284eb5e680c5b1d0f53c003ddb62efcc167c8d77"
INPUT_KEYS = ("node", "powershell", "provider", "sdk", "sourceIdentity", "svnZip", "svnRoot", "gate", "gateSource")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2), encoding="utf-8")


def budget(deadline, case_seconds, now=time.monotonic):
    remaining = deadline - now()
    if remaining <= 0:
        raise TimeoutError("suite hard deadline exhausted")
    return min(case_seconds, remaining)


def supervised(command, seconds, log, owner_factory, now=time.monotonic):
    """Owner cleanup runs even on runner exceptions and failed assertions."""
    started = now()
    owner = None
    result = {"command": command, "timeoutSeconds": seconds}
    try:
        owner = owner_factory()
        result["exitCode"] = owner.run(command, seconds, log)
        if result["exitCode"] != 0:
            raise RuntimeError(f"worker exited {result['exitCode']}; see {log}")
    except Exception as error:
        result["error"] = str(error)
        if isinstance(error, TimeoutError):
            result["exitCode"] = 124
    finally:
        try:
            result["cleanup"] = owner.close() if owner else {"notStarted": True}
        except Exception as error:
            result["cleanupError"] = str(error)
        result["durationMs"] = (now() - started) * 1000
    result["status"] = "failed" if "error" in result or "cleanupError" in result else "passed"
    return result


def remove_owned_tree(root, seconds=5):
    """Remove only the newly allocated fixture, including SVN read-only revs."""
    root = Path(root).resolve()
    deadline = time.monotonic() + seconds

    def writable_retry(function, path, error):
        target = Path(path).resolve()
        if root not in target.parents or time.monotonic() >= deadline:
            raise error
        os.chmod(target, stat.S_IWRITE | stat.S_IREAD)
        while True:
            try:
                function(target)
                return
            except OSError as failure:
                if getattr(failure, "winerror", None) != 32 or time.monotonic() >= deadline:
                    raise
                # Windows can briefly retain a file during kernel teardown.
                # Retry only this owned path and sharing violation, with a deadline.
                time.sleep(0.01)

    shutil.rmtree(root, onexc=writable_retry)
    return not root.exists()


class WindowsJob:
    """One non-inherited kernel job handle owns a gated Python worker and descendants.

    Same KILL_ON_JOB_CLOSE mechanism as invoke-windows-bun-install.ps1. The
    trusted Python worker cannot launch the requested command until assignment.
    No PID/name based termination, breakaway permission, or tree-scan race.
    """
    def __init__(self):
        from ctypes import wintypes as w
        class Basic(ctypes.Structure):
            _fields_ = [("user", ctypes.c_int64), ("job", ctypes.c_int64), ("flags", w.DWORD),
                        ("minimum", ctypes.c_size_t), ("maximum", ctypes.c_size_t),
                        ("active", w.DWORD), ("affinity", ctypes.c_size_t),
                        ("priority", w.DWORD), ("scheduling", w.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ("ro", "wo", "oo", "rb", "wb", "ob")]
        class Limits(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", IO), ("pm", ctypes.c_size_t),
                        ("jm", ctypes.c_size_t), ("pp", ctypes.c_size_t), ("pj", ctypes.c_size_t)]
        class Accounting(ctypes.Structure):
            _fields_ = [("u", ctypes.c_int64), ("k", ctypes.c_int64), ("pu", ctypes.c_int64),
                        ("pk", ctypes.c_int64), ("faults", w.DWORD), ("total", w.DWORD),
                        ("active", w.DWORD), ("terminated", w.DWORD)]
        self.accounting = Accounting
        self.k = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateJobObjectW": ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
            "SetInformationJobObject": ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
            "AssignProcessToJobObject": ([w.HANDLE, w.HANDLE], w.BOOL),
            "TerminateJobObject": ([w.HANDLE, w.UINT], w.BOOL),
            "QueryInformationJobObject": ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p], w.BOOL),
            "CloseHandle": ([w.HANDLE], w.BOOL),
            "OpenProcess": ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            "WaitForSingleObject": ([w.HANDLE, w.DWORD], w.DWORD),
        }
        for name, (args, ret) in signatures.items():
            getattr(self.k, name).argtypes = args
            getattr(self.k, name).restype = ret
        self.handle = self.k.CreateJobObjectW(None, None)
        self.process = None
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Limits()
        limits.basic.flags = 0x2000
        if not self.k.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            self.k.CloseHandle(self.handle)
            raise ctypes.WinError(ctypes.get_last_error())

    def run(self, command, seconds, log):
        with Path(log).open("wb") as stream:
            self.process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--exec", *command],
                                            stdin=subprocess.PIPE, stdout=stream, stderr=subprocess.STDOUT,
                                            env={**os.environ, "LITHE_VCS_DIAGNOSTIC_OWNER": "windows-job-supervisor"},
                                            creationflags=0x08000000)
            if not self.k.AssignProcessToJobObject(self.handle, int(self.process._handle)):
                # The root has not been released and cannot have descendants.
                self.process.kill()
                self.process.wait(timeout=2)
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                self.process.communicate(b"release\n", timeout=seconds)
            except subprocess.TimeoutExpired as error:
                raise TimeoutError("external worker hard deadline") from error
            return self.process.returncode

    def close(self):
        retained = []
        try:
            # Accounting reaching zero can precede final kernel teardown. Retain
            # member handles for bounded waits; termination still targets the job.
            members = ctypes.create_string_buffer(65536)
            if not self.k.QueryInformationJobObject(self.handle, 3, members, len(members), None):
                raise ctypes.WinError(ctypes.get_last_error())
            count = ctypes.c_uint32.from_buffer(members, 4).value
            for index in range(count):
                pid = ctypes.c_size_t.from_buffer(members, 8 + index * ctypes.sizeof(ctypes.c_size_t)).value
                handle = self.k.OpenProcess(0x00100000, False, pid)
                if handle:
                    retained.append(handle)
            if not self.k.TerminateJobObject(self.handle, 125):
                raise ctypes.WinError(ctypes.get_last_error())
            deadline = time.monotonic() + 5
            for handle in retained:
                remaining = max(0, int((deadline - time.monotonic()) * 1000))
                if self.k.WaitForSingleObject(handle, remaining) != 0:
                    raise TimeoutError("owned member handle did not terminate")
            while True:
                info = self.accounting()
                if not self.k.QueryInformationJobObject(self.handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                    raise ctypes.WinError(ctypes.get_last_error())
                if info.active == 0:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"job cleanup survivors: {info.active}")
                # Native job completion has no Python event; bounded observable polling.
                time.sleep(0.01)
            if self.process:
                self.process.wait(timeout=2)
            return {"activeProcesses": info.active, "totalProcesses": info.total, "jobTerminated": True}
        finally:
            for handle in retained:
                self.k.CloseHandle(handle)
            self.k.CloseHandle(self.handle)


def validate_input_paths(inputs):
    if (set(inputs) != set(INPUT_KEYS)
            or any(not isinstance(inputs[key], str) or not Path(inputs[key]).is_absolute() for key in INPUT_KEYS)):
        raise ValueError("provide exactly the explicit absolute input paths: " + ", ".join(INPUT_KEYS))


def validate_output(inputs, input_file, output):
    """Resolve existing junction parents before any output or fixture writes."""
    validate_input_paths(inputs)
    destination = output.resolve()
    directories = {Path(inputs[key]).resolve() for key in ("provider", "sdk", "svnRoot")}
    protected = {Path(value).resolve() for value in inputs.values()} | {input_file.resolve()}
    for source in protected:
        if (destination == source or destination in source.parents
                or (source in directories and source in destination.parents)):
            raise ValueError(f"output overlaps fixed input: {source}")
    return destination


def cleanup_proven(row):
    cleanup = row.get("cleanup", {})
    return ("cleanupError" not in row and cleanup.get("jobTerminated") is True
            and cleanup.get("activeProcesses") == 0)


def verify_inputs(inputs, runtime, receipt):
    validate_input_paths(inputs)
    for key, expected in (("sourceIdentity", SOURCE_HASH), ("svnZip", ZIP_HASH),
                          ("gate", GATE_HASH), ("gateSource", GATE_SOURCE_HASH)):
        if digest(inputs[key]) != expected:
            raise ValueError(f"fixed {key} identity mismatch")
    source = json.loads(Path(inputs["sourceIdentity"]).read_text())
    if source["commit"] != PROVIDER or source["sdk"]["revision"] != SDK:
        raise ValueError("fixed Provider/SDK revision mismatch")
    identities = []
    for root, rows, field in ((inputs["provider"], source["files"], "path"),
                              (inputs["sdk"], source["lockedSdkFiles"], "upstream")):
        for row in rows:
            file = Path(root) / row[field]
            if digest(file) != row["sha256"]:
                raise ValueError(f"source bytes changed: {file}")
            identities.append({"path": str(file), "sha256": row["sha256"], "bytes": file.stat().st_size})
    svn_root = Path(inputs["svnRoot"])
    with zipfile.ZipFile(inputs["svnZip"]) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            relative = Path(member.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("unsafe ZIP path")
            file = svn_root / relative
            expected = hashlib.sha256(archive.read(member)).hexdigest()
            if digest(file) != expected:
                raise ValueError(f"SVN extraction differs from fixed ZIP: {file}")
            identities.append({"path": str(file), "sha256": expected, "bytes": file.stat().st_size})
    tools = []
    commands = []

    def checked(command, env=None):
        started = time.monotonic()
        row = {"command": command, "timeoutSeconds": 10}
        try:
            result = subprocess.run(command, env=env, timeout=10, creationflags=0x08000000,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            row.update(exitCode=result.returncode, stdout=result.stdout.decode("utf-8-sig", errors="replace"),
                       stderr=result.stderr.decode("utf-8-sig", errors="replace"))
            result.check_returncode()
            return result.stdout
        except Exception as error:
            row["error"] = str(error)
            raise
        finally:
            row["durationMs"] = (time.monotonic() - started) * 1000
            commands.append(row)
            write_json(Path(receipt).with_name("identity-commands.json"), commands)

    for name in ("svn.exe", "svnadmin.exe"):
        file = svn_root / "bin" / name
        data = file.read_bytes()
        offset = int.from_bytes(data[60:64], "little")
        if data[:2] != b"MZ" or data[offset:offset+6] != b"PE\0\0\x64\x86":
            raise ValueError("SVN is not PE x64")
        env = {**os.environ, "LITHE_DIAGNOSTIC_SIGNED_FILE": str(file)}
        # A pwsh caller's module path can prevent Windows PowerShell from loading
        # its own signing module. Let this child initialize its native defaults.
        env.pop("PSModulePath", None)
        signature = checked([inputs["powershell"], "-NoProfile", "-Command",
            "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); "
            "$s=Get-AuthenticodeSignature -LiteralPath $env:LITHE_DIAGNOSTIC_SIGNED_FILE; "
            "@{status=[string]$s.Status;subject=$s.SignerCertificate.Subject;thumbprint=$s.SignerCertificate.Thumbprint} | ConvertTo-Json -Compress"],
            env=env).decode("utf-8-sig")
        signature = json.loads(signature)
        if signature["status"] != "Valid" or signature["thumbprint"] != "6F0D0D78D3D3285EC16DB943B59E806B8B26D9B1":
            raise ValueError("SVN publisher signature mismatch")
        version = checked([str(file), "--version"]).decode()
        if "version 1.15.0 (r1937767)" not in version:
            raise ValueError("SVN version mismatch")
        tools.append({"path": str(file), "signature": signature, "version": version, "machine": "8664"})
    runtime = Path(runtime)
    runtime.mkdir()
    for name in ("svn-provider.mjs", "svn-output.mjs", "xml.mjs"):
        shutil.copyfile(Path(inputs["provider"]) / "io.github.lithe-idea.svn-support/provider" / name, runtime / name)
    vendor = runtime / "vendor/lithe-plugin-sdk"
    vendor.mkdir(parents=True)
    for row in source["lockedSdkFiles"]:
        if row["path"].startswith("vendor/lithe-plugin-sdk/src/") and row["path"].endswith(".mjs"):
            shutil.copyfile(Path(inputs["provider"]) / row["path"], vendor / Path(row["path"]).name)
    runtime_files = [{"path": str(file), "sha256": digest(file)} for file in sorted(runtime.rglob("*")) if file.is_file()]
    write_json(receipt, {"verified": True, "providerRepository": "https://github.com/Lithe-IDEA/lithe-plugin-svn",
                         "provider": PROVIDER, "sdk": SDK, "sourceManifest": source, "files": identities,
                         "runtimeFiles": runtime_files,
                         "svnSource": "https://www.visualsvn.com/files/Apache-Subversion-1.15.0-x64.zip",
                         "zipSha256": ZIP_HASH, "tools": tools, "gateSha256": GATE_HASH,
                         "gateSourceSha256": GATE_SOURCE_HASH, "formalWindowsPackage": False})


def reports(output, rows):
    write_json(output / "timing.json", {"runner": "SVN move explicit diagnostic", "tests": rows})
    suite = ET.Element("testsuite", name="vcs-move-diagnostic", tests=str(len(rows)),
                       failures=str(sum(row["status"] != "passed" for row in rows)))
    for row in rows:
        case = ET.SubElement(suite, "testcase", name=row["name"], time=str(row["durationMs"] / 1000))
        if row["status"] != "passed":
            ET.SubElement(case, "failure").text = json.dumps(row)
    ET.ElementTree(suite).write(output / "timing.junit.xml", encoding="utf-8", xml_declaration=True)
    (output / "timing.html").write_text("<!doctype html><meta charset=utf-8><title>SVN move diagnostic</title>"
        "<h1>Diagnostic execution; counterexamples are not safety passes</h1><pre>" +
        html.escape(json.dumps(rows, indent=2)) + "</pre>", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case-seconds", type=float, default=45)
    parser.add_argument("--suite-seconds", type=float, default=180)
    args = parser.parse_args()
    if os.name != "nt" or not 1 <= args.case_seconds <= 120 or not 1 <= args.suite_seconds <= 600:
        parser.error("Windows required; case 1..120 seconds and suite 1..600 seconds")
    inputs = json.loads(args.inputs.read_text(encoding="utf-8-sig"))
    args.output = validate_output(inputs, args.inputs, args.output)
    args.output.mkdir(parents=True, exist_ok=False)
    rows = []
    deadline = time.monotonic() + args.suite_seconds
    temporary = Path(tempfile.mkdtemp(prefix="vcs-move-"))
    cleanup = {"temporary": str(temporary), "removed": False}
    all_jobs_closed = True
    try:
        runtime = temporary / "runtime"
        steps = [("identity", [sys.executable, str(Path(__file__).resolve()), "--verify", str(args.inputs.resolve()),
                               str(runtime), str(args.output.resolve() / "identity.json")])]
        worker = Path(__file__).with_name("vcs-move-diagnostic-worker.mjs")
        for name in CASES:
            steps.append((name, [inputs["node"], str(worker), str(args.inputs.resolve()), name,
                                  str(temporary / name), str(runtime), str(args.output.resolve() / (name + ".json"))]))
        for name, command in steps:
            try:
                seconds = budget(deadline, args.case_seconds)
            except TimeoutError as error:
                rows.append({"name": name, "status": "failed", "error": str(error), "durationMs": 0, "exitCode": 124})
                break
            row = supervised(command, seconds, args.output / (name + ".log"), WindowsJob)
            if not cleanup_proven(row) and not row.get("cleanup", {}).get("notStarted"):
                all_jobs_closed = False
                row.update(status="failed", cleanupError=row.get("cleanupError", "job termination has no zero-member receipt"))
            evidence = args.output / ("identity.json" if name == "identity" else name + ".json")
            if row["status"] == "passed":
                try:
                    receipt = json.loads(evidence.read_text())
                    if name == "identity" and receipt.get("verified") is not True:
                        raise AssertionError("identity verification did not complete")
                    if name != "identity" and (receipt.get("status") != "diagnosis-matched" or receipt.get("safetyPass") is not False):
                        raise AssertionError("worker did not record a diagnostic-only result")
                except Exception as error:
                    row.update(status="failed", evidenceError=str(error))
            if row["status"] != "passed" and name != "identity":
                row.update(operationOutcome="unknown", refreshRequired=True)
                # Only a proven zero-member job permits another SVN reader.
                # Otherwise retain the fixture so no deletion races a survivor.
                if not cleanup_proven(row):
                    row["afterUnavailable"] = "cleanup-unproven"
                else:
                    try:
                        recovery_seconds = budget(deadline, 12)
                        row["recovery"] = supervised([inputs["node"], str(worker), "--snapshot", str(args.inputs.resolve()),
                            str(temporary / name / "wc"), str(args.output.resolve() / (name + "-recovery.json"))],
                            recovery_seconds, args.output / (name + "-recovery.log"), WindowsJob)
                        if not cleanup_proven(row["recovery"]) and not row["recovery"].get("cleanup", {}).get("notStarted"):
                            all_jobs_closed = False
                    except TimeoutError as error:
                        row["afterUnavailable"] = str(error)
            rows.append({"name": name, **row})
            reports(args.output, rows)
            if row["status"] != "passed":
                break
        if not all_jobs_closed:
            cleanup["inputBytesUnavailable"] = "cleanup-unproven"
        elif (args.output / "identity.json").exists():
            started = time.monotonic()
            try:
                identity = json.loads((args.output / "identity.json").read_text())
                changed = [row["path"] for row in identity["files"] + identity["runtimeFiles"] if digest(row["path"]) != row["sha256"]]
                cleanup["inputBytesUnchanged"] = not changed
                if changed:
                    raise AssertionError(f"read-only inputs changed: {changed}")
            except Exception as error:
                cleanup["inputBytesUnchanged"] = False
                rows.append({"name": "input-immutability", "status": "failed", "error": str(error),
                             "durationMs": (time.monotonic() - started) * 1000, "exitCode": 1})
    except Exception as error:
        rows.append({"name": "suite-exception", "status": "failed", "error": str(error), "durationMs": 0, "exitCode": 1})
        raise
    finally:
        try:
            if all_jobs_closed:
                cleanup["removed"] = remove_owned_tree(temporary)
            else:
                cleanup["retained"] = "cleanup-unproven; isolate until exact owned processes are confirmed terminated"
        except Exception as error:
            cleanup["error"] = str(error)
            rows.append({"name": "temporary-cleanup", "status": "failed", "error": str(error), "durationMs": 0, "exitCode": 1})
            raise
        finally:
            write_json(args.output / "cleanup.json", cleanup)
            reports(args.output, rows)
    return 0 if len(rows) == 4 and all(row["status"] == "passed" for row in rows) else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--exec"]:
        if sys.stdin.buffer.readline() != b"release\n":
            raise SystemExit(125)
        # The external job owner supplies the hard timeout for this whole worker.
        raise SystemExit(subprocess.call(sys.argv[2:]))
    if sys.argv[1:2] == ["--verify"]:
        verify_inputs(json.loads(Path(sys.argv[2]).read_text(encoding="utf-8-sig")), sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(main())
