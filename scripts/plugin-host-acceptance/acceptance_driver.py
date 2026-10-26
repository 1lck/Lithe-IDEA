#!/usr/bin/env python3
"""Drive the real Windows Tauri/WebView2 declarative-plugin workflow."""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from ctypes import wintypes
from pathlib import Path

import psutil
from playwright.sync_api import Page, Playwright, expect, sync_playwright


PLUGIN_ID = "io.github.lithe-acceptance.host"
DISPLAY_NAME = "Lithe Host Acceptance"
ACCEPTANCE_IDENTIFIER = "app.lithe.windows.host-acceptance"
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PROCESS_TERMINATE = 0x0001
SYNCHRONIZE = 0x00100000
WAIT_TIMEOUT = 258
TH32CS_SNAPPROCESS = 0x00000002
ERROR_NO_MORE_FILES = 18
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


class ProcessEntry32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
        ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260),
    ]


kernel32 = ctypes.windll.kernel32
kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32)]
kernel32.Process32FirstW.restype = wintypes.BOOL
kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32)]
kernel32.Process32NextW.restype = wintypes.BOOL
kernel32.GetLastError.argtypes = []
kernel32.GetLastError.restype = wintypes.DWORD
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
kernel32.GetExitCodeProcess.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
kernel32.GetProcessTimes.restype = wintypes.BOOL
kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.WaitForSingleObject.restype = wintypes.DWORD
kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel32.TerminateProcess.restype = wintypes.BOOL


class OwnedProcess:
    """A retained handle, rather than a reusable PID, authorizes termination."""

    def __init__(self, pid: int, handle, creation_time: int, executable: str):
        self.pid = pid
        self.handle = handle
        self.creation_time = creation_time
        self.executable = executable
        # Keep kernel-object ownership from earlier successful inspections even
        # if a later query fails or the root exits before cleanup.
        self.descendants: list[OwnedProcess] = []

    @classmethod
    def capture(cls, pid: int, expected: dict | None = None):
        handle = kernel32.OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, False, pid
        )
        if not handle:
            return None
        try:
            created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
            if not kernel32.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user)):
                return None
            creation_time = (created.dwHighDateTime << 32) | created.dwLowDateTime
            image = ctypes.create_unicode_buffer(32768)
            length = wintypes.DWORD(len(image))
            if not kernel32.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length)):
                return None
            if expected is not None:
                # Both sides retain native FILETIME ticks, without float loss.
                if creation_time != int(expected.get("CreationTime", -1)):
                    return None
                expected_image = expected.get("ExecutablePath") or ""
                if os.path.normcase(image.value) != os.path.normcase(expected_image):
                    # An inspector can preserve a runtime-manager junction
                    # while the handle reports the executable's physical path.
                    try:
                        if not os.path.samefile(image.value, expected_image):
                            return None
                    except OSError:
                        return None
            result = cls(pid, handle, creation_time, image.value)
            handle = None
            return result
        finally:
            if handle:
                kernel32.CloseHandle(handle)

    def running(self) -> bool:
        return bool(self.handle) and kernel32.WaitForSingleObject(self.handle, 0) == WAIT_TIMEOUT

    def terminate(self) -> None:
        if self.running() and not kernel32.TerminateProcess(self.handle, 1):
            if self.running():
                raise RuntimeError(f"could not terminate the owned process handle for {self.pid}")

    def close(self) -> None:
        if self.handle:
            kernel32.CloseHandle(self.handle)
            self.handle = None


owned_processes: dict[int, OwnedProcess] = {}
unverified_fixture_pids: set[int] = set()
fixture_processes: dict[int, OwnedProcess] = {}


def remember_owned_process(pid: int, expected: dict | None = None) -> OwnedProcess | None:
    previous = owned_processes.get(pid)
    if previous is not None and previous.running():
        if expected is None or previous.creation_time == int(expected.get("CreationTime", -1)):
            return previous
        return None
    process = OwnedProcess.capture(pid, expected)
    if process is not None:
        if previous is not None:
            previous.close()
        owned_processes[pid] = process
    return process


def owned_process_running(pid: int, expected: dict | None = None) -> bool:
    process = owned_processes.get(pid)
    return process is not None and process.running() and (
        expected is None or process.creation_time == int(expected.get("CreationTime", -1))
    )


def process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    exit_code = wintypes.DWORD()
    try:
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        return exit_code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def terminate_process_tree(pid: int, timeout_seconds: float = 10, inspect_descendants: bool = True) -> None:
    owner = owned_processes.get(pid)
    if owner is None:
        if process_exists(pid):
            raise RuntimeError(f"refusing to terminate PID {pid} without a retained ownership handle")
        return
    inspection_error = None
    if inspect_descendants and owner.running():
        try:
            capture_owned_tree(owner)
        except Exception as error:  # noqa: BLE001 - cleanup must still use retained handles.
            inspection_error = error
    targets = list(dict.fromkeys([owner] + (owner.descendants if inspect_descendants else [])))
    # Each termination targets the original kernel object, including if it
    # exited between inspection and this call. Never reopen a historical PID.
    cleanup_errors = []
    for process in targets:
        try:
            process.terminate()
        except Exception as error:  # noqa: BLE001 - another owned handle still needs cleanup.
            cleanup_errors.append(str(error))
    deadline = time.monotonic() + timeout_seconds
    while any(process.running() for process in targets) and time.monotonic() < deadline:
        time.sleep(0.05)
    survivors = [process.pid for process in targets if process.running()]
    if survivors:
        cleanup_errors.append(f"owned process handles survived cleanup: {survivors}")
    if inspection_error is not None:
        suffix = f"; {'; '.join(cleanup_errors)}" if cleanup_errors else ""
        raise RuntimeError(
            f"could not inspect the owned process tree rooted at {pid}: {inspection_error}; "
            f"retained-handle cleanup attempted, uninspected descendants may remain{suffix}"
        ) from inspection_error
    if cleanup_errors:
        raise RuntimeError("; ".join(cleanup_errors))


