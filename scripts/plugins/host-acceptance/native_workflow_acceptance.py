#!/usr/bin/env python3
"""Normal community install -> Provider -> functions/settings/native panels.

Run under the existing assign-before-release Windows Job and AppSession. No
capability override, installation-record edits, mock IPC or synthetic IME events.
This controlled unsigned input cannot certify M10's external signed packages.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path

from build_acceptance import missing_capabilities, source_capabilities
from build_fixture import json_bytes
from generator_acceptance import cleanup_session, runtime_paths
from native_workflow_fixture import DISPLAY_NAME, PLUGIN_ID, REQUIRES, declaration, load_plan
from settings_functions_acceptance import (assert_resources, snapshot_resources,
                                          sha256, verify_host, verify_installed_archive)
from text_window_fixture import source_inventory

# Reuse the bounded native transport/output observer. It forwards original
# callbacks unchanged and retains Core-decoded events, never parses reports.
OBSERVER = Path(__file__).with_name("java_workflow_observer.js").read_text(encoding="utf-8")
OBSERVER_OPTIONS = {"namespace": "__litheSettingsAcceptance", "includePluginCommands": True}

CASES = ("source-and-install-review", "provider-model", "task-test-dependencies",
         "tree-state-and-selection", "list-long-empty", "function-progress-cancel-error",
         "form-controls-and-restore", "settings-explicit-save-cancel", "two-window-global-settings",
         "shared-provider-functions-and-registration", "settings-effects-and-project-reload",
         "replace-disable-uninstall", "quit-and-resource-invariance")
PENDING = {
    "real-ime-and-native-focus": "Real Chinese IME composition, candidate windows, native hierarchy and window activation need human observation; DOM events are insufficient.",
    "theme-narrow-docking": "Automated real-menu cross-slot movement, narrow grid and close-focus checks run in the full package lane; dark/light visual quality and native drag still need manual acceptance.",
    "full-version-contract": "Model task selectors, missing-report presentation, overlapping requests and injected native cleanup-failure recovery require their full product lanes before capability admission.",
    "external-formal-M10": "This newly generated unsigned community archive is not an external signed official artifact.",
    "windows-arm64": "No native ARM64 product run in this lane.",
}


def pending_rows(reason):
    return [{"name": name, "suite": "controlled-native-workflow", "status": "skipped",
             "durationMs": 0, "maxMs": 120_000, "details": reason} for name in CASES]


def preflight(plan, capabilities):
    missing = missing_capabilities(REQUIRES, capabilities)
    return {"runtimeExecuted": False, "complete": False, "controlledSubsetPassed": False,
            "blocked": ["closed capability " + item for item in missing], "fixture": plan,
            "hostCapabilities": capabilities,
            "tests": pending_rows("Not executed. " + (", ".join(missing) if missing else "Explicit source-bound product run required."))}


def read(page, expression, argument=None):
    # Also bound renderer/transport loss, not only JavaScript's promise timers.
    return page._sync(asyncio.wait_for(page._impl_obj.evaluate(expression, arg=argument), timeout=10))


def function_receipt(calls, operation):
    """Observe one real IPC operation; never retry or infer success from silence."""
    for call in calls:
        if call.get("args", {}).get("operationId") != operation or not call.get("settled"):
            continue
        if call["command"] not in ("declarative_plugins_function_prepare", "declarative_plugins_function_confirm", "declarative_plugins_function_state"):
            continue
        if call.get("error"):
            raise AssertionError(f"{operation}: {call['error']}")
        if call["command"] == "declarative_plugins_function_state":
            value = call.get("value") or {}
            if value.get("phase") in ("failed", "cancelled", "cleanupFailed"):
                raise AssertionError(f"{operation}: {json.dumps(value, ensure_ascii=True)}")
            if value.get("phase") == "succeeded":
                if value.get("context", {}).get("operationId") != operation:
                    raise AssertionError(f"{operation}: terminal identity mismatch")
                return value
    return None


def settings_conflict_receipt(calls):
    """A saved revision revokes the old panel receipt before any approval."""
    prepared = [row for row in calls if row["command"] == "declarative_plugins_native_function_prepare"]
    if len(prepared) != 1 or not prepared[0].get("settled"):
        raise AssertionError("expected one settled stale native preparation")
    row = prepared[0]
    if not isinstance(row.get("error"), dict) or row["error"].get("code") != "plugin.settings.conflict":
        raise AssertionError(f"expected exact settings conflict: {row}")
    if any(call["command"] == "declarative_plugins_function_confirm" for call in calls):
        raise AssertionError("stale native preparation was confirmed")
    return row


def project_reload_receipt(calls, *, restart_required=False):
    """The reload notice owns one normal approved model load, not a second load."""
    def one(command):
        rows = [row for row in calls if row["command"] == command]
        failure_expected = restart_required and command == "declarative_plugins_build_load_model"
        valid = (len(rows) == 1 and rows[0].get("settled") and
                 ((rows[0].get("error") == "plugin.build.restartRequired" and not rows[0].get("value"))
                  if failure_expected else (not rows[0].get("error") and rows[0].get("value"))))
        if not valid:
            raise AssertionError(f"project reload requires one successful or expected restart-required {command}: {rows}")
        return rows[0]
    reloaded = one("declarative_plugins_reload_settings")
    prepared = one("declarative_plugins_prepare_settings_reload_model")
    loaded = one("declarative_plugins_build_load_model")
    receipt = reloaded.get("args", {})
    operation = prepared["value"].get("operationId")
    if (receipt.get("scope") != "project" or not receipt.get("project")
            or prepared.get("args", {}).get("receipt") != receipt
            or not operation or loaded.get("args", {}).get("operationId") != operation):
        raise AssertionError("project reload model receipt/operation identity mismatch")
    return {"reload": reloaded, "prepared": prepared, "loaded": loaded}


def run_receipt(calls, events, action, scope, workspace):
    preparations = [row for row in calls if row["command"] == "declarative_plugins_build_prepare_run"]
    executions = [row for row in calls if row["command"] == "declarative_plugins_build_execute_run"]
    if len(preparations) != 1 or len(executions) != 1:
        raise AssertionError("task/test requires exactly one preparation and execution")
    prepared, executed = preparations[0], executions[0]
    if any(not row.get("settled") or row.get("error") for row in (prepared, executed)):
        raise AssertionError(f"task/test IPC failed: {prepared}, {executed}")
    testing = action == "Tests"
    expected_selection = {"kind": "test" if testing else "task", "taskId": None if testing else "build",
        "projectId": None if scope == "Workspace" else "workflow:Workflow project",
        "targetId": "workflow.test:Workflow tests" if scope == "Target" else None,
        "modelTaskId": None, "suite": "fixture.Suite" if testing else None,
        "case": "fails" if testing else None, "userArguments": []}
    if prepared.get("args", {}).get("selection") != expected_selection:
        raise AssertionError("task/test selector identity mismatch")
    review = prepared.get("value") or {}
    identity = {key: review.get(key) for key in
                ("operationId", "pluginId", "buildSystemId", "root", "workspaceRoot", "generation")}
    if (not identity["operationId"] or identity["pluginId"] != PLUGIN_ID or identity["buildSystemId"] != "workflow"
            or identity["root"] != "." or identity["workspaceRoot"] != str(workspace)
            or not isinstance(identity["generation"], int)
            or executed.get("args", {}).get("operationId") != identity["operationId"]
            or any(prepared.get("args", {}).get(key) != identity[key] for key in ("pluginId", "buildSystemId", "root", "workspaceRoot"))):
        raise AssertionError("task/test operation identity mismatch")
    actual = [event for event in events if event.get("operationId") == identity["operationId"]]
    if any(any(event.get(key) != value for key, value in identity.items()) for event in actual):
        raise AssertionError("task/test output identity mismatch")
    terminal = executed.get("value") or {}
    if terminal.get("kind") != ("failed" if testing else "succeeded") or terminal.get("exitCode") != (1 if testing else 0):
        raise AssertionError(f"unexpected task/test terminal: {terminal}")
    terminals = [event for event in actual if event.get("type") == "terminal"]
    if len(terminals) != 1 or terminals[0].get("terminal") != terminal or actual[-1] != terminals[0]:
        raise AssertionError("missing, duplicate or unordered task/test terminal event")
    if testing:
        reports = [event.get("results", {}) for event in actual if event.get("type") == "testResults"]
        diagnostics = [item for event in actual if event.get("type") == "diagnostics" for item in event.get("diagnostics", [])]
        if (len(reports) != 1 or reports[0].get("success") is not False
                or reports[0].get("summary") != {"total": 1, "passed": 0, "failed": 1, "errors": 0, "skipped": 0}
                or not any(case.get("suite") == "fixture.Suite" and case.get("case") == "fails"
                           and case.get("status") == "failed" and "controlled failure" in case.get("message", "")
                           for case in reports[0].get("tests", []))
                or not any(item.get("message") == "controlled diagnostic" and item.get("severity") == "error" for item in diagnostics)):
            raise AssertionError("missing or incorrect Core-decoded test report/diagnostics")
    elif "controlled task stdout" not in "".join(event.get("text", "") for event in actual
                                                if event.get("type") == "chunk" and event.get("stream") == "stdout"):
        raise AssertionError("missing controlled task output")
    return {"identity": identity, "selection": expected_selection, "terminal": terminal, "events": actual}


class Workflow:
    def __init__(self, args, driver, reporter):
        self.args, self.driver, self.reporter = args, driver, reporter
        self.page = self.session = self.second = None
        self.version = "1.0.0"
        self.workspace = args.fixture_root / "one"
        self.manifest = declaration(self.version)
        self.observed = []
        self.saved_backend_events = []
        self.deadline = time.monotonic() + 780

    def wait(self, predicate, description):
        def pump():
            if time.monotonic() >= self.deadline:
                raise TimeoutError("native workflow work deadline; cleanup remains reserved")
            return predicate()
        return self.driver.wait_until(pump, 30, description)

    def calls(self, page=None):
        return read(page or self.page, "() => window.__litheSettingsAcceptance.snapshot().calls")

    def capture_failure(self):
        try:
            self.driver.write_json(self.args.artifact_root / "ipc-snapshot-failure.json",
                                   read(self.page, "() => window.__litheSettingsAcceptance.snapshot()"))
            self.driver.write_json(self.args.artifact_root / "ipc-failure.json", self.calls())
        finally:
            self.driver.capture_session_failure(self.session, self.args.artifact_root)

    def backend_events(self):
        rows = []
        for root in (self.args.app_local_data, self.args.app_roaming_data):
            for path in root.glob("plugin-state/**/native-events.jsonl"):
                # An in-flight append may leave its last record incomplete.
                for line in path.read_text(encoding="utf-8").splitlines(keepends=True):
                    if line.endswith("\n"):
                        rows.append(json.loads(line))
        return rows

    def preserve_backend(self, stage):
        rows = self.backend_events()
        self.driver.write_json(self.args.artifact_root / (stage + "-backend-events.json"), rows)
        self.saved_backend_events.append({"stage": stage, "events": rows})
        return rows

    def settled(self, command, offset):
        return next((row for row in self.calls()[offset:] if row["command"] == command and row.get("settled")), None)

    def approved(self, predicate, description, *, decline=False):
        def pump():
            dialog = self.page.get_by_role("dialog", name=re.compile(r"^Review (model loading|task . test execution|dependency loading)$"))
            if dialog.count() and dialog.is_visible():
                text = dialog.inner_text(timeout=5000)
                if PLUGIN_ID not in text:
                    raise AssertionError("approval does not identify this plugin")
                dialog.get_by_role("button", name="Decline" if decline else re.compile(r"^(Allow and execute|Allow and load|Approve and load)$"), exact=True).click(timeout=5000)
            return predicate()
        return self.wait(pump, description)

    def catalog(self, page=None):
        return next((row for row in self.driver.invoke(page or self.page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)

    def details(self, page=None):
        page = page or self.page
        self.driver.open_plugin_settings(page)
        page.locator(f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']").get_by_role("button").click(timeout=10000)
        return page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=DISPLAY_NAME, exact=True)

    def install(self, version, *, cancel=False):
        review = self.driver.import_review(self.page, self.session.process.pid, self.args.fixture_root / f"workflow-{version}.zip")
        text = review.inner_text(timeout=5000)
        if "Unverified publisher" not in text or "process.build" not in text:
            raise AssertionError("normal unsigned community approval was not shown")
        review.get_by_role("button", name=re.compile(r"Program declaration \(\d+\)")).click(timeout=5000)
        programs = json.loads(review.locator("pre").inner_text(timeout=5000))
        if not any(row.get("kind") == "buildSystem" for row in programs):
            raise AssertionError("review omitted complete canonical build program")
        if cancel:
            self.driver.cancel_review(self.page, review)
            if self.catalog():
                raise AssertionError("cancelled install changed the catalog")
            return
        self.driver.confirm_review(self.page, review)
        self.wait(lambda: (row := self.catalog()) and row.get("status") == "accepted"
                  and row.get("version") == version, "accepted complete package")
        self.version = version
        self.manifest = declaration(version)
        self.check_package("installed-" + version)

    def check_package(self, name):
        root = self.args.app_local_data / "plugins" / PLUGIN_ID / self.version
        verify_installed_archive(root, self.args.fixture_root / f"workflow-{self.version}.zip",
                                 self.args.artifact_root / (name + "-package.json"))

    def build(self):
        self.driver.close_settings(self.page)
        region = self.page.get_by_role("region", name="Workflow Provider", exact=True)
        if not region.count() or not region.is_visible():
            self.page.get_by_role("button", name="Workflow Provider", exact=True).click(timeout=10000)
        region.wait_for(state="visible", timeout=10000)
        return region

    def model(self):
        region = self.build()
        button = region.get_by_role("button", name="Load model…", exact=True)
        declined_offset = len(self.calls())
        button.click(timeout=10000)
        self.approved(lambda: region.get_by_role("status").filter(has_text="Model loading declined").count(),
                      "declined model review returned ownership", decline=True)
        if self.settled("declarative_plugins_build_load_model", declined_offset):
            raise AssertionError("declined model review executed the Provider")
        self.load_model()

    def load_model(self):
        region = self.build()
        offset = len(self.calls())
        region.get_by_role("button", name=re.compile(r"^(Load|Reload) model…$"), exact=True).click(timeout=10000)
        row = self.approved(lambda: self.settled("declarative_plugins_build_load_model", offset), "real Core Provider model")
        if row.get("error") or not row.get("value"):
            raise AssertionError(f"Provider model failed: {row}")
        self.driver.write_json(self.args.artifact_root / ("provider-model-" + self.version + ".json"), row)

    def choose(self, region, name, option):
        region.get_by_role("combobox", name=name, exact=True).click(timeout=5000)
        selected = self.page.get_by_role("option", name=option, exact=True)
        selected.wait_for(state="visible", timeout=5000)
        selected.press("Enter", timeout=5000)
        self.wait(lambda: not selected.count() or not selected.is_visible(), "selector keyboard choice closed")

    def tasks(self):
        receipts = []
        for action, scope in (("build / Build", "Workspace"), ("build / Build", "Project"),
                              ("build / Build", "Target"), ("Tests", "Project"), ("Tests", "Target")):
            # Task outputs may invalidate the model through normal workspace
            # watching. Explicitly reload through approval before selecting IDs.
            self.load_model()
            region = self.build().get_by_role("region", name="Tasks and tests", exact=True)
            self.choose(region, "Action", action)
            self.choose(region, "Scope", scope)
            if scope != "Workspace":
                self.choose(region, "Project", "Workflow project (.)")
            if scope == "Target":
                self.choose(region, "Target", "Workflow tests [test]")
            if action == "Tests":
                region.get_by_role("textbox", name="Test suite filter", exact=True).fill("fixture.Suite", timeout=5000)
                region.get_by_role("textbox", name="Test case filter", exact=True).fill("fails", timeout=5000)
            offset = len(self.calls())
            region.get_by_role("button", name="Prepare task / test…", exact=True).click(timeout=10000)
            row = self.approved(lambda: self.settled("declarative_plugins_build_execute_run", offset), "real task/test dispatch")
            if row.get("error"):
                raise AssertionError(f"task/test failed: {row}")
            operation = row["args"]["operationId"]
            self.wait(lambda: any(event.get("operationId") == operation and event.get("type") == "terminal"
                                 for event in read(self.page, "() => window.__litheSettingsAcceptance.snapshot().events")),
                      "ordered native task/test terminal")
            snapshot = read(self.page, "() => window.__litheSettingsAcceptance.snapshot()")
            if snapshot["dropped"] or snapshot["errors"]:
                raise AssertionError("native task/test observation lost evidence")
            receipt = run_receipt(snapshot["calls"][offset:], snapshot["events"], action, scope, self.workspace)
            if action == "Tests":
                summary = self.page.locator("[data-slot='build-output-tests']")
                summary.wait_for(state="visible", timeout=5000)
                if "Tests failed" not in summary.inner_text(timeout=5000):
                    raise AssertionError("Core-decoded JUnit failure is not visible in product output")
            receipts.append({"action": action, "scope": scope, "calls": snapshot["calls"][offset:], **receipt})
            self.wait(lambda: region.get_by_role("button", name="Prepare task / test…", exact=True).is_enabled(), "run owner returned idle")
        self.driver.write_json(self.args.artifact_root / "task-test-selectors.json", receipts)
        self.load_model()
        region = self.build().get_by_role("region", name="Dependencies", exact=True)
        region.get_by_role("combobox").click(timeout=5000)
        self.page.get_by_role("option", name="Workflow project", exact=True).click(timeout=5000)
        offset = len(self.calls())
        region.get_by_role("button", name="Load dependencies…", exact=True).click(timeout=10000)
        row = self.approved(lambda: self.settled("declarative_plugins_build_load_dependencies", offset), "real dependencies")
        if row.get("error") or not row.get("value", {}).get("dependencies"):
            raise AssertionError(f"dependency decoding failed: {row}")

    def panel(self, suffix):
        self.driver.close_settings(self.page)
        panel = self.page.get_by_test_id("native-plugin-panel").filter(has=self.page.get_by_text("Workflow " + suffix, exact=True))
        # Contribution commands toggle their own slot. A panel in another slot
        # can remain visible while the preceding workflow uses a list or form.
        if panel.count() and panel.is_visible():
            return panel
        offset = len(self.calls())
        self.page.keyboard.press("Control+Shift+P")
        self.page.get_by_placeholder("Type a command...", exact=True).fill("Open workflow " + suffix, timeout=5000)
        self.page.get_by_text("Open workflow " + suffix, exact=True).click(timeout=10000)
        panel.wait_for(state="visible", timeout=10000)
        native = next(w["native"] for w in self.manifest["ui"]["toolWindows"] if w["id"].endswith("." + suffix))
        if native.get("source"):
            def loaded():
                for row in self.calls()[offset:]:
                    value = row.get("value") or {}
                    if row["command"] == "declarative_plugins_function_state" and value.get("context", {}).get("functionId") == native["source"]["function"]:
                        if value.get("phase") == "failed":
                            raise AssertionError(str(value.get("error")))
                        if value.get("phase") == "succeeded":
                            return not panel.get_by_role("button", name="Cancel", exact=True).count()
                return False
            self.approved(loaded, "real Core source settled")
        if panel.get_by_role("alert").count():
            raise AssertionError(panel.get_by_role("alert").inner_text(timeout=5000))
        return panel

    def action(self, panel, suffix, action_id, *, error=False):
        native = next(w["native"] for w in self.manifest["ui"]["toolWindows"] if w["id"].endswith("." + suffix))
        declaration = next(a for a in native["actions"] if a["id"] == action_id)
        offset = len(self.calls())
        panel.get_by_role("treeitem" if suffix == "tree" else "option").first.click(button="right", timeout=5000)
        self.page.get_by_role("menuitem", name=declaration["title"], exact=True).click(timeout=5000)
        def completed():
            for row in self.calls()[offset:]:
                value = row.get("value") or {}
                if (row["command"] == "declarative_plugins_function_state"
                        and value.get("context", {}).get("functionId") == declaration["function"]
                        and value.get("phase") in ("succeeded", "failed")):
                    if (value["phase"] == "failed") != error:
                        raise AssertionError(f"unexpected native action result: {value}")
                    return True
            return False
        self.approved(completed, "native action " + action_id)

    def reset(self, panel):
        offset = len(self.calls())
        panel.get_by_role("button", name="Reset native panel state", exact=True).click(timeout=5000)
        self.approved(lambda: any(row["command"] == "declarative_plugins_function_state"
                                 and (row.get("value") or {}).get("phase") == "succeeded"
                                 for row in self.calls()[offset:])
                      and not panel.get_by_role("button", name="Cancel", exact=True).count()
                      and not panel.get_by_role("alert").count(), "reset source completed")

    def refresh_after_settings_change(self, panel, snapshot):
        offset = len(self.calls())
        panel.get_by_role("button", name="Reset native panel state", exact=True).click(timeout=5000)
        self.wait(lambda: self.settled("declarative_plugins_native_function_prepare", offset),
                  "old native settings receipt rejected")
        expired = settings_conflict_receipt(self.calls()[offset:])
        panel.get_by_role("alert").wait_for(state="visible", timeout=5000)
        retry_offset = len(self.calls())
        # Only this explicit product retry may replace the stale registration.
        panel.get_by_role("button", name="Retry", exact=True).click(timeout=5000)
        self.approved(lambda: any(row["command"] == "declarative_plugins_function_state"
                                 and (row.get("value") or {}).get("phase") == "succeeded"
                                 for row in self.calls()[retry_offset:])
                      and not panel.get_by_role("button", name="Cancel", exact=True).count()
                      and not panel.get_by_role("alert").count(), "fresh native settings receipt completed")
        calls = self.calls()[retry_offset:]
        opened = [row for row in calls if row["command"] == "declarative_plugins_native_function_open" and row.get("settled")]
        if (len(opened) != 1 or opened[0].get("error")
                or opened[0].get("value", {}).get("settingIdentity") != snapshot["identity"]
                or opened[0].get("value", {}).get("packageIdentity") != snapshot["packageIdentity"]
                or opened[0]["value"]["bindingId"] == expired["args"]["request"]["bindingId"]):
            raise AssertionError("explicit Retry did not register the exact saved settings/package revision")
        closed = [row for row in calls if row["command"] == "declarative_plugins_native_function_close"
                  and row.get("args", {}).get("bindingId") == expired["args"]["request"]["bindingId"]]
        if len(closed) != 1 or not closed[0].get("settled") or closed[0].get("error"):
            raise AssertionError("explicit Retry did not release the old native binding")
        self.driver.write_json(self.args.artifact_root / "settings-native-retry.json",
                               {"expired": expired, "retry": calls})

    def tree(self):
        panel = self.panel("tree")
        row = panel.get_by_role("treeitem").filter(has=self.page.get_by_text("Workflow root", exact=True))
        row.click(timeout=5000)
        self.action(panel, "tree", "rename")
        self.approved(lambda: panel.get_by_role("treeitem").filter(has=self.page.get_by_text("Workflow root renamed", exact=True)).count(), "same Provider state survived refresh")
        row = panel.get_by_role("treeitem").filter(has=self.page.get_by_text("Workflow root renamed", exact=True))
        if row.get_attribute("aria-selected") != "true":
            raise AssertionError("stable selected ID was not retained")
        row.press("ArrowRight", timeout=5000)
        panel.get_by_role("treeitem").filter(has=self.page.get_by_text("Workflow group", exact=True)).wait_for(state="visible", timeout=5000)

    def lists(self):
        panel = self.panel("list")
        self.action(panel, "list", "large")
        rows = panel.get_by_role("option")
        self.approved(lambda: rows.count() > 0 and "Bulk" in rows.first.inner_text(timeout=5000), "large source rendered")
        if rows.count() >= 600:
            raise AssertionError("long list mounted every row")
        rows.first.press("End", timeout=5000)
        panel.get_by_role("option", name="Bulk 599 中文", exact=True).wait_for(state="visible", timeout=5000)
        self.action(panel, "list", "empty")
        self.approved(lambda: rows.count() == 0, "empty source")

    def functions(self):
        panel = self.panel("tree")
        native = next(w["native"] for w in self.manifest["ui"]["toolWindows"] if w["id"].endswith(".tree"))
        title = next(a["title"] for a in native["actions"] if a["id"] == "fail")
        failures = sum(row["event"] == "request" and row.get("params", {}).get("functionID") == "tree.fail"
                       for row in self.backend_events())
        offset = len(self.calls())
        panel.get_by_role("treeitem").first.click(button="right", timeout=5000)
        self.page.get_by_role("menuitem", name=title, exact=True).click(timeout=5000)
        self.approved(lambda: self.settled("declarative_plugins_function_cancel", offset)
                      and not panel.get_by_role("button", name="Cancel", exact=True).count(),
                      "declined function review", decline=True)
        if failures != sum(row["event"] == "request" and row.get("params", {}).get("functionID") == "tree.fail"
                           for row in self.backend_events()):
            raise AssertionError("declined function review reached the backend")
        self.reset(panel)
        self.action(panel, "tree", "fail", error=True)
        # Reset the host UI and reload, retaining the Provider's state owner.
        self.reset(panel)
        title = next(a["title"] for a in native["actions"] if a["id"] == "slow")
        panel.get_by_role("treeitem").first.click(button="right", timeout=5000)
        self.page.get_by_role("menuitem", name=title, exact=True).click(timeout=5000)
        self.approved(lambda: panel.get_by_text("Controlled native operation waiting", exact=False).count(), "function progress before cancellation")
        request = next(row for row in reversed(self.backend_events())
                       if row["event"] == "request" and row.get("params", {}).get("functionID") == "tree.slow")
        panel.get_by_role("button", name="Cancel", exact=True).click(timeout=5000)
        self.wait(lambda: not panel.get_by_role("button", name="Cancel", exact=True).count(), "cancel exact function")
        self.wait(lambda: any(row["event"] == "cancelled" and row["pid"] == request["pid"]
                             and row["id"] == request["id"] for row in self.backend_events()),
                  "peer acknowledged cancellation before its watchdog")
        self.reset(panel)
        following = next(row for row in reversed(self.backend_events())
                         if row["event"] == "request" and row.get("params", {}).get("functionID") == "tree.nodes")
        if following["pid"] != request["pid"]:
            raise AssertionError("function cancellation restarted the shared Provider")

    def form(self):
        panel = self.panel("form")
        native = next(w["native"] for w in self.manifest["ui"]["toolWindows"] if w["id"].endswith(".form"))
        controls = native["controls"]
        expected = {control["id"]: control["value"] for control in controls}
        receipts = []

        def group(control):
            return panel.locator(".plugin-native-grid > *").nth(controls.index(control))

        def field(control):
            container = group(control)
            return (container.get_by_role("checkbox", name=control["label"], exact=True)
                    if control["kind"] == "checkbox" else container.get_by_label(control["label"], exact=True))

        def committed(description, action):
            offset = len(self.calls())
            action()
            def completed():
                submitted = refreshed = False
                for row in self.calls()[offset:]:
                    value = row.get("value") or {}
                    if (row["command"] == "declarative_plugins_function_state"
                            and value.get("context", {}).get("functionId") == "form.changed"):
                        if value.get("phase") == "failed":
                            raise AssertionError(str(value.get("error")))
                        if value.get("phase") == "succeeded":
                            if json.loads(value["result"]["message"]) != expected:
                                raise AssertionError("form invocation did not carry all current typed values")
                            submitted = True
                    if (row["command"] == "declarative_plugins_function_state"
                            and value.get("context", {}).get("functionId") == "form.nodes"
                            and value.get("phase") == "succeeded"):
                        refreshed = True
                return submitted and refreshed and not panel.get_by_role("button", name="Cancel", exact=True).count()
            self.approved(completed, description)
            receipts.append({"interaction": description, "values": dict(expected), "calls": self.calls()[offset:]})

        for control in native["controls"]:
            editing = field(control)
            editing.wait_for(state="visible", timeout=5000)
            if control.get("enabled") is False:
                targets = (group(control).locator('button[data-slot="toggle-group-item"]')
                           if control["kind"] == "segmented" else group(control).locator(
                               'input[data-setting-primary-control="true"],button[aria-label="Increase value"],button[aria-label="Decrease value"]')
                           if control["kind"] == "stepper" else editing)
                if not targets.count() or any(target.is_enabled() for target in targets.all()):
                    raise AssertionError("disabled native field is editable")
        by_id = {control["id"]: control for control in controls}
        name = by_id["name"]
        # Unicode text insertion checks transport only; it is never IME evidence.
        expected["name"] = "中文 workflow"
        field(name).fill(expected["name"], timeout=5000)
        committed("input Enter commits full values", lambda: field(name).press("Enter", timeout=5000))
        expected["query"] = "workflow argument"
        field(by_id["query"]).fill(expected["query"], timeout=5000)
        committed("second input commits full values", lambda: field(by_id["query"]).press("Enter", timeout=5000))
        expected["notes"] = "中文 draft\nsecond line"
        field(by_id["notes"]).fill(expected["notes"], timeout=5000)
        expected["offline"] = not expected["offline"]
        field(by_id["offline"]).click(timeout=5000)
        environment = by_id["environment"]["options"][1]
        expected["environment"] = environment["id"]
        def choose_environment():
            field(by_id["environment"]).click(timeout=5000)
            self.page.get_by_role("option", name=environment["label"], exact=True).click(timeout=5000)
        committed("select includes editor and checkbox drafts", choose_environment)
        expected["notify"] = not expected["notify"]
        committed("checkbox pointer preserves boolean type", lambda: field(by_id["notify"]).click(timeout=5000))
        expected["search"] = "workflow 查询"
        search = field(by_id["search"])
        search.click(timeout=5000)
        search.press("Control+A", timeout=5000)
        search.press_sequentially("workflow keyboard", timeout=5000)
        expected["search"] = "workflow keyboard"
        if not search.evaluate("element => element === document.activeElement"):
            raise AssertionError("search keyboard input lost focus before Enter")
        committed("search Enter commits full values", lambda: field(by_id["search"]).press("Enter", timeout=5000))
        mode = by_id["mode"]["options"][0]
        expected["mode"] = mode["id"]
        committed("segmented pointer commits option ID", lambda: group(by_id["mode"]).get_by_role("button", name=mode["label"], exact=True).click(timeout=5000))
        expected["concurrency"] += by_id["concurrency"]["step"]
        committed("stepper pointer preserves numeric type", lambda: group(by_id["concurrency"]).get_by_role("button", name="Increase value", exact=True).click(timeout=5000))
        button = next(button for button in native["buttons"] if button.get("enabled") is not False
                      and any(action["id"] == button["action"] and action.get("function") == "form.changed" for action in native["actions"]))
        committed("explicit button submits complete current form", lambda: panel.get_by_role("button", name=button["label"], exact=True).click(timeout=5000))
        self.driver.write_json(self.args.artifact_root / "form-controls.json", receipts)
        self.panel("empty")  # Replace the same bottom slot, then restore it.
        panel = self.panel("form")
        if field(name).input_value(timeout=5000) != expected["name"]:
            raise AssertionError("same-slot replacement lost persisted form values")
        geometry = []
        for placement in ("left", "right", "bottom"):
            # Use the real contribution context menu; no store mutation or
            # synthetic resize. Side slots exercise the actual narrow layout.
            self.page.get_by_role("button", name="Workflow form", exact=True).click(button="right", timeout=5000)
            self.page.get_by_role("menuitem", name=placement, exact=True).click(timeout=5000)
            panel = self.panel("form")
            slot = self.page.locator(f"[data-native-tool-window-slot='{placement}']")
            slot.get_by_test_id("native-plugin-panel").wait_for(state="visible", timeout=5000)
            if field(name).input_value(timeout=5000) != expected["name"]:
                raise AssertionError("cross-slot movement lost persisted form values")
            layout = panel.locator(".plugin-native-grid").evaluate("element => ({width: element.getBoundingClientRect().width, columns: getComputedStyle(element).gridTemplateColumns, theme: document.documentElement.dataset.theme})")
            if layout["width"] < 640 and len(layout["columns"].split()) != 1:
                raise AssertionError("narrow native form did not use a single column")
            geometry.append({"placement": placement, **layout})
            self.page.screenshot(path=str(self.args.artifact_root / ("form-" + placement + ".png")), timeout=10000)
        panel.hover(timeout=5000)
        panel.get_by_role("button", name="Close native plugin panel", exact=True).click(timeout=5000)
        trigger = self.page.get_by_role("button", name="Workflow form", exact=True)
        if not trigger.evaluate("element => element === document.activeElement"):
            raise AssertionError("closing the native panel did not restore contribution focus")
        trigger.press("Enter", timeout=5000)
        panel = self.panel("form")
        if field(name).input_value(timeout=5000) != expected["name"]:
            raise AssertionError("keyboard reopen lost persisted form values")
        self.driver.write_json(self.args.artifact_root / "form-docking-focus.json", geometry)
        for suffix in ("static-tree", "static-list", "buttons"):
            self.panel(suffix)

    def settings(self):
        details = self.details()
        details.get_by_role("tab", name=re.compile(r"^Settings(?:\s|\d|$)")).click(timeout=5000)
        editor = details.locator(f"[data-plugin-settings='{PLUGIN_ID}']")
        before = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        row = editor.locator("[data-plugin-setting='globalMessage']")
        row.get_by_role("textbox").fill("discarded", timeout=5000)
        row.get_by_role("button", name=re.compile(r": Cancel$")).click(timeout=5000)
        after = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        if before != after:
            raise AssertionError("cancelling settings wrote a value")
        row.get_by_role("textbox").fill("confirmed-global", timeout=5000)
        offset = len(self.calls())
        row.get_by_role("button", name=re.compile(r": Save$")).click(timeout=5000)
        call = self.wait(lambda: self.settled("declarative_plugins_store_setting", offset), "explicit global save")
        if call.get("error"):
            raise AssertionError(str(call))
        saved = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        if saved["globalValues"].get("globalMessage") != "confirmed-global":
            raise AssertionError("saved global setting was not read back")
        action = editor.locator("[data-plugin-function-action='inspect']")
        offset = len(self.calls())
        started = time.monotonic()
        action.get_by_role("button", name="Inspect workflow", exact=True).click(timeout=5000)
        prepared = self.wait(lambda: self.settled("declarative_plugins_function_prepare", offset), "settings function review")
        if prepared.get("error"):
            raise AssertionError(str(prepared))
        operation = prepared["value"]["context"]["operationId"]
        observation = {"reviewContext": prepared["value"]["context"], "savedIdentity": saved["identity"]}
        try:
            action.get_by_role("button", name="Confirm and run", exact=True).click(timeout=10000)
            def completed():
                receipt = function_receipt(self.calls()[offset:], operation)
                return receipt and action.locator("pre").filter(has_text="Workflow inspect succeeded").count()
            self.wait(completed, "real settings function result and cleanup receipt")
        finally:
            observation["durationMs"] = round((time.monotonic() - started) * 1000, 3)
            observation["calls"] = [{key: row.get(key) for key in ("command", "args", "settled", "error", "value")}
                                    for row in self.calls()[offset:]
                                    if row["command"] != "declarative_plugins_function_prepare"]
            self.driver.write_json(self.args.artifact_root / "settings-function-observation.json", observation)
        # Effect variants are in the complete package. Full reload/restart
        # acceptance remains a separate pending row until its lane passes.

    def two_windows(self):
        with self.page.context.expect_page(timeout=30000) as opened:
            self.driver.invoke(self.page, "create_app_window", {"request": {"type": "directory", "path": str(self.args.fixture_root / "two")}})
        self.second = opened.value
        self.second.wait_for_load_state("domcontentloaded", timeout=15000)
        self.driver.finish_onboarding(self.second)
        self.second.evaluate(OBSERVER, OBSERVER_OPTIONS)
        self.observed.append(self.second)
        self.details(self.second).get_by_role("tab", name=re.compile(r"^Settings(?:\s|\d|$)")).click(timeout=5000)
        first = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        second = self.driver.invoke(self.second, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.args.fixture_root / "two")})
        if first["globalValues"] != second["globalValues"]:
            raise AssertionError("global settings differed across product windows")
        self.driver.write_json(self.args.artifact_root / "two-windows.json", {"first": first, "second": second})

    def setting_editor(self, scope="global"):
        details = self.details()
        details.get_by_role("tab", name=re.compile(r"^Settings(?:\s|\d|$)")).click(timeout=5000)
        editor = details.locator(f"[data-plugin-settings='{PLUGIN_ID}']")
        editor.get_by_role("combobox").click(timeout=5000)
        self.page.get_by_role("option", name="this workspace" if scope == "project" else "all workspaces",
                              exact=True).click(timeout=5000)
        return editor

    def save_setting(self, setting, value, scope="global"):
        editor = self.setting_editor(scope)
        row = editor.locator(f"[data-plugin-setting='{setting}']")
        row.get_by_role("textbox").fill(value, timeout=5000)
        offset = len(self.calls())
        row.get_by_role("button", name=re.compile(r": Save$")).click(timeout=5000)
        call = self.wait(lambda: self.settled("declarative_plugins_store_setting", offset), "save " + setting)
        if call.get("error"):
            raise AssertionError(str(call))
        self.wait(lambda: row.get_by_role("textbox").is_enabled(), "setting effect settled")
        if editor.get_by_role("alert").count():
            raise AssertionError(editor.get_by_role("alert").inner_text(timeout=5000))
        snapshot = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot",
                                     {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        if snapshot["projectValues" if scope == "project" else "globalValues"].get(setting) != value:
            raise AssertionError("setting did not read back from its saved scope")
        return snapshot

    def setting_action(self, action_id, message):
        editor = self.setting_editor()
        action = editor.locator(f"[data-plugin-function-action='{action_id}']")
        declaration = next(item for item in self.manifest["settingActions"] if item["id"] == action_id)
        offset = len(self.calls())
        action.get_by_role("button", name=declaration["title"], exact=True).click(timeout=5000)
        prepared = self.wait(lambda: self.settled("declarative_plugins_function_prepare", offset), "settings action review")
        if prepared.get("error"):
            raise AssertionError(str(prepared))
        operation = prepared["value"]["context"]["operationId"]
        action.get_by_role("button", name="Confirm and run", exact=True).click(timeout=5000)
        receipt = self.wait(lambda: function_receipt(self.calls()[offset:], operation), "settings action terminal")
        action.locator("pre").filter(has_text=message).wait_for(state="visible", timeout=5000)
        self.driver.write_json(self.args.artifact_root / (self.version + "-action-" + action_id + ".json"),
                               {"review": prepared, "terminal": receipt, "calls": self.calls()[offset:]})

    def shared_provider(self):
        self.preserve_backend("before-shared-upgrade")
        self.install("1.1.0")
        self.load_model()  # Real model approval authorizes the existing editor owner.
        self.tree()
        self.functions()  # Cancels only its own request, then refreshes the same peer.
        self.setting_action("inspect", "Workflow inspect succeeded")
        self.setting_action("withdraw", "Workflow rename withdrawn")
        panel = self.panel("tree")
        native = next(w["native"] for w in self.manifest["ui"]["toolWindows"] if w["id"].endswith(".tree"))
        title = next(a["title"] for a in native["actions"] if a["id"] == "rename")
        before = sum(row.get("params", {}).get("functionID") == "tree.rename" for row in self.backend_events())
        offset = len(self.calls())
        panel.get_by_role("treeitem").first.click(button="right", timeout=5000)
        self.page.get_by_role("menuitem", name=title, exact=True).click(timeout=5000)
        self.approved(lambda: panel.get_by_role("alert").count(), "withdrawn function is rejected")
        if before != sum(row.get("params", {}).get("functionID") == "tree.rename" for row in self.backend_events()):
            raise AssertionError("withdrawn function reached the backend")
        self.driver.write_json(self.args.artifact_root / "withdrawn-function.json", self.calls()[offset:])
        self.setting_action("restore", "Workflow rename restored")
        panel = self.panel("tree")
        self.reset(panel)
        self.action(panel, "tree", "rename")
        rows = self.backend_events()
        starts = [row for row in rows if row["event"] == "started" and "1.1.0" in row.get("argv", [])
                  and row["workspace"].lower() == str(self.workspace).lower()]
        shared_pids = {row["pid"] for row in starts}
        requests = [row for row in rows if row["event"] == "request" and row["pid"] in shared_pids]
        methods = {row.get("params", {}).get("functionID") for row in requests}
        if len(shared_pids) != 1 or not {"tree.rename", "tree.nodes", "tree.slow", "buttons.inspect"} <= methods:
            raise AssertionError("native and settings functions did not borrow exactly one authorized language process")
        registrations = [row for row in rows if row["event"] == "registration" and row["pid"] in shared_pids]
        if len(registrations) != 2 or any(row.get("error") for row in registrations):
            raise AssertionError("Core did not acknowledge withdrawal and re-registration")
        self.driver.write_json(self.args.artifact_root / "shared-provider.json", {"pids": sorted(shared_pids),
                               "requests": requests, "registrations": registrations})

    def settings_effects(self):
        rows = self.backend_events()
        starts = [row for row in rows if row["event"] == "started" and "1.1.0" in row.get("argv", [])]
        pid = starts[-1]["pid"]
        offset = len(rows)
        snapshot = self.save_setting("immediateMessage", "immediate-applied", "project")
        updated = self.wait(lambda: next((row for row in self.backend_events()[offset:]
            if row["event"] == "request" and row.get("method") == "workspace/didChangeConfiguration"
            and row.get("params", {}).get("settings", {}).get("workflow", {}).get("message") == "immediate-applied"), None),
            "shared language configuration notification")
        if updated["pid"] != pid:
            raise AssertionError("immediate setting replaced the editor owner")
        panel = self.panel("tree")
        self.refresh_after_settings_change(panel, snapshot)
        self.action(panel, "tree", "rename")
        self.setting_action("inspect", "Workflow inspect succeeded")
        following = [row for row in self.backend_events()[offset:] if row["event"] == "request"
                     and row.get("params", {}).get("functionID") in ("tree.nodes", "tree.rename", "buttons.inspect")]
        if not {"tree.nodes", "tree.rename", "buttons.inspect"} <= {row["params"]["functionID"] for row in following} or any(row["pid"] != pid for row in following):
            raise AssertionError("functions after immediate configuration did not retain the same language owner")
        # First prove the ordinary reload keeps its existing same-language semantics.
        self.reload_project("before-restart", restart_required=False)
        retained = [row for row in self.backend_events() if row["event"] == "started" and "1.1.0" in row.get("argv", [])]
        if retained[-1]["pid"] != pid:
            raise AssertionError("ordinary model reload replaced the language owner")
        # Deliberately compose restart-save BEFORE model-only reload. The R37
        # reverse order passed but did not exercise changed startup identity.
        offset = len(self.backend_events())
        saved_restart = self.save_setting("restartMessage", "restart-on-next-start")
        if any(row["event"] == "started" for row in self.backend_events()[offset:]):
            raise AssertionError("restart setting silently restarted a process")
        reload_model = self.reload_project("after-restart", restart_required=True)
        starts = [row for row in self.backend_events() if row["event"] == "started" and "1.1.0" in row.get("argv", [])]
        if starts[-1]["pid"] != pid or "restart-on-next-start" in starts[-1]["argv"]:
            raise AssertionError("model-only project reload changed the language startup identity")
        stored = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        if stored["globalValues"].get("restartMessage") != "restart-on-next-start":
            raise AssertionError("failed model reload lost the saved restart value")
        self.driver.write_json(self.args.artifact_root / "settings-effects.json", {"immediate": updated, "followingFunctions": following,
            "reload": reload_model, "retainedStart": starts[-1], "savedRestartIdentity": saved_restart["identity"],
            "restartStillSaved": stored["globalValues"]["restartMessage"]})
        self.restart_pid = pid
        self.check_package("after-settings-effects")

    def reload_project(self, value, *, restart_required):
        self.save_setting("reloadMessage", value, "project")
        notice = self.page.locator(f"[data-plugin-reload='{PLUGIN_ID}'][data-plugin-reload-scope='project']")
        notice.wait_for(state="visible", timeout=5000)
        offset = len(self.calls())
        self.preserve_backend("before-project-reload-" + value)
        notice.locator("[data-plugin-reload-confirm]").click(timeout=5000)
        self.approved(lambda: self.settled("declarative_plugins_build_load_model", offset),
                      "project reload model approved and settled")
        receipt = project_reload_receipt(self.calls()[offset:], restart_required=restart_required)
        if restart_required:
            notice.get_by_role("alert").filter(has_text="Saved settings require a plugin restart.").wait_for(timeout=5000)
            # This failed model attempt did not revoke the live editor. Explicit
            # Later retires only its receipt before Disable/Enable recovery.
            notice.locator("[data-plugin-reload-postpone]").click(timeout=5000)
            notice.wait_for(state="detached", timeout=5000)
        else:
            notice.wait_for(state="detached", timeout=5000)
        self.driver.write_json(self.args.artifact_root / ("project-reload-" + value + ".json"), receipt)
        return receipt

    def lifecycle(self):
        for action in ("Disable", "Enable"):
            self.details().get_by_role("button", name=action, exact=True).click(timeout=5000)
            self.wait(lambda: self.catalog()["enabled"] == (action == "Enable"), action)
            self.check_package(action.lower())
        self.load_model()
        self.setting_action("inspect", "Workflow inspect succeeded")
        starts = [row for row in self.backend_events() if row["event"] == "started"
                  and "1.1.0" in row.get("argv", [])
                  and row["workspace"].lower() == str(self.workspace).lower()]
        if starts[-1]["pid"] == self.restart_pid or "restart-on-next-start" not in starts[-1]["argv"]:
            raise AssertionError("explicit next language start did not read saved restart settings")
        self.driver.write_json(self.args.artifact_root / "settings-restart.json",
                               {"previousPid": self.restart_pid, "newStart": starts[-1]})
        self.preserve_backend("before-uninstall")
        self.details().get_by_role("button", name="Uninstall", exact=True).click(timeout=5000)
        self.wait(lambda: self.catalog() is None, "uninstall")
        if (self.args.app_local_data / "plugins" / PLUGIN_ID).exists():
            raise AssertionError("uninstalled package retained")

    def native_review(self):
        if os.environ.get("LITHE_NATIVE_WORKFLOW_REVIEW") != "1":
            return
        # External native input has a separate bounded checkpoint. Releasing
        # this gate proves no visual/IME claim; those need their own evidence.
        self.driver.write_json(self.args.artifact_root / "native-review-ready.json",
                               {"pid": self.session.process.pid, "workspace": str(self.workspace),
                                "timeoutSeconds": 180, "automaticVisualPass": False})
        self.driver.wait_until(lambda: (self.args.artifact_root / "native-review-continue").is_file(),
                               180, "bounded native Computer Use checkpoint")

    def run(self):
        from playwright.sync_api import sync_playwright
        resources = snapshot_resources(self.args.run_image)
        self.driver.write_json(self.args.artifact_root / "resources-before.json", resources)
        playwright = sync_playwright().start()
        try:
            # Keep Playwright alive until AppSession completes native quit.
            with self.reporter.step(CASES[0]):
                plan = load_plan(self.args.fixture_root)
                identity = verify_host(self.args.host_identity, self.args.executable, plan)
                if (identity.get("sourceInventory") != source_inventory()
                        or identity.get("configSha256") != sha256(self.args.host_identity.with_name("tauri.host-acceptance.conf.json"))):
                    raise ValueError("frozen build source inventory changed")
                missing = missing_capabilities(REQUIRES, source_capabilities())
                if missing:
                    raise RuntimeError("complete package remains gated: " + ", ".join(missing))
                self.args.app_roaming_data.mkdir(parents=True)
                self.driver.write_json(self.args.app_roaming_data / "settings.json", {"displayLanguage": "en-US"})
                self.args.webview_data.mkdir(parents=True)
                self.session = self.driver.AppSession(playwright, self.args.executable, self.workspace,
                                                     self.args.webview_data, self.args.artifact_root / "logs", 1)
                self.reporter.capture_failure = self.capture_failure
                self.page = self.session.start()
                self.driver.finish_onboarding(self.page)
                self.page.evaluate(OBSERVER, OBSERVER_OPTIONS)
                self.observed.append(self.page)
                self.install("1.0.0", cancel=True)
                self.install("1.0.0")
            for name, action in zip(CASES[1:-1], (self.model, self.tasks, self.tree, self.lists,
                    self.functions, self.form, self.settings, self.two_windows,
                    self.shared_provider, self.settings_effects, self.lifecycle)):
                with self.reporter.step(name):
                    action()
                    self.page.screenshot(path=str(self.args.artifact_root / (name + ".png")), timeout=10000)
                if action == self.form:
                    self.native_review()
            # Restore the actual transport before the original native quit.
            for index, page in enumerate(self.observed):
                final = read(page, "() => window.__litheSettingsAcceptance.stop()")
                self.driver.write_json(self.args.artifact_root / f"ipc-{index}.json", final)
                if final["pending"] or final["dropped"] or final["errors"] or final["callbackWrappersRetained"] or not final["originalInvokeRestored"]:
                    raise AssertionError("native observer did not drain/restore")
        finally:
            with self.reporter.step(CASES[-1]):
                try:
                    try:
                        self.preserve_backend("before-quit")
                        self.driver.write_json(self.args.artifact_root / "backend-events.json", self.saved_backend_events)
                    finally:
                        cleanup = cleanup_session(self.args, self.driver, self.session)
                        self.driver.write_json(self.args.artifact_root / "cleanup.json", cleanup)
                finally:
                    playwright.stop()
                after = snapshot_resources(self.args.run_image)
                self.driver.write_json(self.args.artifact_root / "resources-after.json", after)
                assert_resources(resources, after)
                load_plan(self.args.fixture_root)  # Recheck original archive bytes.
                if cleanup["survivors"] or cleanup["errors"] or not cleanup["profilesAbsent"]:
                    raise AssertionError("native session cleanup could not be proven")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    paths = ("host-identity", "executable", "run-image", "artifact-root", "app-local-data", "app-roaming-data", "webview-data")
    for name in paths:
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.absolute())
    plan = load_plan(args.fixture_root)
    if args.preflight:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes(json_bytes({"runner": "acceptance", "warnMs": 30000, "maxMs": 120000,
                                          **preflight(plan, source_capabilities())}))
        return 2
    if any(getattr(args, name.replace("-", "_")) is None for name in paths):
        parser.error("runtime requires source-bound isolated image, identity, evidence and profiles")
    runtime_paths(args)
    if not args.worker:
        from vcs_move_diagnostic import WindowsJob, cleanup_proven, supervised
        args.report.parent.mkdir(parents=True, exist_ok=True)
        result = supervised([sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:], "--worker"],
                            900, args.report.with_suffix(".worker.log"), WindowsJob)
        report = json.loads(args.report.read_text(encoding="utf-8")) if args.report.exists() else {
            "runner": "acceptance", "complete": False, "controlledSubsetPassed": False,
            "warnMs": 30000, "maxMs": 120000, "tests": pending_rows("Worker did not complete.")}
        report["tests"].append({"name": "native workflow suite owner", "status": result["status"],
                                "durationMs": result["durationMs"], "maxMs": 900000, "details": str(result)})
        (args.artifact_root / "worker-owner.json").write_bytes(json_bytes(result))
        if result["status"] != "passed" or not cleanup_proven(result):
            report["controlledSubsetPassed"] = False
        args.report.write_bytes(json_bytes(report))
        return 0 if report["controlledSubsetPassed"] else 1
    import acceptance_driver as driver
    if (args.app_local_data.resolve() != Path(os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.app_roaming_data.resolve() != Path(os.environ["APPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.webview_data.name != "webview2"):
        parser.error("unexpected isolated profile identity")
    if any(path.exists() for path in (args.artifact_root, args.app_local_data, args.app_roaming_data, args.webview_data)):
        parser.error("run-owned evidence and profiles must be absent")
    reporter = driver.Reporter(args.artifact_root / "progress.json")
    workflow = Workflow(args, driver, reporter)
    code = 0
    try:
        workflow.run()
    except Exception as error:
        print(f"{type(error).__name__}: {error}", flush=True)
        code = 1
    finally:
        completed = {row["name"] for row in reporter.tests}
        reporter.tests.extend(row for row in pending_rows("Not reached; preserve the first failing stage.") if row["name"] not in completed)
        for name, reason in PENDING.items():
            reporter.document_pending(name, reason)
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30000, "maxMs": 120000,
                          "runtimeExecuted": bool(workflow.session and workflow.session.process),
                          "complete": False, "controlledSubsetPassed": code == 0, "tests": reporter.tests})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
