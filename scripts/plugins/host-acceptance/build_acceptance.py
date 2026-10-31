#!/usr/bin/env python3
"""Opt-in real UI/IPC non-provider build acceptance; no native test backdoor.

The planning command reports closed source prerequisites without connecting to
a product. The optional acceptance_driver lane only runs on an already staged
isolated product; existing native import, signatures and approvals remain gates.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import uuid
import zipfile
from pathlib import Path

from build_fixture import COMMAND, ROOT, confined, load_plan, ordinary_tree, tool_script


SUITE = "plugin-host-acceptance / native-build"
STEPS = ("install-review", "passive-detection", "saved-model", "decline-run", "task-test-dependencies",
         "cancel-tree", "replace-late", "close-workspace", "read-only-resources", "uninstall")
OFFICIAL = "hostIntegration / official Maven model-task-test-dependencies"
SETTING_CASE = "setting / configured failure never falls back"
IDENTITY = ("operationId", "pluginId", "buildSystemId", "root", "workspaceRoot", "generation")


def source_capabilities(root: Path = ROOT) -> dict:
    source = (root / "windows/tauri/src-tauri/src/plugin_host/mod.rs").read_text(encoding="utf-8")
    match = re.search(r"pub fn host_capabilities\(\) -> Value\s*\{\s*json!\((\{.*?\})\)\s*\}", source, re.S)
    if not match:
        raise ValueError("cannot read the host's literal capability prerequisite; never infer enabled")
    return json.loads(re.sub(r",\s*([}\]])", r"\1", match[1]))


def missing_capabilities(required: dict, capabilities: dict) -> list[str]:
    return [f"{name}:{level}" for name, level in sorted(required.items()) if level not in capabilities.get(name, [])]


def planned_cases(plan: dict, capabilities: dict, official: bool = False) -> list[dict]:
    rows = []
    for variant in plan["variants"]:
        missing = missing_capabilities(variant["requires"], capabilities)
        reason = ("Closed source prerequisites: " + ", ".join(missing)) if missing else "Requires opt-in real isolated product execution"
        for step in STEPS:
            rows.append({"name": f"{variant['id']} / {step}", "suite": SUITE, "status": "skipped", "durationMs": 0,
                         "maxMs": 120_000, "details": f"{reason}. Not executed. Install through the native review; never edit installation records."})
    rows.append({"name": OFFICIAL, "suite": SUITE, "status": "skipped", "durationMs": 0, "maxMs": 120_000,
                 "details": "Not executed. " + plan["hostIntegration"]["prerequisite"] +
                 (" Official archive supplied; native validation/approval still required." if official else " No official archive supplied.")})
    rows.append({"name": SETTING_CASE, "suite": SUITE, "status": "skipped", "durationMs": 0, "maxMs": 120_000,
                 "details": "Not executed. Requires settings/executableResolution enabled and the real failed-tool UI/IPC path."})
    return rows


def record_unreached_cases(reporter, plan: dict, capabilities: dict, *, official=False, reason=None):
    completed = {test["name"] for test in reporter.tests}
    for row in planned_cases(plan, capabilities, official):
        if row["name"] not in completed:
            if reason:
                row["details"] += " " + reason
            reporter.tests.append(row)


def add_arguments(parser) -> None:
    parser.add_argument("--build-fixture-root", type=Path, help="Opt in to generated non-provider build fixtures; closed capabilities remain skipped.")
    parser.add_argument("--build-official-maven-package", type=Path, help="Optional genuine official publisher-signed Maven archive; no test signature/trust override.")


def validate_arguments(parser, args) -> None:
    if args.build_official_maven_package and not args.build_fixture_root:
        parser.error("--build-official-maven-package requires --build-fixture-root")


@contextlib.contextmanager
def tool_environment(root: Path):
    tools = confined(root, "tools with spaces/bin")
    prior = {key: os.environ.get(key) for key in ("PATH", "LITHE_ACCEPTANCE_TOOL_HOME")}
    os.environ["PATH"] = str(tools) + os.pathsep + (prior["PATH"] or "")
    os.environ["LITHE_ACCEPTANCE_TOOL_HOME"] = str(tools.parent)
    try:
        yield
    finally:
        for key, value in prior.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def events_after(workspace: Path, offset: int) -> list[dict]:
    path = workspace / ".lithe-acceptance/events.jsonl"
    if not path.exists():
        if offset:
            raise ValueError("fixture evidence disappeared after the action snapshot")
        return []
    if path.is_symlink() or path.is_junction() or path.stat().st_size < offset:
        raise ValueError("fixture evidence was replaced or truncated")
    if offset < 0 or path.stat().st_size - offset > 2 * 1024 * 1024:
        raise ValueError("fixture evidence exceeded its per-action read budget")
    with path.open("rb") as stream:
        stream.seek(offset)
        lines = stream.read().split(b"\n")[:-1]
    events = [json.loads(line) for line in lines if line]
    if any(not isinstance(row, dict) or row.get("workspace") != str(workspace) for row in events):
        raise ValueError("fixture evidence belongs to another workspace")
    return events


def event_offset(workspace: Path) -> int:
    path = workspace / ".lithe-acceptance/events.jsonl"
    return path.stat().st_size if path.exists() else 0


def fixture_command_matches(command: str, script: Path) -> bool:
    expected = str(script.resolve()).replace("\\", "/")
    normalized = command.replace("\\", "/")
    return re.search(r'(?:^|\s)"?' + re.escape(expected) + r'"?(?=\s|$)', normalized, re.I) is not None


def matching_events(events: list[dict], review: dict) -> list[dict]:
    if any(key not in review for key in IDENTITY):
        raise ValueError("review is missing its native operation identity")
    return [event for event in events if all(event.get(key) == review[key] for key in IDENTITY)]


def assert_ordered_terminal(events: list[dict], review: dict, terminal: str) -> list[dict]:
    matching = matching_events(events, review)
    terminals = [event for event in matching if event.get("type") == "terminal"]
    if len(terminals) != 1 or terminals[0].get("terminal", {}).get("kind") != terminal or matching[-1] != terminals[0]:
        raise AssertionError("expected exactly one final terminal for the complete native identity")
    return matching


class FixtureGate:
    """A workspace-owned fixture control file, never installed/package state."""
    def __init__(self, workspace: Path, action: str):
        if action not in ("model", "task", "test", "dependencies"):
            raise ValueError("invalid controlled fixture action")
        self.directory = confined(workspace, ".lithe-acceptance")
        self.token = uuid.uuid4().hex
        self.control = self.directory / "control.json"
        self.release = self.directory / f"release-{self.token}"
        self.action = action

    def __enter__(self):
        with self.control.open("x", encoding="utf-8") as stream:
            json.dump({"holdAction": self.action, "token": self.token}, stream)
        return self

    def __exit__(self, *_):
        self.release.touch(exist_ok=False)
        self.control.unlink(missing_ok=True)


# Read-only instrumentation: every original invoke, success and rejection is
# passed through unchanged. No command is replaced and no events are forged.
OBSERVER = r"""async () => {
  if (window.__litheBuildAcceptanceObserver) throw new Error('observer already active');
  const internals = window.__TAURI_INTERNALS__, original = internals.invoke;
  const state = { calls: [], events: [], dropped: 0, original };
  const push = (array, item) => { if (array.length < 8192) array.push(item); else state.dropped++; };
  const allowed = command => command.startsWith('declarative_plugins_build_') || command === 'write_file';
  internals.invoke = function(command, args, ...rest) {
    if (!allowed(command)) return original.call(this, command, args, ...rest);
    const record = {command, args, settled:false}; push(state.calls, record);
    return original.call(this, command, args, ...rest).then(value => {
      record.settled=true; record.value=value; return value;
    }, error => {record.settled=true; record.error=String(error); throw error;});
  };
  const callback = internals.transformCallback(event => push(state.events, event.payload));
  const target = {kind:'Window',label:internals.metadata.currentWindow.label};
  let timer;
  const listen = original.call(internals, 'plugin:event|listen', {event:'declarative-build-output',target,handler:callback});
  let eventId;
  try {
    eventId = await Promise.race([listen,new Promise((_,reject) => {
      timer=setTimeout(() => reject(new Error('observer listen deadline')),10000);
    })]);
  } catch (error) {
    internals.invoke=original;
    void listen.then(eventId => original.call(internals,'plugin:event|unlisten',{event:'declarative-build-output',eventId}))
      .finally(() => internals.unregisterCallback(callback)).catch(error => console.error('acceptance observer cleanup',error));
    throw error;
  } finally { clearTimeout(timer); }
  state.stop = async () => {
    internals.invoke=original;
    let timer;
    try {
      await Promise.race([original.call(internals,'plugin:event|unlisten',{event:'declarative-build-output',eventId}),
        new Promise((_,reject) => {timer=setTimeout(() => reject(new Error('observer unlisten deadline')),10000);})]);
    } finally {
      clearTimeout(timer); internals.unregisterCallback(callback);
      delete window.__litheBuildAcceptanceObserver;
    }
  };
  window.__litheBuildAcceptanceObserver=state;
}"""


class BuildAcceptance:
    def __init__(self, driver, args, reporter, restart):
        self.driver, self.args, self.reporter, self.restart = driver, args, reporter, restart
        self.root = args.build_fixture_root.resolve()
        self.plan = load_plan(self.root)
        self.capabilities = source_capabilities()
        self.evidence = args.artifact_root.resolve() / "build"
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.page = None
        self.variant = None
        self.workspace = None
        self.owned_handles = {}
        self.package_before = None
        self.native_workspace = None

    def snapshot(self):
        return self.page.evaluate("() => { const s=window.__litheBuildAcceptanceObserver; return {calls:s.calls,events:s.events,dropped:s.dropped}; }")

    def native(self, command, arguments=None):
        return self.driver.invoke(self.page, command, arguments)

    def catalog(self):
        return next((row for row in self.native("declarative_plugins_state") if row["pluginId"] == self.variant["pluginId"] and row["source"] == "installed"), None)

    def details(self):
        return self.native("declarative_plugins_details", {"pluginId": self.variant["pluginId"], "source": "installed"})

    def region(self):
        return self.page.get_by_role("region", name=self.variant["displayName"], exact=True)

    def open_build(self):
        self.driver.close_settings(self.page)
        region = self.region()
        if not region.count() or not region.is_visible():
            self.page.get_by_role("button", name=self.variant["displayName"], exact=True).click(timeout=15_000)
        region.wait_for(state="visible", timeout=15_000)
        return region

    def choose(self, scope, label, option):
        trigger = scope.get_by_role("combobox", name=label, exact=True)
        trigger.click(timeout=10_000)
        self.page.get_by_role("option", name=option, exact=True).click(timeout=10_000)

    def import_package(self, marker: str, *, cancel=False):
        asset = self.variant["archives"][marker]
        review = self.driver.import_review(self.page, self.session.process.pid, confined(self.root, asset["path"]))
        text = review.inner_text(timeout=10_000)
        if "Unverified publisher" not in text or "process.build" not in text:
            raise AssertionError("the real import review omitted trust or process.build")
        review.get_by_role("button", name=re.compile(r"Program declaration \(\d+\)")).click(timeout=10_000)
        programs = json.loads(review.locator("pre").inner_text(timeout=10_000))
        if not any(program.get("kind") == "buildSystem" for program in programs):
            raise AssertionError("native install review omitted the full build declaration")
        if cancel:
            self.driver.cancel_review(self.page, review)
        else:
            self.driver.confirm_review(self.page, review)
            self.driver.wait_until(lambda: self.catalog() and self.catalog().get("status") == "accepted", 15, "native installed build fixture")
            provenance = self.details()["versions"]["current"]
            if provenance["archiveSha256"] != asset["sha256"]:
                raise AssertionError("native install provenance differs from approved archive")
        return programs

    def installed_package(self):
        # Existing store layout, read only. Never create/edit installation.json.
        root = self.args.app_local_data / "plugins" / self.variant["pluginId"] / "1.0.0"
        if not root.is_dir():
            raise AssertionError("the native installation directory is missing")
        return root

    def uninstall(self):
        self.driver.open_plugin_settings(self.page)
        row = self.page.locator("[data-testid='declarative-plugin-list'] "
                                f"[data-plugin-id='{self.variant['pluginId']}'][data-plugin-source='installed']")
        row.get_by_role("button").click(timeout=10_000)
        details = self.page.locator("[data-settings-content='declarative-plugins']").get_by_role(
            "region", name=self.variant["displayName"], exact=True)
        details.get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
        self.driver.wait_until(lambda: self.catalog() is None, 15, "real build fixture uninstall")
        if (self.args.app_local_data / "plugins" / self.variant["pluginId"]).exists():
            raise AssertionError("native uninstall left the fixture package directory")

    def passive_view(self):
        offset = len(self.snapshot()["calls"])
        self.open_build().get_by_role("button", name="Reload", exact=True).click(timeout=10_000)
        view = self.prepared("declarative_plugins_build_refresh", offset)
        rows = [row for row in view["instances"] if row["pluginID"] == self.variant["pluginId"] and row["buildSystemID"] == self.variant["buildSystemId"]]
        if not rows:
            raise AssertionError("native detection returned no exact fixture instance")
        self.native_workspace = view["workspaceRoot"]
        return view, next(row for row in rows if row["root"] == ".")

    def prepared(self, command, call_offset):
        return self.driver.wait_until(lambda: next((row["value"] for row in self.snapshot()["calls"][call_offset:]
            if row["command"] == command and row.get("settled") and row.get("value")), None), 15, command + " native review")

    def approve(self, title, label, prepare_command, trigger, *, decline=False):
        from playwright.sync_api import expect
        offset = len(self.snapshot()["calls"])
        before = event_offset(self.workspace)
        trigger()
        dialog = self.page.get_by_role("dialog", name=title, exact=True)
        expect(dialog).to_be_visible(timeout=15_000)
        review = self.prepared(prepare_command, offset)
        for key, expected in (("pluginId", self.variant["pluginId"]), ("buildSystemId", self.variant["buildSystemId"]),
                              ("root", "."), ("workspaceRoot", str(self.workspace))):
            if (key == "workspaceRoot" and Path(review.get(key, "")).resolve() != Path(expected).resolve()) or (key != "workspaceRoot" and review.get(key) != expected):
                raise AssertionError("review belongs to another fixture/context")
            expect(dialog).to_contain_text(str(review[key]))
        if events_after(self.workspace, before):
            raise AssertionError("a project executable/probe ran before approval")
        if any(row["command"] in ("declarative_plugins_build_execute_run", "declarative_plugins_build_load_model", "declarative_plugins_build_load_dependencies")
               for row in self.snapshot()["calls"][offset:]):
            raise AssertionError("native execution was invoked before the review decision")
        dialog.get_by_role("button", name="Decline" if decline else label, exact=True).click(timeout=10_000)
        expect(dialog).to_be_hidden(timeout=15_000)
        if decline:
            self.driver.wait_until(lambda: any(row["command"] == "declarative_plugins_build_cancel_operation" and row.get("settled") for row in self.snapshot()["calls"][offset:]), 15, "declined native operation cleanup")
            if events_after(self.workspace, before):
                raise AssertionError("declining executed a fixture tool")
        return review, offset

    def terminal(self, review, kind):
        events = self.driver.wait_until(lambda: (lambda rows: rows if any(row.get("type") == "terminal" for row in rows) else None)(
            matching_events(self.snapshot()["events"], review)), 30, "matching native terminal")
        return assert_ordered_terminal(events, review, kind)

    def save_and_model(self):
        # Exercise the canonical editor and Ctrl+S. An on-disk fixture write
        # cannot stand in for the product's save-before-build sequence.
        self.driver.open_fixture_file(self.page, "acceptance.build.txt")
        editor = self.page.locator(".monaco-editor textarea.inputarea").last
        editor.focus(timeout=10_000)
        editor.press("Control+End", timeout=10_000)
        editor.press("End", timeout=10_000)
        editor.type(" accepted-through-editor", timeout=10_000)
        editor.press("Control+s", timeout=10_000)
        self.driver.wait_until(lambda: "accepted-through-editor" in (self.workspace / "acceptance.build.txt").read_text(encoding="utf-8"), 10, "the real saved editor buffer")
        region = self.open_build()
        if self.variant["id"].startswith("static"):
            region.get_by_role("button", name="Reload", exact=True).click(timeout=10_000)
        else:
            model_offset = event_offset(self.workspace)
            review, offset = self.approve("Review model loading", "Allow and load", "declarative_plugins_build_prepare_model",
                lambda: region.get_by_role("button", name=re.compile(r"^(Load|Reload) model…$")).click(timeout=10_000))
            self.driver.wait_until(lambda: any(row["command"] == "declarative_plugins_build_load_model" and row.get("settled") and "error" not in row
                                  for row in self.snapshot()["calls"][offset:]), 30, "native model loaded after approval")
            if review["operationId"] not in [row["args"].get("operationId") for row in self.snapshot()["calls"][offset:] if row["command"] == "declarative_plugins_build_load_model"]:
                raise AssertionError("model execution did not consume its reviewed identity")
            if not any(row.get("action") == "model" and "accepted-through-editor" in (row.get("savedText") or "")
                       for row in events_after(self.workspace, model_offset)):
                raise AssertionError("the approved model process did not observe the saved editor contents")
        _, row = self.current_view()
        if not row.get("model", {}).get("projects"):
            raise AssertionError("the Core-decoded native model has no projects")

    def current_view(self):
        # sync_check returns the existing model rather than discarding a
        # command model with a whole-registry re-detection.
        view = self.native("declarative_plugins_build_sync_check", {"workspaceRoot": self.native_workspace,
            "pluginId": self.variant["pluginId"], "buildSystemId": self.variant["buildSystemId"], "root": "."})
        return view, next(row for row in view["instances"] if row["pluginID"] == self.variant["pluginId"] and row["buildSystemID"] == self.variant["buildSystemId"] and row["root"] == ".")

    def run_action(self, testing=False, decline=False):
        region = self.open_build().get_by_role("region", name="Tasks and tests", exact=True)
        self.choose(region, "Action", "Tests" if testing else "build / Build")
        project = region.get_by_role("combobox", name="Project", exact=True)
        if project.count():
            self.choose(region, "Project", "fixture-app (.)")
        return self.approve("Review task / test execution", "Allow and execute", "declarative_plugins_build_prepare_run",
            lambda: region.get_by_role("button", name="Prepare task / test…", exact=True).click(timeout=10_000), decline=decline)

    def setting_failure(self):
        before = event_offset(self.workspace)
        self.native("declarative_plugins_store_setting", {"pluginId": self.variant["pluginId"], "settingId": "toolPath", "scope": "global",
            "workspacePath": str(self.workspace), "value": str(self.root / "missing tool.cmd")})
        try:
            review, _ = self.run_action()
            self.terminal(review, "failedToStart")
            if events_after(self.workspace, before):
                raise AssertionError("a configured failure fell back to the command candidate")
        finally:
            self.native("declarative_plugins_store_setting", {"pluginId": self.variant["pluginId"], "settingId": "toolPath", "scope": "global",
                "workspacePath": str(self.workspace), "value": str(confined(self.root, f"tools with spaces/bin/{COMMAND}"))})

    def task_test_dependencies(self):
        before = event_offset(self.workspace)
        review, _ = self.run_action()
        self.terminal(review, "succeeded")
        if not any(row.get("action") == "task" and "accepted-through-editor" in (row.get("savedText") or "")
                   for row in events_after(self.workspace, before)):
            raise AssertionError("the approved task did not read the saved editor contents")
        review, _ = self.run_action(testing=True)
        rows = self.terminal(review, "failed")
        if not any(row.get("type") == "testResults" and row.get("results", {}).get("summary", {}).get("failed") == 1 for row in rows):
            raise AssertionError("native Core test decoding did not return the controlled failure")
        if not any(row.get("type") == "diagnostics" and row.get("diagnostics") for row in rows):
            raise AssertionError("native Core diagnostics decoding did not return a source location")
        region = self.open_build().get_by_role("region", name="Dependencies", exact=True)
        project = region.get_by_role("combobox")
        project.click(timeout=10_000)
        self.page.get_by_role("option", name="fixture-app", exact=True).click(timeout=10_000)
        review, offset = self.approve("Review dependency loading", "Approve and load", "declarative_plugins_build_prepare_dependencies",
            lambda: region.get_by_role("button", name="Load dependencies…", exact=True).click(timeout=10_000))
        self.terminal(review, "succeeded")
        result = self.driver.wait_until(lambda: next((row["value"] for row in self.snapshot()["calls"][offset:]
            if row["command"] == "declarative_plugins_build_load_dependencies" and row.get("settled") and row.get("value")), None), 30, "Core-decoded dependency result")
        if not result.get("dependencies"):
            raise AssertionError("native dependency tree is missing")
        region.get_by_text(re.compile("fixture-dependency")).first.wait_for(state="visible", timeout=10_000)

    def capture_fixture_processes(self, offset):
        rows = events_after(self.workspace, offset)
        pids = {row["pid"] for row in rows if row.get("event") in ("started", "gated") and row.get("action") != "probe"}
        records = self.driver.process_tree(self.session.root_owner.pid)
        captured = {owner.pid: owner for owner in self.driver.capture_owned_tree(self.session.root_owner, records)}
        by_pid = {record["ProcessId"]: record for record in records}
        script = tool_script(self.root, self.variant)
        for pid in pids:
            record = by_pid.get(pid)
            if pid not in captured or record is None or not fixture_command_matches(record.get("CommandLine", ""), script):
                raise AssertionError("fixture evidence lacks a retained matching application-descendant handle")
            self.owned_handles[pid] = captured[pid]
        return [self.owned_handles[pid] for pid in pids]

    def cleanup_owned(self):
        # Normal native cancellation must already have ended every retained
        # fixture handle. A forced cleanup is a failure, never a passing case.
        survivors = [owner for owner in self.owned_handles.values() if owner.running()]
        errors = []
        for owner in survivors:
            try:
                if self.driver.owned_processes.get(owner.pid) is not owner:
                    raise RuntimeError("refusing cleanup through a replaced process ownership handle")
                self.driver.terminate_process_tree(owner.pid, timeout_seconds=5)
            except Exception as error:
                errors.append(str(error))
        self.owned_handles.clear()
        if survivors:
            raise AssertionError(f"native build cleanup left owned handles {[owner.pid for owner in survivors]}; forced cleanup: {errors}")

    def gated_run(self, action):
        before = event_offset(self.workspace)
        review, _ = self.run_action()
        self.driver.wait_until(lambda: any(row.get("event") == "gated" and not row.get("child") for row in events_after(self.workspace, before)), 10, "controlled executable gate")
        self.driver.wait_until(lambda: any(row.get("child") and row.get("event") == "started" for row in events_after(self.workspace, before)), 10, "controlled child started")
        handles = self.capture_fixture_processes(before)
        action(review)
        self.driver.wait_until(lambda: all(not owner.running() for owner in handles), 15, "owned build process tree revoked")
        return review

    def cancel_tree(self):
        with FixtureGate(self.workspace, "task"):
            review = self.gated_run(lambda _: self.open_build().get_by_role("button", name="Cancel task / test", exact=True).click(timeout=10_000))
            self.terminal(review, "cancelled")

    def replace_late(self):
        from playwright.sync_api import expect
        before_replace = ordinary_tree(self.installed_package())
        if before_replace != self.package_before:
            raise AssertionError("runtime work changed the installed source package before replacement")
        with FixtureGate(self.workspace, "task"):
            old = self.gated_run(lambda _: self.import_package("b"))
        self.open_build()
        if ordinary_tree(self.installed_package()) == before_replace:
            raise AssertionError("same-version replacement did not publish new package bytes")
        self.package_before = ordinary_tree(self.installed_package())
        # A stale native review must be refused by the real host, never replayed
        # through the observer or represented by a fabricated late event.
        try:
            self.native("declarative_plugins_build_execute_run", {"operationId": old["operationId"]})
        except Exception:
            pass
        else:
            raise AssertionError("the replaced package's old run was accepted")
        self.save_and_model()
        before = event_offset(self.workspace)
        new, _ = self.run_action()
        self.terminal(new, "succeeded")
        output = self.open_build().get_by_role("region", name="Tasks and tests", exact=True).get_by_role("region", name="Build Output", exact=True)
        expect(output).to_contain_text("[marker=b]", timeout=10_000)
        expect(output).not_to_contain_text("[marker=a]", timeout=10_000)
        rows = events_after(self.workspace, before)
        if not any(row.get("marker") == "b" and row.get("action") == "task" for row in rows):
            raise AssertionError("replacement did not execute the newly approved package declaration")
        if matching_events(self.snapshot()["events"], old) == matching_events(self.snapshot()["events"], new):
            raise AssertionError("replacement reused an old operation identity")

    def close_workspace(self):
        with FixtureGate(self.workspace, "task"):
            old = self.gated_run(lambda _: self.native("declarative_plugins_build_close_workspace", {"workspaceRoot": self.native_workspace}))
        try:
            self.native("declarative_plugins_build_prepare_run", {"workspaceRoot": self.native_workspace,
                "pluginId": self.variant["pluginId"], "buildSystemId": self.variant["buildSystemId"], "root": ".",
                "selection": {"kind": "task", "taskId": "build", "projectId": None, "targetId": None,
                              "modelTaskId": None, "suite": None, "case": None, "userArguments": []}})
        except Exception:
            pass
        else:
            raise AssertionError("a closed workspace admitted a new operation")
        if not matching_events(self.snapshot()["events"], old):
            raise AssertionError("closed operation had no actual native event evidence")
        # The parent subsequently requires actual graceful Quit and retains
        # its existing WebView2/descendant kernel-handle checks.

    def execute_variant(self, variant):
        self.variant = variant
        self.workspace = confined(self.root, variant["workspace"])
        with tool_environment(self.root):
            self.page, self.session = self.restart(self.workspace)
        self.page.evaluate(OBSERVER)
        resources_before = self.driver.hash_tree(self.args.run_image.resolve())
        try:
            with self.reporter.step(f"{variant['id']} / install-review"):
                self.import_package("a", cancel=True)
                if self.catalog() is not None:
                    raise AssertionError("cancelled native installation left a catalog entry")
                self.import_package("a")
                if variant["candidate"] in ("setting", "executableSetting"):
                    self.native("declarative_plugins_store_setting", {"pluginId": variant["pluginId"], "settingId": "toolPath", "scope": "global",
                        "workspacePath": str(self.workspace), "value": str(confined(self.root, f"tools with spaces/bin/{COMMAND}"))})
                self.package_before = ordinary_tree(self.installed_package())
            with self.reporter.step(f"{variant['id']} / passive-detection"):
                before = event_offset(self.workspace)
                self.open_build(); self.passive_view()
                if events_after(self.workspace, before):
                    raise AssertionError("passive detection probed or executed a project tool")
            with self.reporter.step(f"{variant['id']} / saved-model"):
                self.save_and_model()
            with self.reporter.step(f"{variant['id']} / decline-run"):
                self.run_action(decline=True)
            with self.reporter.step(f"{variant['id']} / task-test-dependencies"):
                self.task_test_dependencies()
            if variant["candidate"] == "setting":
                with self.reporter.step(SETTING_CASE):
                    self.setting_failure()
            with self.reporter.step(f"{variant['id']} / cancel-tree"):
                self.cancel_tree()
            with self.reporter.step(f"{variant['id']} / replace-late"):
                self.replace_late()
            with self.reporter.step(f"{variant['id']} / close-workspace"):
                self.close_workspace()
            with self.reporter.step(f"{variant['id']} / read-only-resources"):
                if self.driver.hash_tree(self.args.run_image.resolve()) != resources_before:
                    raise AssertionError("the packaged resource baseline changed")
                if ordinary_tree(self.installed_package()) != self.package_before:
                    raise AssertionError("installed package files changed during runtime work")
            with self.reporter.step(f"{variant['id']} / uninstall"):
                self.uninstall()
        finally:
            try:
                snapshot = self.snapshot()
                self.driver.write_json(self.evidence / f"{variant['id']}.json", snapshot)
                if snapshot["dropped"]:
                    raise AssertionError("acceptance observer truncated its evidence")
            finally:
                try:
                    self.page.evaluate("() => window.__litheBuildAcceptanceObserver.stop()")
                finally:
                    self.cleanup_owned()

    def execute_official(self):
        archive = self.args.build_official_maven_package.resolve(strict=True)
        with zipfile.ZipFile(archive) as package:
            manifest = json.loads(package.read("plugin.json"))
        system = next((system for system in manifest.get("buildSystems", []) if system.get("hostIntegration") == "maven"), None)
        if system is None:
            raise ValueError("the supplied official archive declares no Maven hostIntegration")
        if missing_capabilities(manifest.get("requires", {}), self.capabilities):
            return
        self.workspace = confined(self.root, self.plan["hostIntegration"]["workspace"])
        self.variant = {"pluginId": manifest["id"], "displayName": system.get("displayName", system["id"]), "buildSystemId": system["id"]}
        self.page, self.session = self.restart(self.workspace)
        self.page.evaluate(OBSERVER)
        try:
            with self.reporter.step(OFFICIAL):
                review = self.driver.import_review(self.page, self.session.process.pid, archive)
                self.driver.confirm_review(self.page, review)
                details = self.driver.wait_until(lambda: self.details(), 15, "official installed package details")
                if details["versions"]["current"]["verification"]["status"] != "publisherSignature":
                    raise AssertionError("hostIntegration acceptance requires a genuine trusted publisher signature")
                package_root = self.args.app_local_data / "plugins" / manifest["id"] / manifest["version"]
                before = ordinary_tree(package_root)
                region = self.open_build()
                _, instance = self.passive_view()
                if not instance.get("model", {}).get("projects"):
                    raise AssertionError("passive Maven hostIntegration returned no Core model")
                run = region.get_by_role("region", name="Tasks and tests", exact=True)
                for option, terminal in (("lifecycle / compile", "succeeded"), ("Tests", "succeeded")):
                    self.choose(run, "Action", option)
                    # Both official Maven actions expose workspace scope.
                    scope = run.get_by_role("combobox", name="Scope", exact=True)
                    if scope.count():
                        self.choose(run, "Scope", "Workspace")
                    native_review, _ = self.approve("Review task / test execution", "Allow and execute", "declarative_plugins_build_prepare_run",
                        lambda: run.get_by_role("button", name="Prepare task / test…", exact=True).click(timeout=10_000))
                    self.terminal(native_review, terminal)
                dependencies = region.get_by_role("region", name="Dependencies", exact=True)
                native_review, offset = self.approve("Review dependency loading", "Approve and load", "declarative_plugins_build_prepare_dependencies",
                    lambda: dependencies.get_by_role("button", name="Load dependencies…", exact=True).click(timeout=10_000))
                self.terminal(native_review, "succeeded")
                result = self.driver.wait_until(lambda: next((call["value"] for call in self.snapshot()["calls"][offset:]
                    if call["command"] == "declarative_plugins_build_load_dependencies" and call.get("settled") and call.get("value")), None), 30, "official native dependency decode")
                if result.get("dependencies") is None:
                    raise AssertionError("official hostIntegration did not decode dependencies")
                if ordinary_tree(package_root) != before:
                    raise AssertionError("official installed resources changed at runtime")
        finally:
            self.driver.write_json(self.evidence / "host-integration.json", self.snapshot())
            self.page.evaluate("() => window.__litheBuildAcceptanceObserver.stop()")

    def run(self):
        try:
            for variant in self.plan["variants"]:
                if missing_capabilities(variant["requires"], self.capabilities):
                    continue
                self.execute_variant(variant)
            if self.args.build_official_maven_package:
                self.execute_official()
        finally:
            record_unreached_cases(self.reporter, self.plan, self.capabilities,
                                   official=bool(self.args.build_official_maven_package))


def main():
    parser = argparse.ArgumentParser(description="Write pending build acceptance cases without launching a product or server.")
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
              "tests": planned_cases(load_plan(args.fixture_root), source_capabilities())}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Registered {len(report['tests'])} pending native build cases; no product executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