def run_bounded_process(command: list[str], timeout_seconds: float, *, inspect_descendants: bool = True) -> subprocess.CompletedProcess:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=CREATE_NEW_PROCESS_GROUP,
    )
    owner = remember_owned_process(process.pid)
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as error:
        cleanup_error = None
        try:
            terminate_process_tree(process.pid, inspect_descendants=inspect_descendants)
        except Exception as failure:  # noqa: BLE001 - preserve cleanup failure in the timeout.
            cleanup_error = failure
        # Popen itself retains a kernel handle, including if capturing our
        # stronger identity failed. Do not release that last cleanup owner early.
        if process.poll() is None:
            try:
                process.kill()
                process.wait(timeout=2)
            except Exception as failure:  # noqa: BLE001 - retain both cleanup diagnostics.
                cleanup_error = RuntimeError(f"{cleanup_error or 'owned cleanup failed'}; Popen cleanup: {failure}")
        with contextlib.suppress(Exception):
            process.communicate(timeout=2)
        suffix = f"; cleanup could not be confirmed: {cleanup_error}" if cleanup_error else ""
        raise TimeoutError(
            f"process exceeded its {timeout_seconds:.1f}s local deadline: {command[0]}{suffix}"
        ) from (cleanup_error or error)
    finally:
        if owner is not None:
            owner.close()
            if owned_processes.get(process.pid) is owner:
                del owned_processes[process.pid]


def wait_until(predicate, timeout_seconds: float, description: str, interval: float = 0.1):
    deadline = time.monotonic() + timeout_seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception as error:  # noqa: BLE001 - preserve the latest polling diagnostic.
            last_error = error
        time.sleep(interval)
    suffix = f"; last error: {last_error}" if last_error else ""
    raise TimeoutError(f"timed out waiting for {description}{suffix}")


def hash_tree(root: Path) -> dict[str, str]:
    result = {}
    for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
        relative = path.relative_to(root).as_posix()
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        result[relative] = digest.hexdigest()
    return result


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def process_tree_ids(root_pid: int) -> list[int]:
    """Read only topology; these PIDs never authorize termination by themselves."""
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(kernel32.GetLastError())
    try:
        entry = ProcessEntry32()
        entry.dwSize = ctypes.sizeof(entry)
        parents: dict[int, list[int]] = {}
        present = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while present:
            parents.setdefault(entry.th32ParentProcessID, []).append(entry.th32ProcessID)
            present = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
        error = kernel32.GetLastError()
        if error != ERROR_NO_MORE_FILES:
            raise ctypes.WinError(error)
    finally:
        kernel32.CloseHandle(snapshot)
    pending, seen, result = [root_pid], set(), []
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        result.append(pid)
        pending.extend(parents.get(pid, []))
    return result


def process_record(pid: int) -> dict | None:
    """Use upstream native inspection, retaining exact Win32 identity ticks.

    psutil handles Windows command-line/parent inspection without WMI. Its
    PID-reuse checks supplement, rather than replace, the retained kernel
    handles used to authorize cleanup. Do not round FILETIME through a float.
    """
    identity = None
    try:
        process = psutil.Process(pid)
        process.create_time()  # Freeze psutil's original process identity.
        identity = OwnedProcess.capture(pid)
        if identity is None:
            if process.is_running():
                raise RuntimeError(f"could not inspect the process identity for {pid}")
            return None
        record = {
            "ProcessId": pid,
            "ParentProcessId": process.ppid(),
            "Name": process.name(),
            "ExecutablePath": identity.executable,
            "CommandLine": subprocess.list2cmdline(process.cmdline()),
            "CreationTime": identity.creation_time,
        }
        if not process.is_running() or not identity.running():
            return None
        return record
    except psutil.NoSuchProcess:
        return None
    finally:
        if identity is not None:
            identity.close()


def process_tree(root_pid: int) -> list[dict]:
    return [record for pid in process_tree_ids(root_pid)
            if (record := process_record(pid)) is not None]


def acceptance_process_inventory(executable: Path, identifier: str) -> list[dict]:
    """Wrapper fallback: inspect only matching app/fixture candidates.

    Returned records are evidence, never termination authority. The wrapper
    reopens and retains handles, then compares exact times and executable paths.
    """
    expected = os.path.normcase(str(executable.resolve()))
    state_root = Path(os.environ["LOCALAPPDATA"]) / identifier / "plugin-state" / PLUGIN_ID
    roots = set()
    for process in psutil.process_iter(["pid", "name"]):
        name = (process.info["name"] or "").lower()
        if name not in (executable.name.lower(), "node.exe", "node"):
            continue
        record = process_record(process.pid)
        if record is None:
            continue
        if (os.path.normcase(record["ExecutablePath"]) == expected
                or fixture_command_matches(record["CommandLine"], state_root)):
            roots.add(process.pid)
    records = {}
    for root in roots:
        for record in process_tree(root):
            records[record["ProcessId"]] = record
    return list(records.values())


def capture_owned_tree(root: OwnedProcess, records: list[dict] | None = None) -> list[OwnedProcess]:
    if not root.running():
        return []
    records = process_tree(root.pid) if records is None else records
    root_record = next((item for item in records if int(item["ProcessId"]) == root.pid), None)
    if root_record is None or int(root_record.get("CreationTime", -1)) != root.creation_time:
        return []
    pending = {root.pid: root}
    accepted = []
    while pending:
        parent_pid, parent = pending.popitem()
        for record in records:
            pid = int(record["ProcessId"])
            if int(record["ParentProcessId"]) != parent_pid or pid == root.pid:
                continue
            if int(record.get("CreationTime", -1)) < parent.creation_time:
                continue
            child = remember_owned_process(pid, record)
            if child is not None and child not in accepted:
                accepted.append(child)
                if child not in root.descendants:
                    root.descendants.append(child)
                pending[pid] = child
    return accepted


