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
from settings_functions_acceptance import (OBSERVER, assert_resources, snapshot_resources,
                                          sha256, verify_host, verify_installed_archive)
from text_window_fixture import source_inventory

CASES = ("source-and-install-review", "provider-model", "task-test-dependencies",
         "tree-state-and-selection", "list-long-empty", "function-progress-cancel-error",
         "form-controls-and-restore", "settings-explicit-save-cancel", "two-window-global-settings",
         "replace-disable-uninstall", "quit-and-resource-invariance")
PENDING = {
    "real-ime-and-native-focus": "Real Chinese IME composition, candidate windows, native hierarchy and window activation need human observation; DOM events are insufficient.",
    "theme-narrow-docking": "Dark/light visual geometry, narrow docking and cross-slot drag/restore need native manual acceptance.",
    "full-version-contract": "Shared-language Provider, all execution selectors, dynamic function withdrawal, settings reload/restart and cleanup-failure retry require their full product lanes before capability admission.",
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


class Workflow:
    def __init__(self, args, driver, reporter):
        self.args, self.driver, self.reporter = args, driver, reporter
        self.page = self.session = self.second = None
        self.version = "1.0.0"
        self.workspace = args.fixture_root / "one"
        self.manifest = declaration(self.version)
        self.observed = []
        self.deadline = time.monotonic() + 480

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
        self.wait(lambda: self.catalog() and self.catalog().get("status") == "accepted", "accepted complete package")
        self.version = version
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
        self.driver.write_json(self.args.artifact_root / "provider-model.json", row)

    def choose(self, region, name, option):
        region.get_by_role("combobox", name=name, exact=True).click(timeout=5000)
        self.page.get_by_role("option", name=option, exact=True).click(timeout=5000)

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
            receipts.append({"action": action, "scope": scope, "calls": self.calls()[offset:]})
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
        field(by_id["search"]).fill(expected["search"], timeout=5000)
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
        action.get_by_role("button", name="Inspect workflow", exact=True).click(timeout=5000)
        action.get_by_role("button", name="Confirm and run", exact=True).click(timeout=10000)
        self.wait(lambda: action.locator("pre").filter(has_text="Workflow inspect succeeded").count(), "real settings function result")
        # Effect variants are in the complete package. Full reload/restart
        # acceptance remains a separate pending row until its lane passes.

    def two_windows(self):
        with self.page.context.expect_page(timeout=30000) as opened:
            self.driver.invoke(self.page, "create_app_window", {"request": {"type": "directory", "path": str(self.args.fixture_root / "two")}})
        self.second = opened.value
        self.second.wait_for_load_state("domcontentloaded", timeout=15000)
        self.driver.finish_onboarding(self.second)
        self.second.evaluate(OBSERVER)
        self.observed.append(self.second)
        self.details(self.second).get_by_role("tab", name=re.compile(r"^Settings(?:\s|\d|$)")).click(timeout=5000)
        first = self.driver.invoke(self.page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.workspace)})
        second = self.driver.invoke(self.second, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(self.args.fixture_root / "two")})
        if first["globalValues"] != second["globalValues"]:
            raise AssertionError("global settings differed across product windows")
        self.driver.write_json(self.args.artifact_root / "two-windows.json", {"first": first, "second": second})

    def lifecycle(self):
        self.install("1.1.0")
        for action in ("Disable", "Enable"):
            self.details().get_by_role("button", name=action, exact=True).click(timeout=5000)
            self.wait(lambda: self.catalog()["enabled"] == (action == "Enable"), action)
            self.check_package(action.lower())
        self.details().get_by_role("button", name="Uninstall", exact=True).click(timeout=5000)
        self.wait(lambda: self.catalog() is None, "uninstall")
        if (self.args.app_local_data / "plugins" / PLUGIN_ID).exists():
            raise AssertionError("uninstalled package retained")

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
                self.page.evaluate(OBSERVER)
                self.observed.append(self.page)
                self.install("1.0.0", cancel=True)
                self.install("1.0.0")
            for name, action in zip(CASES[1:-1], (self.model, self.tasks, self.tree, self.lists,
                    self.functions, self.form, self.settings, self.two_windows, self.lifecycle)):
                with self.reporter.step(name):
                    action()
                    self.page.screenshot(path=str(self.args.artifact_root / (name + ".png")), timeout=10000)
            # Restore the actual transport before the original native quit.
            for index, page in enumerate(self.observed):
                final = read(page, "() => window.__litheSettingsAcceptance.stop()")
                self.driver.write_json(self.args.artifact_root / f"ipc-{index}.json", final)
                if final["pending"] or final["dropped"] or not final["originalInvokeRestored"]:
                    raise AssertionError("native observer did not drain/restore")
        finally:
            with self.reporter.step(CASES[-1]):
                try:
                    try:
                        self.driver.write_json(self.args.artifact_root / "backend-events.json", self.backend_events())
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
                            600, args.report.with_suffix(".worker.log"), WindowsJob)
        report = json.loads(args.report.read_text(encoding="utf-8")) if args.report.exists() else {
            "runner": "acceptance", "complete": False, "controlledSubsetPassed": False,
            "warnMs": 30000, "maxMs": 120000, "tests": pending_rows("Worker did not complete.")}
        report["tests"].append({"name": "native workflow suite owner", "status": result["status"],
                                "durationMs": result["durationMs"], "maxMs": 600000, "details": str(result)})
        args.report.with_suffix(".owner.json").write_bytes(json_bytes(result))
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
