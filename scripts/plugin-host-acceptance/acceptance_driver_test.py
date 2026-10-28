#!/usr/bin/env python3
"""Bounded driver checks, with an explicitly enabled browser DOM regression."""

from __future__ import annotations

import argparse
import ctypes
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import acceptance_driver as driver
from acceptance_driver import (
    DISPLAY_NAME, PLUGIN_ID, OwnedProcess, fixture_command_matches,
    plugin_row, process_exists, run_bounded_process,
    select_plugin_details, set_plugin_enabled,
)
from playwright.sync_api import expect, sync_playwright


def run_case(name, action, tests, max_ms=10_000):
    started = time.monotonic()
    try:
        action()
        status = "passed"
        details = ""
    except Exception as error:  # noqa: BLE001 - the report must retain any failure.
        status = "failed"
        details = f"{type(error).__name__}: {error}"
    duration_ms = round((time.monotonic() - started) * 1000, 3)
    if duration_ms >= max_ms:
        status = "failed"
        details = f"{details}; " if details else ""
        details += f"test exceeded its {max_ms}ms budget ({duration_ms}ms)"
    tests.append(
        {
            "name": name,
            "suite": "plugin-host-acceptance / driver",
            "status": status,
            "durationMs": duration_ms,
            "details": details,
            "maxMs": max_ms,
        }
    )
    if status != "passed":
        # Retain the failure and nonzero suite exit while still checking the
        # remaining cleanup/identity/DOM regressions on an unhealthy machine.
        print(f"FAIL {name}: {details}", file=sys.stderr)


def grouped_plugin_dom(browser_channel: str) -> None:
    """Exercise the real locator API against grouped rows and external actions."""
    # The caller owns a process-level watchdog around this browser fixture;
    # launch and DOM actions additionally retain short local deadlines.
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=browser_channel, headless=True, timeout=10_000)
        try:
            page = browser.new_page()
            page.set_default_timeout(2_000)
            page.set_content(f"""
                <section aria-label="{DISPLAY_NAME}">
                  <button onclick="document.body.dataset.trap='true'">Uninstall</button>
                </section>
                <div data-settings-content="declarative-plugins">
                  <ul data-testid="declarative-plugin-list">
                    <li><h4>Enabled (3)</h4><ul>
                      <li data-plugin-id="{PLUGIN_ID}" data-plugin-source="bundled">
                        <button onclick="document.body.dataset.trap='true'">{DISPLAY_NAME}</button>
                      </li>
                      <li data-plugin-id="{PLUGIN_ID}" data-plugin-source="installed">
                        <button onclick="document.querySelector('#details').hidden=false;
                          this.setAttribute('aria-pressed', 'true')">{DISPLAY_NAME}</button>
                      </li>
                      <li data-plugin-id="io.example.other" data-plugin-source="installed">
                        <button onclick="document.body.dataset.trap='true'">Other</button>
                      </li>
                    </ul></li>
                  </ul>
                  <section id="details" aria-label="{DISPLAY_NAME}" hidden>
                    <button id="enabled" onclick="this.textContent=this.textContent==='Disable'?'Enable':'Disable'">Disable</button>
                    <button onclick="document.body.dataset.rolledBack='true'">Roll back…</button>
                    <button onclick="document.querySelector('[data-plugin-source=installed][data-plugin-id=\\'{PLUGIN_ID}\\']').remove()">Uninstall</button>
                  </section>
                </div>
            """, timeout=2_000)
            expect(plugin_row(page)).to_have_count(1)
            expect(page.locator("[data-testid='declarative-plugin-list'] > li")).to_have_count(1)
            details = select_plugin_details(page, timeout_ms=2_000)
            expect(plugin_row(page).get_by_role("button")).to_have_attribute("aria-pressed", "true")
            set_plugin_enabled(page, False, timeout_ms=2_000)
            expect(details.get_by_role("button", name="Enable", exact=True)).to_be_visible()
            set_plugin_enabled(page, True, timeout_ms=2_000)
            expect(details.get_by_role("button", name="Disable", exact=True)).to_be_visible()
            details.get_by_role("button", name="Roll back…", exact=True).click()
            expect(page.locator("body")).to_have_attribute("data-rolled-back", "true")
            details.get_by_role("button", name="Uninstall", exact=True).click()
            expect(plugin_row(page)).to_have_count(0)
            expect(page.locator("[data-plugin-source='bundled']")).to_have_count(1)
            expect(page.locator("[data-plugin-id='io.example.other']")).to_have_count(1)
            assert page.locator("body").get_attribute("data-trap") is None
            page.set_content('''
                <button aria-label="Settings" onclick="document.querySelector('#settings').hidden=false">Settings</button>
                <section id="settings" hidden>
                  <button data-settings-category="declarative-plugins"
                    onclick="document.querySelector('[data-settings-content]').hidden=false">Declarative plugins</button>
                  <div data-settings-content="declarative-plugins" hidden>Plugin list</div>
                </section>
            ''', timeout=2_000)
            page.evaluate("document.addEventListener('keydown', () => {document.body.dataset.keyboardTrap='true'})")
            driver.open_plugin_settings(page)
            assert page.locator("body").get_attribute("data-keyboard-trap") is None
            assert page.locator("[data-settings-content='declarative-plugins']").is_visible()
            page.set_content('''
                <div role="treeitem" data-root="true" aria-expanded="true">workspace</div>
                <div role="tab" aria-selected="false" onclick="this.setAttribute('aria-selected','true')">
                  acceptance.litheaccept
                  <button onclick="document.body.dataset.closed='true';event.stopPropagation()">Close</button>
                </div>
            ''', timeout=2_000)
            driver.open_fixture_file(page)
            expect(page.get_by_role("tab")).to_have_attribute("aria-selected", "true")
            assert page.locator("body").get_attribute("data-closed") is None
        finally:
            browser.close()


