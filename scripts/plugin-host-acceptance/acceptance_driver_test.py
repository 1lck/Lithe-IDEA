#!/usr/bin/env python3
"""Bounded driver checks, with an explicitly enabled browser DOM regression."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

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
    tests.append(
        {
            "name": name,
            "suite": "plugin-host-acceptance / driver",
            "status": status,
            "durationMs": round((time.monotonic() - started) * 1000, 3),
            "details": details,
            "maxMs": max_ms,
        }
    )
    if status != "passed":
        raise AssertionError(details)


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
        finally:
            browser.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--dom-browser", choices=["msedge"], help="Also run the HTML locator regression using this installed browser; no Lithe product is launched.")
    parser.add_argument("--dom-fixture-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.dom_fixture_child:
        if args.dom_browser is None:
            parser.error("--dom-fixture-child requires --dom-browser")
        grouped_plugin_dom(args.dom_browser)
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

    def timeout_cleans_tree():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="lithe-host-driver-test-", dir=args.report.parent
        ) as directory:
            pid_file = Path(directory) / "child.pid"
            script = (
                "import pathlib,subprocess,sys,time; "
                "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                f"pathlib.Path({str(pid_file)!r}).write_text(str(p.pid)); "
                "time.sleep(60)"
            )
            try:
                run_bounded_process([sys.executable, "-c", script], timeout_seconds=1)
            except TimeoutError:
                pass
            else:
                raise AssertionError("bounded process did not time out")
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            assert pid_file.exists(), "fixture child PID was not recorded"
            child_pid = int(pid_file.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 5
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            assert not process_exists(child_pid), f"timed-out child {child_pid} survived cleanup"

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

    try:
        run_case("bounded process captures a successful child", completes, tests)
        run_case("timeout terminates the owned process tree", timeout_cleans_tree, tests)
        run_case("termination targets a retained handle despite a changed PID", retained_handle_ignores_changed_pid, tests)
        run_case("creation-time and executable mismatches reject ownership", mismatched_identity_is_not_owned, tests)
        run_case("fixture arguments reject substring lookalikes", fixture_arguments_are_exact, tests)
        run_case("filesystem aliases preserve the retained process identity", executable_alias_retains_identity, tests)
        if args.dom_browser is not None:
            run_case("grouped installed rows select scoped detail actions", grouped_plugin_actions, tests, max_ms=35_000)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