class Reporter:
    def __init__(self, progress_path: Path | None = None):
        self.tests: list[dict] = []
        self.progress_path = progress_path
        self.capture_failure = lambda: None

    @contextlib.contextmanager
    def step(self, name: str, max_ms: int = 120_000):
        started = time.monotonic()
        details = ""
        status = "passed"
        print(f"START {name}", flush=True)
        try:
            yield
        except Exception as error:  # noqa: BLE001 - report and re-raise the exact acceptance failure.
            status = "failed"
            details = f"{type(error).__name__}: {error}"
            with contextlib.suppress(Exception):
                self.capture_failure()
            raise
        finally:
            self.tests.append(
                {
                    "name": name,
                    "suite": "plugin-host-acceptance / native-windows-x64",
                    "status": status,
                    "durationMs": round((time.monotonic() - started) * 1000, 3),
                    "details": details,
                    "maxMs": max_ms,
                }
            )
            print(f"{status.upper()} {name} ({self.tests[-1]['durationMs']:.0f} ms)", flush=True)
            if self.progress_path is not None:
                write_json(self.progress_path, {"tests": self.tests})

    def document_pending(
        self, name: str, details: str, suite: str = "plugin-host-acceptance / pending-platforms"
    ):
        self.tests.append(
            {
                "name": name,
                "suite": suite,
                "status": "skipped",
                "durationMs": 0,
                "details": details,
                "maxMs": 1,
            }
        )


def safe_remove_owned_directory(path: Path, expected_parent: Path, expected_name: str) -> None:
    # MSIX redirects an existing AppData leaf to LocalCache; resolving its
    # parent separately gives a different physical root. Prove the exact
    # caller-owned logical path, then let Windows perform its redirection.
    resolved = Path(os.path.abspath(path))
    if resolved.name != expected_name or resolved.parent != Path(os.path.abspath(expected_parent)):
        raise RuntimeError(f"refusing to remove non-acceptance directory: {resolved}")
    if resolved.is_symlink() or resolved.is_junction():
        raise RuntimeError(f"refusing to remove a linked acceptance directory: {resolved}")
    deadline = time.monotonic() + 5
    while resolved.exists():
        try:
            shutil.rmtree(resolved)
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def cdp_ready(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=0.5) as response:
            return response.status == 200
    except Exception:
        return False


def invoke(page: Page, command: str, arguments: dict | None = None):
    return page.evaluate(
        """async ([command, args]) => {
          if (!window.__TAURI_INTERNALS__?.invoke) throw new Error("Tauri IPC is unavailable");
          let deadline;
          try {
            return await Promise.race([
              window.__TAURI_INTERNALS__.invoke(command, args ?? {}),
              new Promise((_, reject) => {
                deadline = setTimeout(() => reject(new Error(`IPC deadline exceeded: ${command}`)), 10000);
              }),
            ]);
          } finally {
            clearTimeout(deadline);
          }
        }""",
        [command, arguments or {}],
    )


class AppSession:
    def __init__(
        self,
        playwright: Playwright,
        executable: Path,
        workspace: Path,
        webview_data: Path,
        log_root: Path,
        sequence: int,
    ):
        self.playwright = playwright
        self.executable = executable
        self.workspace = workspace
        self.webview_data = webview_data
        self.log_root = log_root
        self.sequence = sequence
        self.process: subprocess.Popen | None = None
        self.browser = None
        self.page: Page | None = None
        self.stdout_file = None
        self.stderr_file = None
        self.initial_tree: list[dict] = []
        self.root_owner: OwnedProcess | None = None
        self.owned_tree: list[OwnedProcess] = []

    def start(self) -> Page:
        port = free_port()
        environment = os.environ.copy()
        environment["WEBVIEW2_USER_DATA_FOLDER"] = str(self.webview_data)
        environment["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = (
            f"--remote-debugging-port={port} --remote-allow-origins=http://127.0.0.1:{port}"
        )
        self.log_root.mkdir(parents=True, exist_ok=True)
        self.stdout_file = (self.log_root / f"app-{self.sequence}.stdout.log").open("w", encoding="utf-8")
        self.stderr_file = (self.log_root / f"app-{self.sequence}.stderr.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(self.executable), str(self.workspace)],
            cwd=self.executable.parent,
            env=environment,
            stdout=self.stdout_file,
            stderr=self.stderr_file,
            creationflags=CREATE_NEW_PROCESS_GROUP,
        )
        self.root_owner = remember_owned_process(self.process.pid)
        if self.root_owner is None or Path(self.root_owner.executable).resolve() != self.executable.resolve():
            raise RuntimeError("could not retain the isolated application's process identity")
        try:
            wait_until(lambda: cdp_ready(port), 30, "the isolated WebView2 CDP endpoint")
            self.browser = self.playwright.chromium.connect_over_cdp(
                f"http://127.0.0.1:{port}", timeout=15_000
            )
            self.page = wait_until(self._tauri_page, 30, "the real Tauri product page")
            self.page.wait_for_load_state("domcontentloaded", timeout=15_000)
            self.page.wait_for_function("() => Boolean(window.__TAURI_INTERNALS__?.invoke)", timeout=15_000)
            runtime_data = Path(invoke(self.page, "plugin:path|resolve_directory", {"directory": 15}))
            expected_data = Path(os.environ["LOCALAPPDATA"]) / ACCEPTANCE_IDENTIFIER
            if runtime_data.resolve() != expected_data.resolve():
                raise RuntimeError(f"the executable has an unexpected application data root: {runtime_data}")
            write_json(self.log_root / f"app-{self.sequence}.identity.json", {
                "appLocalData": str(runtime_data),
                "expectedAppLocalData": str(expected_data),
            })
            self.initial_tree = process_tree(self.process.pid)
            self.owned_tree = capture_owned_tree(self.root_owner, self.initial_tree)
            return self.page
        except Exception:
            with contextlib.suppress(Exception):
                terminate_process_tree(self.process.pid)
            raise

    def _tauri_page(self):
        if self.browser is None:
            return None
        for context in self.browser.contexts:
            for candidate in context.pages:
                try:
                    if candidate.evaluate("() => Boolean(window.__TAURI_INTERNALS__?.invoke)"):
                        return candidate
                except Exception:
                    continue
        return None

    def stop(self, require_graceful: bool = True) -> dict:
        if self.process is None:
            return {"forced": False, "tree": []}
        current_tree = process_tree(self.process.pid) if self.root_owner is not None and self.root_owner.running() else []
        if self.root_owner is not None:
            self.owned_tree = list(dict.fromkeys(self.owned_tree + capture_owned_tree(self.root_owner, current_tree)))
        tree = list({
            int(item["ProcessId"]): item
            for item in self.initial_tree + current_tree
        }.values())
        forced = False
        if self.root_owner is not None and self.root_owner.running() and self.page is not None:
            with contextlib.suppress(Exception):
                invoke(self.page, "plugin:process|exit", {"code": 0})
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            forced = True
            terminate_process_tree(self.process.pid)
        if self.browser is not None:
            with contextlib.suppress(Exception):
                self.browser.close()
        for stream in (self.stdout_file, self.stderr_file):
            if stream is not None:
                stream.close()
        deadline = time.monotonic() + 10
        survivors = [item for item in self.owned_tree if item.running()]
        while survivors and time.monotonic() < deadline:
            time.sleep(0.05)
            survivors = [item for item in survivors if item.running()]
        if survivors:
            for item in survivors:
                with contextlib.suppress(Exception):
                    terminate_process_tree(item.pid)
            raise RuntimeError(f"owned application process tree left survivors: {[item.pid for item in survivors]}")
        if forced and require_graceful:
            raise RuntimeError("the isolated Lithe instance required forced termination")
        if require_graceful and self.process.returncode != 0:
            raise RuntimeError(f"the isolated Lithe instance exited with code {self.process.returncode}")
        return {"forced": forced, "tree": tree}