def cdp_observer_detaches_only(browser_channel: str) -> None:
    """Prove the pinned client's bounded close leaves its external browser alive."""
    port = driver.free_port()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=browser_channel, headless=True, timeout=10_000,
                                             args=[f"--remote-debugging-port={port}"])
        try:
            observer = playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{port}", timeout=10_000)
            driver.disconnect_cdp_observer(observer)
            assert not observer.is_connected()
            assert browser.is_connected(), "observer detach closed a browser it did not launch"
            page = browser.new_page()
            page.set_content("<title>still-owned</title>", timeout=2_000)
            assert page.title() == "still-owned"
        finally:
            browser.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--dom-browser", choices=["msedge"], help="Also run the HTML locator regression using this installed browser; no Lithe product is launched.")
    parser.add_argument("--dom-fixture-child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--observer-fixture-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.dom_fixture_child:
        if args.dom_browser is None:
            parser.error("--dom-fixture-child requires --dom-browser")
        grouped_plugin_dom(args.dom_browser)
        return 0
    if args.observer_fixture_child:
        if args.dom_browser is None:
            parser.error("--observer-fixture-child requires --dom-browser")
        cdp_observer_detaches_only(args.dom_browser)
        return 0
    if args.report is None:
        parser.error("--report is required")
    tests = []

    def completes():
        result = run_bounded_process(
            [sys.executable, "-c", "print('bounded-ok')"], timeout_seconds=5
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "bounded-ok"

    def output_is_utf8_and_loss_tolerant():
        result = run_bounded_process([
            sys.executable, "-c",
            "import sys; "
            "sys.stdout.buffer.write('进程输出'.encode('utf-8') + b'\\xff'); "
            "sys.stderr.buffer.write('查询错误'.encode('utf-8') + b'\\xfe'); "
            "sys.exit(1)",
        ], timeout_seconds=5)
        assert result.returncode == 1
        assert result.stdout == "进程输出\ufffd", repr(result.stdout)
        assert result.stderr == "查询错误\ufffd", repr(result.stderr)

    def inspection_failure_is_not_an_empty_tree():
        with patch.object(driver, "process_tree_ids", return_value=[123]), patch.object(driver, "process_exit_proven", return_value=False):
            with patch.object(driver.psutil, "Process", side_effect=driver.psutil.AccessDenied(123)):
                try:
                    driver.process_tree(123)
                except driver.psutil.AccessDenied:
                    pass
                else:
                    raise AssertionError("inspection failure was accepted as an empty tree")

    def exited_identity_race_requires_positive_proof():
        process = MagicMock()
        process.is_running.return_value = True
        with patch.object(driver.psutil, "Process", return_value=process), patch.object(OwnedProcess, "capture", return_value=None):
            with patch.object(driver, "process_exit_proven", return_value=True):
                assert driver.process_record(123) is None
            with patch.object(driver, "process_exit_proven", return_value=False):
                try:
                    driver.process_record(123)
                except RuntimeError as error:
                    assert "could not inspect" in str(error)
                else:
                    raise AssertionError("live identity failure was swallowed")
        with patch.object(driver.psutil, "Process", side_effect=driver.psutil.AccessDenied(123)):
            with patch.object(driver, "process_exit_proven", return_value=True):
                assert driver.process_record(123) is None
            with patch.object(driver, "process_exit_proven", return_value=False):
                try:
                    driver.process_record(123)
                except driver.psutil.AccessDenied:
                    pass
                else:
                    raise AssertionError("live AccessDenied owner was swallowed")

    def native_exit_proof_rejects_denied_or_failed_inspection():
        for state, expected in ((0, True), (driver.WAIT_TIMEOUT, False)):
            with patch.object(driver.kernel32, "OpenProcess", return_value=456), patch.object(driver.kernel32, "WaitForSingleObject", return_value=state):
                with patch.object(driver.kernel32, "CloseHandle") as close:
                    assert driver.process_exit_proven(123) is expected
                    close.assert_called_once_with(456)
        for open_handle, error, state in ((0, 87, 0), (0, 5, 0), (456, 5, 0xFFFFFFFF)):
            with patch.object(driver.kernel32, "OpenProcess", return_value=open_handle), patch.object(driver.kernel32, "GetLastError", return_value=error):
                with patch.object(driver.kernel32, "WaitForSingleObject", return_value=state), patch.object(driver.kernel32, "CloseHandle") as close:
                    if error == 87:
                        assert driver.process_exit_proven(123)
                    else:
                        try:
                            driver.process_exit_proven(123)
                        except OSError as failure:
                            assert failure.winerror == 5
                        else:
                            raise AssertionError("uninspectable process was reported exited")
                    assert close.call_count == bool(open_handle)
        owner = OwnedProcess(123, 456, 1000, "fixture.exe")
        with patch.object(driver.kernel32, "WaitForSingleObject", return_value=0xFFFFFFFF), patch.object(driver.kernel32, "GetLastError", return_value=5):
            try:
                owner.running()
            except OSError as failure:
                assert failure.winerror == 5
            else:
                raise AssertionError("failed retained-handle wait was reported exited")

    def capture_tree_rejects_live_uninspectable_child():
        root = MagicMock(pid=101, creation_time=1000, descendants=[])
        root.running.return_value = True
        records = [{"ProcessId": 101, "ParentProcessId": 0, "CreationTime": 1000},
                   {"ProcessId": 102, "ParentProcessId": 101, "CreationTime": 1001}]
        with patch.object(driver, "remember_owned_process", return_value=None):
            with patch.object(driver, "process_exit_proven", return_value=True):
                assert driver.capture_owned_tree(root, records) == []
            with patch.object(driver, "process_exit_proven", return_value=False):
                try:
                    driver.capture_owned_tree(root, records)
                except RuntimeError as error:
                    assert "could not retain the live process identity" in str(error)
                else:
                    raise AssertionError("live uninspectable child was omitted")

    def short_lived_native_process_has_signaled_exit_proof():
        # Popen retains the original kernel object until context exit. Waiting
        # establishes the race order without timing sleeps or PID-name cleanup.
        with subprocess.Popen([sys.executable, "-c", "pass"], creationflags=driver.CREATE_NO_WINDOW) as child:
            try:
                child.wait(timeout=5)
                assert driver.process_exit_proven(child.pid)
                process = MagicMock()
                process.is_running.return_value = True
                with patch.object(driver.psutil, "Process", return_value=process), patch.object(OwnedProcess, "capture", return_value=None):
                    assert driver.process_record(child.pid) is None
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)

    def metadata_rejects_pid_reuse_and_closes_identity():
        process, identity = MagicMock(), MagicMock()
        process.is_running.return_value = False
        identity.creation_time = 134000000000000001
        identity.executable = "C:/fixture/node.exe"
        with patch.object(driver.psutil, "Process", return_value=process):
            with patch.object(driver.OwnedProcess, "capture", return_value=identity):
                assert driver.process_record(123) is None
                identity.close.assert_called_once()
        process.is_running.return_value = True
        identity.running.return_value = True
        process.ppid.return_value = 100
        process.name.return_value = "node.exe"
        process.cmdline.return_value = ["node.exe", "中文 fixture.mjs"]
        identity.reset_mock()
        with patch.object(driver.psutil, "Process", return_value=process):
            with patch.object(driver.OwnedProcess, "capture", return_value=identity):
                record = driver.process_record(123)
                assert record["CreationTime"] == 134000000000000001
                assert record["ParentProcessId"] == 100
                assert record["CommandLine"] == 'node.exe "中文 fixture.mjs"'
                identity.close.assert_called_once()

    def topology_snapshot_closes_handles_and_rejects_errors():
        entries = iter([(101, 0), (102, 101), (103, 102), (999, 0)])

        def next_entry(_handle, pointer):
            try:
                pid, parent_pid = next(entries)
            except StopIteration:
                return False
            entry = ctypes.cast(pointer, ctypes.POINTER(driver.ProcessEntry32)).contents
            assert entry.dwSize == ctypes.sizeof(driver.ProcessEntry32)
            entry.th32ProcessID, entry.th32ParentProcessID = pid, parent_pid
            return True

        with patch.object(driver.kernel32, "CreateToolhelp32Snapshot", return_value=456):
            with patch.object(driver.kernel32, "Process32FirstW", side_effect=next_entry):
                with patch.object(driver.kernel32, "Process32NextW", side_effect=next_entry):
                    with patch.object(driver.kernel32, "GetLastError", return_value=driver.ERROR_NO_MORE_FILES):
                        with patch.object(driver.kernel32, "CloseHandle") as close:
                            assert driver.process_tree_ids(101) == [101, 102, 103]
                            close.assert_called_once_with(456)
            with patch.object(driver.kernel32, "Process32FirstW", return_value=False):
                with patch.object(driver.kernel32, "GetLastError", return_value=5):
                    with patch.object(driver.kernel32, "CloseHandle") as close:
                        try:
                            driver.process_tree_ids(101)
                        except OSError as error:
                            assert error.winerror == 5
                        else:
                            raise AssertionError("failed topology snapshot was accepted as an empty tree")
                        close.assert_called_once_with(456)
        with patch.object(driver.kernel32, "CreateToolhelp32Snapshot", return_value=driver.INVALID_HANDLE_VALUE):
            with patch.object(driver.kernel32, "GetLastError", return_value=5):
                with patch.object(driver.kernel32, "CloseHandle") as close:
                    try:
                        driver.process_tree_ids(101)
                    except OSError as error:
                        assert error.winerror == 5
                    else:
                        raise AssertionError("invalid snapshot handle was accepted")
                    close.assert_not_called()

    def wrapper_inventory_rejects_unrelated_lookalikes():
        executable = Path("C:/fixture/lithe-host-acceptance.exe")
        state = Path(driver.os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER / "plugin-state" / PLUGIN_ID
        candidates = []
        records = {}
        for pid, directory in ((101, state / "workspace"), (102, Path(str(state) + "-unrelated"))):
            process = MagicMock(pid=pid)
            process.info = {"pid": pid, "name": "node.exe"}
            candidates.append(process)
            records[pid] = {"ProcessId": pid, "ExecutablePath": "C:/runtime/node.exe",
                            "CommandLine": subprocess.list2cmdline([
                                "node.exe", "C:/fixture/fake-lsp-server.mjs", "--state-dir", str(directory),
                            ])}
        with patch.object(driver.psutil, "process_iter", return_value=candidates):
            with patch.object(driver, "process_record", side_effect=records.get):
                with patch.object(driver, "process_tree", side_effect=lambda pid: [records[pid]]) as tree:
                    assert driver.acceptance_process_inventory(executable, driver.ACCEPTANCE_IDENTIFIER) == [records[101]]
                    tree.assert_called_once_with(101)
    def query_failure_still_cleans_retained_handles():
        class HandleOwner:
            def __init__(self, pid):
                self.pid = pid
                self.alive = True
                self.descendants = []
                self.terminated = False
                self.creation_time = pid * 100

            def running(self):
                return self.alive

            def terminate(self):
                self.terminated = True
                self.alive = False

        root, child, unrelated = (HandleOwner(pid) for pid in (101, 102, 103))
        records = [
            {"ProcessId": root.pid, "ParentProcessId": 0, "CreationTime": root.creation_time},
            {"ProcessId": child.pid, "ParentProcessId": root.pid, "CreationTime": child.creation_time},
        ]
        with patch.object(driver, "remember_owned_process", return_value=child):
            assert driver.capture_owned_tree(root, records) == [child]
        query_error = RuntimeError("CIM 查询失败")
        with patch.object(driver, "owned_processes", {item.pid: item for item in (root, child, unrelated)}):
            with patch.object(driver, "process_tree", side_effect=query_error):
                try:
                    driver.terminate_process_tree(root.pid, timeout_seconds=0)
                except RuntimeError as error:
                    assert error.__cause__ is query_error
                    assert "CIM 查询失败" in str(error)
                    assert "uninspected descendants may remain" in str(error)
                else:
                    raise AssertionError("failed inspection reported complete tree cleanup")
        assert root.terminated and child.terminated
        assert unrelated.alive and not unrelated.terminated

    def cleanup_distinguishes_exiting_and_surviving_handles():
        class ExitingHandle:
            pid = 123
            descendants = []

            def __init__(self, survives):
                self.alive = True
                self.survives = survives

            def running(self):
                return self.alive

            def terminate(self):
                self.alive = self.survives
                raise RuntimeError("controlled native termination denial")

        exited = ExitingHandle(False)
        with patch.dict(driver.owned_processes, {exited.pid: exited}, clear=True):
            driver.terminate_process_tree(exited.pid, timeout_seconds=0, inspect_descendants=False)
        survivor = ExitingHandle(True)
        with patch.dict(driver.owned_processes, {survivor.pid: survivor}, clear=True):
            try:
                driver.terminate_process_tree(survivor.pid, timeout_seconds=0, inspect_descendants=False)
            except RuntimeError as error:
                assert "controlled native termination denial" in str(error)
                assert "owned process handles survived cleanup: [123]" in str(error)
            else:
                raise AssertionError("a surviving retained handle was accepted as clean")

    def timeout_query_failure_keeps_error_and_reaps_root():
        real_popen = driver.subprocess.Popen
        spawned = []

        def capture_popen(*positional, **keyword):
            process = real_popen(*positional, **keyword)
            spawned.append(process)
            return process

        try:
            with patch.object(driver.subprocess, "Popen", side_effect=capture_popen):
                with patch.object(driver, "process_tree", side_effect=RuntimeError("CIM unavailable")):
                    try:
                        run_bounded_process([
                            sys.executable, "-c", "import time; time.sleep(60)",
                        ], timeout_seconds=0.05)
                    except TimeoutError as error:
                        assert "CIM unavailable" in str(error), str(error)
                        assert "uninspected descendants may remain" in str(error), str(error)
                    else:
                        raise AssertionError("bounded process did not time out")
            assert len(spawned) == 1
            assert spawned[0].poll() is not None, "retained root survived failed inspection"
            assert spawned[0].pid not in driver.owned_processes, "root ownership was not released after cleanup"
        finally:
            for process in spawned:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)

    def timeout_cleans_tree():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="lithe-host-driver-test-", dir=args.report.parent
        ) as directory:
            pid_file = Path(directory) / "child.pid"
            script = (
                "import json,pathlib,subprocess,sys,time; "
                f"sys.path.insert(0,{str(Path(__file__).resolve().parent)!r}); "
                "from acceptance_driver import OwnedProcess; "
                "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                "owner=OwnedProcess.capture(p.pid); assert owner is not None; "
                f"pathlib.Path({str(pid_file)!r}).write_text(json.dumps("
                "{'pid':p.pid,'CreationTime':owner.creation_time,'ExecutablePath':owner.executable}),encoding='utf-8'); "
                "time.sleep(60)"
            )
            child_owner = None
            command = [sys.executable, "-B", "-c", script]
            communicate = subprocess.Popen.communicate

            def fixture_ready():
                try:
                    identity = json.loads(pid_file.read_text(encoding="utf-8"))
                    return bool(identity.get("pid") and identity.get("CreationTime") and identity.get("ExecutablePath"))
                except (FileNotFoundError, json.JSONDecodeError):
                    return False

            def communicate_after_ready(process, *arguments, **keywords):
                # This case checks an already-created tree. Arm its timeout only
                # after the fixture's child identity is complete, not after an
                # assumed Python startup duration. Failure still enters the
                # production timeout cleanup with its retained root handle.
                if process.args == command:
                    try:
                        driver.wait_until(fixture_ready, 5, "the timeout fixture child identity")
                    except (TimeoutError, OSError) as error:
                        raise subprocess.TimeoutExpired(command, 5) from error
                return communicate(process, *arguments, **keywords)

            try:
                try:
                    with patch.object(subprocess.Popen, "communicate", communicate_after_ready):
                        run_bounded_process(command, timeout_seconds=1)
                except TimeoutError as error:
                    timeout_error = str(error)
                else:
                    raise AssertionError("bounded process did not time out")
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert pid_file.exists(), "fixture child PID was not recorded"
                identity = json.loads(pid_file.read_text(encoding="utf-8"))
                child_pid = identity["pid"]
                # Keep teardown ownership separate from the driver's cached
                # tree, so it cannot make the behavior under test succeed.
                child_owner = OwnedProcess.capture(child_pid, identity)
                deadline = time.monotonic() + 5
                while process_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert not process_exists(child_pid), f"timed-out child {child_pid} survived cleanup: {timeout_error}"
                assert "cleanup could not be confirmed" not in timeout_error, timeout_error
            finally:
                if child_owner is None and pid_file.exists():
                    identity = json.loads(pid_file.read_text(encoding="utf-8"))
                    child_owner = OwnedProcess.capture(identity["pid"], identity)
                if child_owner is not None:
                    try:
                        child_owner.terminate()
                        driver.wait_until(lambda: not child_owner.running(), 3, "the fixture child's final cleanup", interval=0.02)
                    finally:
                        child_owner.close()

    def retained_handle_ignores_changed_pid():
        first = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        second = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        owner = None
        try:
            owner = OwnedProcess.capture(first.pid)
            assert owner is not None
            # Model PID reuse without depending on the OS actually recycling it.
            owner.pid = second.pid
            owner.terminate()
            first.wait(timeout=3)
            assert second.poll() is None, "termination followed a recycled PID instead of the retained handle"
        finally:
            if owner is not None:
                owner.close()
            for process in (first, second):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)

    def mismatched_identity_is_not_owned():
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        original = rejected = None
        try:
            original = OwnedProcess.capture(process.pid)
            assert original is not None
            rejected = OwnedProcess.capture(process.pid, {
                "CreationTime": original.creation_time - 100,
                "ExecutablePath": original.executable,
            })
            assert rejected is None
            rejected = OwnedProcess.capture(process.pid, {
                "CreationTime": original.creation_time,
                "ExecutablePath": original.executable + ".unrelated",
            })
            assert rejected is None
            assert process.poll() is None
        finally:
            if original is not None:
                original.close()
            if rejected is not None:
                rejected.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)

    def fixture_arguments_are_exact():
        root = Path(tempfile.gettempdir()) / "lithe fixture state"
        valid = subprocess.list2cmdline(["node.exe", "C:/fixture/fake-lsp-server.mjs", "--state-dir", str(root)])
        assert fixture_command_matches(valid, root)
        assert not fixture_command_matches(valid.replace("fake-lsp-server.mjs", "other-fake-lsp-server.mjs"), root)
        sibling = subprocess.list2cmdline(["node.exe", "C:/fixture/fake-lsp-server.mjs", "--state-dir", str(root) + "-unrelated"])
        assert not fixture_command_matches(sibling, root)

    def executable_alias_retains_identity():
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        original = alias_owner = None
        try:
            original = OwnedProcess.capture(process.pid)
            assert original is not None
            # The extended Windows path names the same executable through a
            # different spelling, without requiring junction privileges.
            executable_alias = "\\\\?\\" + original.executable
            alias_owner = OwnedProcess.capture(process.pid, {
                "CreationTime": original.creation_time,
                "ExecutablePath": executable_alias,
            })
            assert alias_owner is not None, "a filesystem alias rejected the original process identity"
            assert alias_owner.running()
            assert alias_owner.creation_time == original.creation_time
        finally:
            for owner in (original, alias_owner):
                if owner is not None:
                    owner.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)

    def grouped_plugin_actions():
        result = run_bounded_process([
            sys.executable, "-B", str(Path(__file__).resolve()),
            "--dom-browser", args.dom_browser, "--dom-fixture-child",
        ], timeout_seconds=30)
        assert result.returncode == 0, result.stderr or result.stdout

    def observer_detach_preserves_external_browser():
        result = run_bounded_process([
            sys.executable, "-B", str(Path(__file__).resolve()),
            "--dom-browser", args.dom_browser, "--observer-fixture-child",
        ], timeout_seconds=30)
        assert result.returncode == 0, result.stderr or result.stdout

    def application_quit_uses_all_product_labels_and_waits_for_real_close():
        page = MagicMock()
        labels = ["main", "project-2", "hidden-launcher"]
        with patch.object(driver, "invoke", return_value=labels) as invoke:
            result = driver.request_application_quit(page)
        invoke.assert_called_once_with(page, "plugin:window|get_all_windows")
        page.expect_event.assert_called_once_with("close", timeout=15_000)
        script, emitted = page.evaluate.call_args.args
        assert emitted == labels
        assert 'Promise.all(labels.map(label' in script
        assert '"plugin:event|emit_to"' in script and 'event: "menu_quit_app"' in script
        assert 'kind: "AnyLabel", label' in script
        assert result == {"windowLabels": labels, "observedProductPageClosed": True, "dispatch": "acknowledged"}
        page.reset_mock()
        page.evaluate.side_effect = driver.TargetClosedError("fixture page closed during acknowledgement")
        with patch.object(driver, "invoke", return_value=labels):
            assert driver.request_application_quit(page)["observedProductPageClosed"] is True
        page.expect_event.assert_called_once_with("close", timeout=15_000)
        page.evaluate.side_effect = RuntimeError("fixture permission denied")
        with patch.object(driver, "invoke", return_value=labels):
            try:
                driver.request_application_quit(page)
            except RuntimeError as error:
                assert str(error) == "fixture permission denied"
            else:
                raise AssertionError("a rejected quit dispatch was accepted")
        page.reset_mock()
        with patch.object(driver, "invoke", return_value=[]):
            try:
                driver.request_application_quit(page)
            except RuntimeError as error:
                assert "WebviewWindow labels" in str(error)
            else:
                raise AssertionError("an empty product window list was accepted")
        page.evaluate.assert_not_called()

    def session_observes_quit_before_detach_and_keeps_failed_cleanup_evidence():
        with tempfile.TemporaryDirectory(prefix="lithe-session-stop-") as directory:
            root = Path(directory)
            session = driver.AppSession(None, root / "app.exe", root, root / "webview", root / "logs", 1)
            owner = MagicMock(pid=101)
            owner.running.return_value = True
            session.root_owner = owner
            session.process = MagicMock(pid=101, returncode=0)
            session.process.poll.return_value = 0
            session.browser = MagicMock()
            session.page = MagicMock()
            session.page.is_closed.return_value = False
            events = []
            def waited(**_):
                events.append("wait")
                owner.running.return_value = False
            session.process.wait.side_effect = waited
            with patch.object(driver, "process_tree", return_value=[]):
                with patch.object(driver, "capture_owned_tree", return_value=[]):
                    with patch.object(driver, "application_window_inventory", side_effect=lambda _: events.append("inventory") or []):
                        with patch.object(driver, "disconnect_cdp_observer", side_effect=lambda _: events.append("disconnect")):
                            def request_quit(_page, evidence):
                                events.append("quit-closed")
                                evidence.update({"windowLabels": ["main", "hidden"], "observedProductPageClosed": True})
                            with patch.object(driver, "request_application_quit", side_effect=request_quit):
                                result = session.stop()
            assert events == ["inventory", "quit-closed", "disconnect", "wait"], events
            assert result["forced"] is False
            assert result["attempts"][0]["quitRequest"]["windowLabels"] == ["main", "hidden"]
            assert result["attempts"][0]["observerDetachedAfterWindowClose"] is True

            child = MagicMock(pid=102, creation_time=12345, executable="C:/fixture/webview.exe")
            child.running.return_value = True
            session.owned_tree = [child]
            clock = iter(range(0, 1000, 20))
            def terminate(_):
                child.running.return_value = False
            with patch.object(driver.time, "monotonic", side_effect=lambda: next(clock)):
                with patch.object(driver, "terminate_process_tree", side_effect=terminate):
                    try:
                        session.stop()
                    except RuntimeError as error:
                        assert "left survivors: [102]" in str(error)
                    else:
                        raise AssertionError("forced descendant cleanup was accepted as graceful")
            final = session.stop(require_graceful=False)
            assert final["forced"] is True, "a later cleanup attempt hid the original forced cleanup"
            assert final["attempts"][1]["survivorsBeforeCleanup"] == [
                {"pid": 102, "creationTime": 12345, "executable": "C:/fixture/webview.exe"}]
            recorded = json.loads((root / "logs/app-1.stop.json").read_text(encoding="utf-8"))
            assert recorded[1]["forced"] is True and "left survivors" in recorded[1]["error"]

    try:
        run_case("bounded process captures a successful child", completes, tests)
        run_case("process output decodes UTF-8 and replaces malformed bytes", output_is_utf8_and_loss_tolerant, tests)
        run_case("inspection errors cannot become an empty process tree", inspection_failure_is_not_an_empty_tree, tests)
        run_case("exited identity races require positive proof and live owners fail", exited_identity_race_requires_positive_proof, tests)
        run_case("native exit proof rejects denied handles and failed waits", native_exit_proof_rejects_denied_or_failed_inspection, tests)
        run_case("tree retention skips proven exit but rejects a live uninspectable child", capture_tree_rejects_live_uninspectable_child, tests)
        run_case("short-lived native process exposes a signaled original object", short_lived_native_process_has_signaled_exit_proof, tests)
        run_case("metadata rejects PID reuse and preserves exact native identity", metadata_rejects_pid_reuse_and_closes_identity, tests)
        run_case("topology snapshots close their handles and reject inspection errors", topology_snapshot_closes_handles_and_rejects_errors, tests)
        run_case("wrapper inventory rejects unrelated fixture path lookalikes", wrapper_inventory_rejects_unrelated_lookalikes, tests)
        run_case("query failure cleans retained handles without touching unrelated processes", query_failure_still_cleans_retained_handles, tests)
        run_case("cleanup accepts a signaled original handle but rejects a surviving handle", cleanup_distinguishes_exiting_and_surviving_handles, tests)
        run_case("timeout preserves query failure and reaps its retained root", timeout_query_failure_keeps_error_and_reaps_root, tests)
        run_case("timeout terminates the owned process tree", timeout_cleans_tree, tests)
        run_case("termination targets a retained handle despite a changed PID", retained_handle_ignores_changed_pid, tests)
        run_case("creation-time and executable mismatches reject ownership", mismatched_identity_is_not_owned, tests)
        run_case("fixture arguments reject substring lookalikes", fixture_arguments_are_exact, tests)
        run_case("filesystem aliases preserve the retained process identity", executable_alias_retains_identity, tests)
        run_case("application quit uses all product labels and waits for real close", application_quit_uses_all_product_labels_and_waits_for_real_close, tests)
        run_case("session observes quit before detach and retains failed cleanup evidence", session_observes_quit_before_detach_and_keeps_failed_cleanup_evidence, tests)
        if args.dom_browser is not None:
            run_case("grouped installed rows select scoped detail actions", grouped_plugin_actions, tests, max_ms=35_000)
            run_case("CDP observer detach leaves the external browser alive", observer_detach_preserves_external_browser, tests, max_ms=35_000)
        else:
            tests.append({
                "name": "grouped installed rows select scoped detail actions",
                "suite": "plugin-host-acceptance / driver",
                "status": "skipped",
                "durationMs": 0,
                "maxMs": 35_000,
                "details": "Not requested; pass --dom-browser msedge to exercise the lightweight HTML locator regression. This is separate from native product acceptance.",
            })
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(
                {
                    "runner": "acceptance",
                    "warnMs": 2_000,
                    "maxMs": 10_000,
                    "tests": tests,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return 1 if any(test["status"] == "failed" for test in tests) else 0


if __name__ == "__main__":
    raise SystemExit(main())