user32 = ctypes.windll.user32
EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [EnumWindowsProc, wintypes.LPARAM]
user32.EnumChildWindows.argtypes = [wintypes.HWND, EnumWindowsProc, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetWindow.restype = wintypes.HWND
user32.IsWindow.argtypes = [wintypes.HWND]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowEnabled.argtypes = [wintypes.HWND]
user32.GetDlgCtrlID.argtypes = [wintypes.HWND]
user32.GetDlgCtrlID.restype = ctypes.c_int
user32.GetParent.argtypes = [wintypes.HWND]
user32.GetParent.restype = wintypes.HWND


user32.SendMessageTimeoutW.argtypes = [
    wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPCWSTR,
    wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t),
]
user32.SendMessageTimeoutW.restype = wintypes.LPARAM
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostMessageW.restype = wintypes.BOOL


def window_pid(hwnd: int) -> int:
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def window_class(hwnd: int) -> str:
    buffer = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buffer, len(buffer))
    return buffer.value


def find_file_dialog(app_pid: int):
    matches = []

    @EnumWindowsProc
    def callback(hwnd, _):
        if user32.IsWindowVisible(hwnd) and window_class(hwnd) == "#32770":
            owner = user32.GetWindow(hwnd, 4)  # GW_OWNER
            if window_pid(hwnd) == app_pid or (owner and window_pid(owner) == app_pid):
                matches.append(hwnd)
        return True

    user32.EnumWindows(callback, 0)
    return matches[-1] if matches else None


def child_windows(hwnd: int) -> list[int]:
    children = []

    @EnumWindowsProc
    def callback(child, _):
        children.append(child)
        return True

    user32.EnumChildWindows(hwnd, callback, 0)
    return children


def select_native_file(app_pid: int, file_path: Path) -> None:
    dialog = wait_until(lambda: find_file_dialog(app_pid), 10, "the native package picker")
    edits = [
        child
        for child in child_windows(dialog)
        if window_class(child) == "Edit" and user32.IsWindowVisible(child) and user32.IsWindowEnabled(child)
    ]
    if not edits:
        classes = sorted({window_class(child) for child in child_windows(dialog)})
        raise RuntimeError(f"native package picker exposed no editable filename field; classes={classes}")
    filename_edits = [
        edit for edit in edits if user32.GetDlgCtrlID(user32.GetParent(edit)) == 1148
    ]
    if not filename_edits:
        controls = [{"class": window_class(edit), "id": user32.GetDlgCtrlID(edit),
                     "parentId": user32.GetDlgCtrlID(user32.GetParent(edit))} for edit in edits]
        raise RuntimeError(f"the native filename combo was not found: {controls}")
    edit = filename_edits[0]
    WM_SETTEXT = 0x000C
    message_result = ctypes.c_size_t()
    kernel32.SetLastError(0)
    if not user32.SendMessageTimeoutW(
        edit, WM_SETTEXT, 0, str(file_path), 0x0002, 5000, ctypes.byref(message_result)
    ):
        error_code = kernel32.GetLastError()
        controls = [
            {"class": window_class(child), "id": user32.GetDlgCtrlID(child)}
            for child in child_windows(dialog)
        ]
        raise RuntimeError(
            f"native filename input failed within 5 seconds (Win32 {error_code}); controls={controls}"
        )
    if not user32.PostMessageW(dialog, 0x0111, 1, 0):  # WM_COMMAND / IDOK
        raise RuntimeError("the native package picker rejected its Open command")
    wait_until(lambda: not user32.IsWindow(dialog), 10, "the native package picker to close")


def finish_onboarding(page: Page) -> None:
    done = page.get_by_role("button", name="Done", exact=True)
    if done.count() > 0 and done.first.is_visible():
        done.first.click()
        done.first.wait_for(state="detached", timeout=15_000)


def open_plugin_settings(page: Page) -> None:
    category = page.locator("[data-settings-category='declarative-plugins']")
    if category.count() == 0 or not category.first.is_visible():
        page.keyboard.press("Control+Comma")
    category.first.wait_for(state="visible", timeout=15_000)
    category.first.click()
    page.locator("[data-settings-content='declarative-plugins']").wait_for(
        state="visible", timeout=15_000
    )


def close_settings(page: Page) -> None:
    content = page.locator("[data-settings-content='declarative-plugins']")
    if content.count() and content.first.is_visible():
        page.get_by_role("button", name="Close", exact=True).last.click()
        content.first.wait_for(state="hidden", timeout=15_000)


def plugin_row(page: Page):
    # List children are state groups; identify the actual installed package,
    # including when a bundled package has the same ID or display name.
    return page.locator(
        "[data-testid='declarative-plugin-list'] "
        f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']"
    )


def select_plugin_details(page: Page, timeout_ms: int = 30_000):
    row = plugin_row(page)
    expect(row).to_have_count(1, timeout=timeout_ms)
    row.get_by_role("button").click(timeout=timeout_ms)
    # Management actions belong to the selected detail panel, outside the
    # grouped list. Scope the region to settings so other surfaces cannot win.
    details = page.locator("[data-settings-content='declarative-plugins']").get_by_role(
        "region", name=DISPLAY_NAME, exact=True
    )
    expect(details).to_be_visible(timeout=timeout_ms)
    return details


def set_plugin_enabled(page: Page, enabled: bool, timeout_ms: int = 30_000) -> None:
    details = select_plugin_details(page, timeout_ms)
    details.get_by_role("button", name="Enable" if enabled else "Disable", exact=True).click(
        timeout=timeout_ms
    )
    # Native catalog publication can precede React's detail refresh. Do not
    # attempt the inverse action until the selected panel reflects completion.
    expect(details.get_by_role("button", name="Disable" if enabled else "Enable", exact=True)).to_be_visible(
        timeout=timeout_ms
    )


def wait_catalog(page: Page, version: str | None = None, enabled: bool | None = None):
    def predicate():
        catalog = invoke(page, "declarative_plugins_state")
        match = next((item for item in catalog if item.get("pluginId") == PLUGIN_ID), None)
        if not match:
            return None
        if version is not None and match.get("version") != version:
            return None
        if enabled is not None and match.get("enabled") is not enabled:
            return None
        return match

    return wait_until(predicate, 30, f"catalog state version={version} enabled={enabled}")


def import_review(page: Page, app_pid: int, package: Path):
    open_plugin_settings(page)
    page.get_by_role("button", name="Import package…", exact=True).click()
    select_native_file(app_pid, package)
    review = page.locator("[data-settings-content='declarative-plugins'] [role='dialog']")
    review.wait_for(state="visible", timeout=30_000)
    return review


def confirm_review(page: Page, review) -> None:
    review.get_by_role("button", name="Install", exact=True).click()
    review.wait_for(state="detached", timeout=45_000)


def cancel_review(page: Page, review) -> None:
    review.get_by_role("button", name="Cancel", exact=True).click()
    review.wait_for(state="detached", timeout=15_000)


def open_fixture_file(page: Page, file_name: str = "acceptance.litheaccept") -> None:
    close_settings(page)
    root = page.locator("[role='treeitem'][data-root='true']")
    root.wait_for(state="visible", timeout=30_000)
    if root.get_attribute("aria-expanded") == "false":
        root.locator("[data-sidebar-tree-disclosure]").click()
    expect(root).to_have_attribute("aria-expanded", "true", timeout=15_000)
    existing = page.get_by_role("tab", name=re.compile(rf"^{re.escape(file_name)}"))
    if existing.count() > 0:
        # A restored editor can still be attaching its language server. Select
        # it without introducing an unrelated close/reopen transaction into
        # the application-restart scenario under test.
        existing.first.click()
        expect(existing.first).to_have_attribute("aria-selected", "true", timeout=15_000)
        return
    entry = page.get_by_text(file_name, exact=True)
    entry.first.wait_for(state="visible", timeout=30_000)
    entry.first.dblclick()
    expect(page.get_by_role("tab", name=re.compile(rf"^{re.escape(file_name)}")).first).to_have_attribute(
        "aria-selected", "true", timeout=15_000)


def evidence_files(state_root: Path, prefix: str) -> list[Path]:
    if not state_root.exists():
        return []
    return sorted(state_root.rglob(f"{prefix}-*.json"))


def fixture_command_matches(command: str, state_root: Path) -> bool:
    # Use Windows' own quoting rules; substring checks would also authorize
    # an unrelated file whose name merely contains the fixture/state path.
    shell32 = ctypes.windll.shell32
    shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    count = ctypes.c_int()
    arguments = shell32.CommandLineToArgvW(command, ctypes.byref(count))
    if not arguments:
        return False
    try:
        values = [arguments[index] for index in range(count.value)]
        if not any(Path(value).name.lower() == "fake-lsp-server.mjs" for value in values[1:]):
            return False
        index = values.index("--state-dir")
        candidate = Path(values[index + 1]).resolve()
        root = state_root.resolve()
        return candidate == root or root in candidate.parents
    except (ValueError, IndexError, OSError):
        return False
    finally:
        kernel32.LocalFree(arguments)


def live_fixture_pids(state_root: Path) -> set[int]:
    pids = set()
    for evidence in evidence_files(state_root, "server-active") + evidence_files(
        state_root, "child-active"
    ):
        with contextlib.suppress(Exception):
            pid = int(json.loads(evidence.read_text(encoding="utf-8"))["pid"])
            known_fixture = fixture_processes.get(pid)
            if known_fixture is not None and known_fixture.running():
                pids.add(pid)
                continue
            if not process_exists(pid):
                continue
            record = next((item for item in process_tree(pid) if int(item["ProcessId"]) == pid), None)
            if record is None or not fixture_command_matches(record.get("CommandLine") or "", state_root):
                unverified_fixture_pids.add(pid)
                continue
            owner = remember_owned_process(pid, record)
            if owner is not None and owner.running():
                fixture_processes[pid] = owner
                pids.add(pid)
            else:
                unverified_fixture_pids.add(pid)
    return pids


def wait_for_server_count(state_root: Path, count: int) -> set[int]:
    return wait_until(
        lambda: (pids if len(pids := live_fixture_pids(state_root)) >= count else None),
        45,
        f"{count} controlled language-server process tree(s)",
    )


def wait_pids_dead(pids: set[int], description: str) -> None:
    wait_until(
        lambda: all(not fixture_processes[pid].running() for pid in pids if pid in fixture_processes),
        30,
        description,
    )


def installation_record(app_local_data: Path) -> dict:
    path = app_local_data / "plugins" / PLUGIN_ID / "installation.json"
    return json.loads(path.read_text(encoding="utf-8"))


def active_fixture_marker(app_local_data: Path, version: str) -> str:
    return (
        app_local_data / "plugins" / PLUGIN_ID / version / "fixture-version.txt"
    ).read_text(encoding="utf-8").strip()


def newest_snapshot(app_local_data: Path) -> Path:
    root = app_local_data / "plugin-temp"
    snapshots = [path for path in root.glob("lithe-plugin-disk-*") if path.is_dir()]
    if not snapshots:
        raise RuntimeError("prepared install did not create a private snapshot")
    return max(snapshots, key=lambda path: path.stat().st_mtime_ns)


def capture_session_failure(session: AppSession | None, artifact_root: Path) -> None:
    if session is None or session.page is None:
        return
    with contextlib.suppress(Exception):
        (artifact_root / "screenshots").mkdir(parents=True, exist_ok=True)
        session.page.screenshot(path=str(artifact_root / "screenshots" / "failure.png"), timeout=5000)
    with contextlib.suppress(Exception):
        write_json(artifact_root / "page-failure.json", {
            "url": session.page.url,
            "text": session.page.locator("body").inner_text(timeout=5000),
        })


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--run-image", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--app-local-data", required=True, type=Path)
    parser.add_argument("--app-roaming-data", required=True, type=Path)
    parser.add_argument("--webview-data", required=True, type=Path)
    parser.add_argument("--package-v1-a", required=True, type=Path)
    parser.add_argument("--package-v1-b", required=True, type=Path)
    parser.add_argument("--package-v2", required=True, type=Path)
    parser.add_argument("--workspace-one", required=True, type=Path)
    parser.add_argument("--workspace-two", required=True, type=Path)
    from marketplace_acceptance import add_arguments, validate_arguments
    add_arguments(parser)
    args = parser.parse_args()
    validate_arguments(parser, args)

    artifact_root = args.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=True)
    reporter = Reporter(artifact_root / "progress.json")
    reporter.document_pending(
        "windows-arm64 native acceptance",
        "No Windows arm64 native execution environment is available; x64 compilation or emulation is not acceptance evidence.",
    )
    reporter.document_pending(
        "macOS native acceptance",
        "This driver is intentionally Windows/WebView2-only; macOS requires its own product acceptance lane.",
    )
    if not args.marketplace:
        reporter.document_pending(
            "roadmap M2 marketplace package acceptance",
            "The optional real HTTPS marketplace lane was not requested; use --marketplace. Native package transactions additionally need the controlled fixture and an already-trusted TLS endpoint.",
        )
    reporter.document_pending(
        "roadmap M4 build-system provider acceptance",
        "The Windows host does not yet advertise buildSystems/buildProviders; this lane must remain pending instead of treating API rejection as a product failure.",
    )
    immutable_before = hash_tree(args.run_image.resolve())
    write_json(artifact_root / "resource-hashes-before.json", immutable_before)
    session: AppSession | None = None
    reporter.capture_failure = lambda: capture_session_failure(session, artifact_root)
    all_owned_fixture_pids: set[int] = set()
    cleanup_evidence = []
    failure = None

    local_parent = Path(os.environ["LOCALAPPDATA"])
    roaming_parent = Path(os.environ["APPDATA"])
    try:
        with reporter.step("isolated application identity and writable roots"):
            assert args.app_local_data.resolve() == (local_parent / ACCEPTANCE_IDENTIFIER).resolve()
            assert args.app_roaming_data.resolve() == (roaming_parent / ACCEPTANCE_IDENTIFIER).resolve()
            safe_remove_owned_directory(args.app_local_data, local_parent, ACCEPTANCE_IDENTIFIER)
            safe_remove_owned_directory(args.app_roaming_data, roaming_parent, ACCEPTANCE_IDENTIFIER)
            args.app_roaming_data.mkdir(parents=True)
            write_json(args.app_roaming_data / "settings.json", {"displayLanguage": "en-US"})
            safe_remove_owned_directory(
                args.webview_data, artifact_root.parent / "runtime", "webview2"
            )
            args.webview_data.mkdir(parents=True)
            assert "host-acceptance" in args.executable.name.lower()

        with sync_playwright() as playwright:
            with reporter.step("cancelled review discards its private snapshot"):
                session = AppSession(
                    playwright,
                    args.executable.resolve(),
                    args.workspace_one.resolve(),
                    args.webview_data.resolve(),
                    artifact_root / "logs",
                    1,
                )
                page = session.start()
                finish_onboarding(page)
                review = import_review(page, session.process.pid, args.package_v1_a.resolve())
                assert "Unverified publisher" in review.inner_text()
                cancel_review(page, review)
                wait_until(
                    lambda: not list((args.app_local_data / "plugin-temp").glob("lithe-plugin-disk-*")),
                    10,
                    "cancelled review snapshot cleanup",
                )

            with reporter.step("review exposes permissions and the complete program declaration"):
                review = import_review(page, session.process.pid, args.package_v1_a.resolve())
                text = review.inner_text()
                assert "languageServer.launch" in text
                disclosure = review.get_by_role("button", name=re.compile(r"Program declaration \(\d+\)"))
                disclosure.click()
                declaration = review.locator("pre").inner_text()
                assert '"kind": "runtimeLanguageServer"' in declaration
                assert '"tool": "node"' in declaration
                assert '"entry": "server/fake-lsp-server.mjs"' in declaration
                (artifact_root / "screenshots").mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(artifact_root / "screenshots" / "install-review.png"))
                confirm_review(page, review)
                installed = wait_catalog(page, "1.0.0", True)
                write_json(artifact_root / "installed-catalog.json", installed)
                assert installed["status"] == "accepted", installed.get("rejection")
                record = installation_record(args.app_local_data)
                assert record["schemaVersion"] == 2
                assert record["origin"] == "community"
                assert [json.loads(program) for program in record["disk"]["approvedPrograms"]] == json.loads(declaration)
                with args.package_v1_a.open("rb") as archive:
                    assert record["disk"]["archiveSha256"] == hashlib.file_digest(archive, "sha256").hexdigest()

            state_root = args.app_local_data / "plugin-state" / PLUGIN_ID
            with reporter.step("installed plugin survives application restart"):
                cleanup_evidence.append(session.stop(require_graceful=True))
                session = None
                session = AppSession(
                    playwright,
                    args.executable.resolve(),
                    args.workspace_one.resolve(),
                    args.webview_data.resolve(),
                    artifact_root / "logs",
                    2,
                )
                page = session.start()
                finish_onboarding(page)
                open_plugin_settings(page)
                wait_catalog(page, "1.0.0", True)
                # Native catalog queries can finish before React publishes its list.
                expect(plugin_row(page)).to_have_count(1, timeout=30_000)

            lsp_started = False
            try:
                with reporter.step("opening a declared language starts its server and child"):
                    open_fixture_file(page)
                    live = wait_for_server_count(state_root, 2)
                    all_owned_fixture_pids.update(live)
                    lsp_started = True
            except Exception as error:
                # Preserve the product failure while exercising independent install transactions.
                failure = error
                diagnostic = {}
                for command in ("declarative_plugins_language_owner", "declarative_plugins_language_launch"):
                    try:
                        arguments = {"filePath": str(args.workspace_one.resolve() / "acceptance.litheaccept")}
                        if command.endswith("_launch"):
                            arguments["workspacePath"] = str(args.workspace_one.resolve())
                        diagnostic[command] = invoke(page, command, arguments)
                    except Exception as diagnostic_error:
                        diagnostic[command] = {"error": str(diagnostic_error)}
                write_json(artifact_root / "language-launch-diagnostic.json", diagnostic)

            if lsp_started:
                with reporter.step("application exit revokes the language-server process tree"):
                    first_live = live_fixture_pids(state_root)
                    cleanup_evidence.append(session.stop(require_graceful=True))
                    session = None
                    wait_pids_dead(first_live, "language-server and child cleanup on application exit")
                    session = AppSession(
                        playwright, args.executable.resolve(), args.workspace_one.resolve(),
                        args.webview_data.resolve(), artifact_root / "logs", 3,
                    )
                    page = session.start()
                    finish_onboarding(page)
                    open_fixture_file(page)
                    all_owned_fixture_pids.update(wait_for_server_count(state_root, 2))
                with reporter.step("two product windows revoke both owned process trees on disable"):
                    # The event wait pumps Playwright's protocol dispatcher;
                    # polling its cached pages list cannot receive a new target.
                    with page.context.expect_page(timeout=30_000) as new_page:
                        second_label = invoke(page, "create_app_window", {"request": {
                            "type": "directory", "path": str(args.workspace_two.resolve()),
                        }})
                    second = new_page.value
                    second.wait_for_load_state("domcontentloaded", timeout=15_000)
                    second.wait_for_function("() => Boolean(window.__TAURI_INTERNALS__?.invoke)", timeout=15_000)
                    write_json(artifact_root / "second-product-window.json", {
                        "label": second_label, "url": second.url,
                        "workspace": str(args.workspace_two.resolve()),
                    })
                    finish_onboarding(second)
                    open_fixture_file(second)
                    live = wait_for_server_count(state_root, 4)
                    all_owned_fixture_pids.update(live)
                    open_plugin_settings(page)
                    set_plugin_enabled(page, False)
                    wait_catalog(page, "1.0.0", False)
                    wait_pids_dead(live, "both windows' language-server process trees after disable")
                    set_plugin_enabled(page, True)
                    wait_catalog(page, "1.0.0", True)
            else:
                reporter.document_pending(
                    "application exit revokes the language-server process tree",
                    "The declared language did not activate its server; no process cleanup success is claimed.",
                    "plugin-host-acceptance / native-windows-x64",
                )
                reporter.document_pending(
                    "two product windows revoke both owned process trees on disable",
                    "The declared language did not activate its server; process revocation was not exercised.",
                    "plugin-host-acceptance / native-windows-x64",
                )

            with reporter.step("approval-bound bytes reject post-review tampering"):
                review = import_review(page, session.process.pid, args.package_v2.resolve())
                snapshot = newest_snapshot(args.app_local_data)
                server = snapshot / "server" / "fake-lsp-server.mjs"
                server.write_text(server.read_text(encoding="utf-8") + "\n// tampered after review\n", encoding="utf-8")
                review.get_by_role("button", name="Install", exact=True).click()
                review.wait_for(state="detached", timeout=45_000)
                alert = page.locator("[data-settings-content='declarative-plugins'] [role='alert']")
                alert.wait_for(state="visible", timeout=15_000)
                assert re.search(r"(changed|digest|review|bytes)", alert.inner_text(), re.IGNORECASE)
                wait_catalog(page, "1.0.0", True)
                assert active_fixture_marker(args.app_local_data, "1.0.0") == "1.0.0-a"
                wait_until(
                    lambda: not list((args.app_local_data / "plugin-temp").glob("lithe-plugin-disk-*")),
                    10,
                    "rejected tampered snapshot cleanup",
                )

            with reporter.step("same-version replacement, update, and rollback preserve provenance"):
                review = import_review(page, session.process.pid, args.package_v1_b.resolve())
                confirm_review(page, review)
                wait_catalog(page, "1.0.0", True)
                assert active_fixture_marker(args.app_local_data, "1.0.0") == "1.0.0-b"
                record = installation_record(args.app_local_data)
                assert record["version"] == "1.0.0"
                with args.package_v1_b.open("rb") as archive:
                    replacement_digest = hashlib.file_digest(archive, "sha256").hexdigest()
                assert record["disk"]["archiveSha256"] == replacement_digest

                review = import_review(page, session.process.pid, args.package_v2.resolve())
                confirm_review(page, review)
                wait_catalog(page, "1.1.0", True)
                record = installation_record(args.app_local_data)
                assert record["version"] == "1.1.0"
                assert record["previousVersion"] == "1.0.0"
                assert record["previousDisk"]["archiveSha256"] == replacement_digest
                assert active_fixture_marker(args.app_local_data, "1.1.0") == "1.1.0"

                select_plugin_details(page).get_by_role("button", name="Roll back…", exact=True).click()
                wait_catalog(page, "1.0.0", True)
                assert active_fixture_marker(args.app_local_data, "1.0.0") == "1.0.0-b"
                assert installation_record(args.app_local_data)["disk"]["archiveSha256"] == replacement_digest

            with reporter.step("uninstall removes package and state"):
                live = set()
                if lsp_started:
                    # Exercise uninstall with a genuinely new document after
                    # rollback, independently of restored-editor reactivation.
                    open_fixture_file(page, "uninstall.litheaccept")
                    live = wait_for_server_count(state_root, 2)
                    all_owned_fixture_pids.update(live)
                open_plugin_settings(page)
                select_plugin_details(page).get_by_role("button", name="Uninstall", exact=True).click()
                expect(plugin_row(page)).to_have_count(0, timeout=45_000)
                if live:
                    with reporter.step("uninstall revokes the language-server process tree"):
                        wait_pids_dead(live, "language-server process cleanup on uninstall")
                else:
                    reporter.document_pending(
                        "uninstall revokes the language-server process tree",
                        "The declared language did not activate its server; no process cleanup success is claimed.",
                        "plugin-host-acceptance / native-windows-x64",
                    )
                assert not (args.app_local_data / "plugins" / PLUGIN_ID).exists()
                assert not (args.app_local_data / "plugin-state" / PLUGIN_ID).exists()

            if args.marketplace:
                from marketplace_acceptance import MarketplaceAcceptance

                def restart_marketplace():
                    nonlocal session
                    cleanup_evidence.append(session.stop(require_graceful=True))
                    session = None
                    wait_pids_dead(all_owned_fixture_pids, "fixture processes before marketplace restart")
                    sequence = len(cleanup_evidence) + 1
                    session = AppSession(
                        playwright, args.executable.resolve(), args.workspace_one.resolve(),
                        args.webview_data.resolve(), artifact_root / "logs", sequence,
                    )
                    current = session.start()
                    finish_onboarding(current)
                    return current

                # The disk lane deliberately opened two workspaces. Start the
                # marketplace with one window so restoring an old second editor
                # cannot introduce an extra language-server owner into its cases.
                with reporter.step("marketplace isolated native session"):
                    page = restart_marketplace()
                MarketplaceAcceptance(
                    sys.modules[__name__], args, reporter, page,
                    restart_marketplace, all_owned_fixture_pids,
                ).run()

            with reporter.step("owned application and helper processes cleanly terminate"):
                cleanup_evidence.append(session.stop(require_graceful=True))
                session = None
                wait_pids_dead(all_owned_fixture_pids, "all recorded fixture processes")
                write_json(artifact_root / "process-cleanup.json", cleanup_evidence)

    except Exception as error:  # noqa: BLE001 - final cleanup and report must always run.
        failure = failure or error
    finally:
        cleanup_errors = []
        if session is not None:
            try:
                cleanup_evidence.append(session.stop(require_graceful=False))
            except Exception as error:
                cleanup_errors.append(str(error))
        owned_pids = all_owned_fixture_pids | live_fixture_pids(
            args.app_local_data / "plugin-state" / PLUGIN_ID
        )
        for pid in owned_pids:
            try:
                if owned_process_running(pid):
                    terminate_process_tree(pid)
            except Exception as error:
                cleanup_errors.append(str(error))
        write_json(artifact_root / "process-ownership-skipped.json", {
            "unverifiedFixturePids": sorted(unverified_fixture_pids),
            "action": "No termination authorized without a retained matching process handle.",
        })
        for process in owned_processes.values():
            process.close()
        owned_processes.clear()
        fixture_processes.clear()
        try:
            if args.app_local_data.exists():
                evidence_copy = artifact_root / "isolated-app-data"
                if evidence_copy.exists():
                    shutil.rmtree(evidence_copy)
                evidence_copy.mkdir(parents=True)
                for name in ("logs", "plugins", "plugin-state", "plugin-temp", "settings.json"):
                    source = args.app_local_data / name
                    if source.is_dir():
                        shutil.copytree(source, evidence_copy / name)
                    elif source.is_file():
                        shutil.copy2(source, evidence_copy / name)
        except Exception as error:
            cleanup_errors.append(f"Could not preserve isolated app-data evidence: {error}")
        for path, parent in (
            (args.app_local_data, local_parent),
            (args.app_roaming_data, roaming_parent),
        ):
            try:
                safe_remove_owned_directory(path, parent, ACCEPTANCE_IDENTIFIER)
            except Exception as error:
                cleanup_errors.append(str(error))
        try:
            safe_remove_owned_directory(
                args.webview_data, artifact_root.parent / "runtime", "webview2"
            )
        except Exception as error:
            cleanup_errors.append(str(error))
        write_json(artifact_root / "process-cleanup.json", cleanup_evidence)
        if cleanup_errors:
            reporter.tests.append(
                {
                    "name": "failure-path cleanup",
                    "suite": "plugin-host-acceptance / native-windows-x64",
                    "status": "failed",
                    "durationMs": 0,
                    "details": "\n".join(cleanup_errors),
                    "maxMs": 30000,
                }
            )
            failure = failure or RuntimeError("; ".join(cleanup_errors))
        try:
            with reporter.step("release executable and packaged resources remain byte-identical"):
                immutable_after = hash_tree(args.run_image.resolve())
                write_json(artifact_root / "resource-hashes-after.json", immutable_after)
                added = sorted(set(immutable_after) - set(immutable_before))
                removed = sorted(set(immutable_before) - set(immutable_after))
                changed = sorted(
                    path
                    for path in set(immutable_before) & set(immutable_after)
                    if immutable_before[path] != immutable_after[path]
                )
                write_json(
                    artifact_root / "resource-hash-diff.json",
                    {"added": added, "removed": removed, "changed": changed},
                )
                assert not added and not removed and not changed
        except Exception as error:
            failure = failure or error
        planned_cases = (
            "cancelled review discards its private snapshot",
            "review exposes permissions and the complete program declaration",
            "installed plugin survives application restart",
            "opening a declared language starts its server and child",
            "application exit revokes the language-server process tree",
            "two product windows revoke both owned process trees on disable",
            "approval-bound bytes reject post-review tampering",
            "same-version replacement, update, and rollback preserve provenance",
            "uninstall removes package and state",
            "uninstall revokes the language-server process tree",
            "owned application and helper processes cleanly terminate",
        )
        completed_names = {test["name"] for test in reporter.tests}
        for name in planned_cases:
            if name not in completed_names:
                reporter.tests.append(
                    {
                        "name": name,
                        "suite": "plugin-host-acceptance / native-windows-x64",
                        "status": "skipped",
                        "durationMs": 0,
                        "details": "An earlier acceptance step failed; this case was not executed.",
                        "maxMs": 120000,
                    }
                )
        if args.marketplace:
            from marketplace_acceptance import record_unreached_cases
            record_unreached_cases(reporter)
        write_json(
            args.report,
            {
                "runner": "acceptance",
                "warnMs": 30_000,
                "maxMs": 120_000,
                "tests": reporter.tests,
            },
        )

    if failure is not None:
        print(f"Windows plugin host acceptance failed: {failure}", file=sys.stderr)
        return 1
    print("Windows plugin host acceptance passed with isolated application identity.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
