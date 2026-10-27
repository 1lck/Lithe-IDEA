#!/usr/bin/env python3
"""M10 phase-one settings entry point using the existing native acceptance owner.

Preflight never launches a product. Controlled settings evidence and blocked
real SDK/package evidence are separate report rows. Incomplete M10 exits nonzero;
source presence, mocked helpers and a successful settings subset cannot pass it.
"""
from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import stat
import sys
import time
from pathlib import Path

from build_acceptance import missing_capabilities, source_capabilities
from build_fixture import ROOT, confined
from settings_functions_fixture import DISPLAY_NAME, LOCK, PLUGIN_ID, load_plan, sha256

SUITE = "plugin-host-acceptance / settings-functions"
SETTINGS_CASES = ("trusted-install-review", "explicit-save-empty-reset-CAS", "two-window-isolation",
                  "project-reload-receipt", "global-reload", "upgrade-disable-uninstall", "observer-cleanup", "resource-invariance")
FUNCTION_CASES = ("discovery-approval-result", "progress-cancel-plugin-error", "settings-and-web-production-entry",
                  "two-window-workspace-isolation", "reload-late-callback", "cleanup-failure-retry",
                  "upgrade-disable-cleanup")


def pending_cases(plan: dict, capabilities: dict) -> list[dict]:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    settings_missing = missing_capabilities(plan["requires"], capabilities)
    function_missing = missing_capabilities(lock["requires"], capabilities)
    rows = []
    for category, names in (("controlled-settings", SETTINGS_CASES), ("real-functions", FUNCTION_CASES)):
        missing = settings_missing if category == "controlled-settings" else function_missing
        reason = "Not executed; normal isolated product install and approval required."
        if missing:
            reason += " Closed complete-package prerequisites: " + ", ".join(missing) + "."
        if category == "real-functions":
            reason += " " + " ".join(lock["audit"]["blockers"])
        for name in names:
            rows.append({"name": f"{category} / {name}", "suite": SUITE, "status": "skipped",
                         "durationMs": 0, "maxMs": 120_000, "details": reason})
    for name, reason in (("windows-arm64", "No native arm64 execution environment."),
                         ("manual-visual", "Real keyboard, IME, narrow-window and theme checks remain pending.")):
        rows.append({"name": name, "suite": SUITE, "status": "skipped", "durationMs": 0,
                     "maxMs": 120_000, "details": reason})
    return rows


def record_unreached_cases(reporter, plan: dict) -> None:
    completed = {row["name"] for row in reporter.tests}
    reporter.tests.extend(row for row in pending_cases(plan, source_capabilities()) if row["name"] not in completed)


def add_arguments(parser) -> None:
    parser.add_argument("--settings-functions-fixture-root", type=Path)
    parser.add_argument("--settings-functions-host-identity", type=Path,
                        help="Existing isolated build-identity.json; executable bytes and Git revision must match.")


def validate_arguments(parser, args) -> None:
    if bool(args.settings_functions_fixture_root) != bool(args.settings_functions_host_identity):
        parser.error("settings/functions requires both --settings-functions-fixture-root and --settings-functions-host-identity")
    if args.settings_functions_fixture_root and (args.marketplace or args.lsp_lifecycle or args.build_fixture_root):
        parser.error("settings/functions requires a focused invocation; run marketplace/LSP/build separately")


def snapshot_resources(root: Path, *, max_files=100_000, max_bytes=8 * 1024**3) -> dict:
    """Bounded exact listing, including empty directories; never follow reparse points."""
    for parent in (root, *root.parents):
        info = parent.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError("resource path traverses a link/reparse point")
    root = root.resolve(strict=True)
    result, total = {}, 0
    directories = [root]
    while directories:
        for path in sorted(directories.pop().iterdir()):
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ValueError("resource snapshot encountered a link/reparse point")
            key = path.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                result[key + "/"] = {"kind": "directory"}
                directories.append(path)
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > max_bytes:
                    raise ValueError("resource snapshot byte budget exceeded")
                result[key] = {"kind": "file", "bytes": info.st_size, "sha256": sha256(path)}
            else:
                raise ValueError("resource snapshot encountered a special file")
            if len(result) > max_files:
                raise ValueError("resource snapshot entry budget exceeded")
    return result


def resource_diff(before: dict, after: dict) -> dict:
    return {"added": sorted(after.keys() - before.keys()), "removed": sorted(before.keys() - after.keys()),
            "changed": sorted(key for key in before.keys() & after.keys() if before[key] != after[key])}


def assert_resources(before: dict, after: dict) -> dict:
    difference = resource_diff(before, after)
    if any(difference.values()):
        raise AssertionError("read-only resource mutation: " + json.dumps(difference, sort_keys=True))
    return difference


def wait_for(predicate, description, *, now=time.monotonic, pump, seconds=10):
    # Pump the existing Playwright dispatcher. Unit checks inject a manual clock;
    # no real sleep, detached task or second process/JSON-RPC runner is introduced.
    deadline = now() + seconds
    while now() < deadline:
        value = predicate()
        if value:
            return value
        pump()
    raise TimeoutError(f"settings/functions deadline: {description}")


def verify_host(identity_path: Path, executable: Path, plan: dict) -> dict:
    identity = json.loads(identity_path.read_text(encoding="utf-8-sig"))
    if (identity.get("identifier") != "app.lithe.windows.host-acceptance"
            or identity.get("rustTarget") != "x86_64-pc-windows-msvc"
            or identity.get("gitRevision") != plan["sourceCommit"]
            or identity.get("executableSha256") != sha256(executable)):
        raise ValueError("host executable, architecture or source identity does not match the selected fixture/build")
    return identity


class SettingsFunctionsAcceptance:
    """Owned by acceptance_driver.AppSession; no independent launch/IPC truth."""
    def __init__(self, driver, args, reporter, restart):
        self.driver, self.args, self.reporter, self.restart = driver, args, reporter, restart
        self.root = args.settings_functions_fixture_root
        self.plan = load_plan(self.root)
        self.root = self.root.resolve()
        self.evidence = args.artifact_root / "settings-functions"
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.page = self.session = self.second = None
        self.workspace = confined(self.root, "one")
        self.package_root = None
        self.package_baselines = {}

    def native(self, page, command, args=None):
        # All calls retain the existing 10-second IPC deadline.
        return self.driver.invoke(page, command, args)

    def step(self, name):
        return self.reporter.step("controlled-settings / " + name)

    def catalog(self, page):
        return next((row for row in self.native(page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)

    def details(self, page):
        self.driver.open_plugin_settings(page)
        row = page.locator(f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']")
        row.wait_for(state="visible", timeout=15_000)
        row.get_by_role("button").click(timeout=10_000)
        details = page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=DISPLAY_NAME, exact=True)
        details.wait_for(state="visible", timeout=15_000)
        return details

    def editor(self, page, *, registered=False):
        if registered:
            self.driver.open_plugin_settings(page)
            group = page.locator("[aria-controls='settings-group-languages']")
            if group.get_attribute("aria-expanded", timeout=10_000) != "true":
                group.click(timeout=10_000)
            route = "plugin-settings:language:lithesettingsaccept"
            category = page.locator(f"[data-settings-category='{route}']")
            category.wait_for(state="visible", timeout=15_000)
            category.click(timeout=10_000)
        else:
            self.details(page).get_by_role("tab", name=re.compile(r"^Settings(?:\s|$)")).click(timeout=10_000)
            route = "declarative-plugins"
        # The dialog retains visited pages. Scope to the selected content so a
        # hidden detail editor cannot satisfy the registered-page workflow.
        content = page.locator(f"[data-settings-content='{route}']")
        content.wait_for(state="visible", timeout=15_000)
        editor = content.locator(f"[data-plugin-settings='{PLUGIN_ID}']")
        setting = "reload" if registered else "message"
        editor.locator(f"[data-plugin-setting='{setting}']").wait_for(state="visible", timeout=15_000)
        return editor

    def snapshot(self, page, workspace):
        return self.native(page, "declarative_plugins_setting_snapshot", {"pluginId": PLUGIN_ID, "workspacePath": str(workspace)})

    def wait(self, predicate, description):
        return wait_for(predicate, description, pump=lambda: self.page.evaluate("() => true"))

    def save(self, page, setting, value, layer="global", *, registered=False):
        editor = self.editor(page, registered=registered)
        select = editor.get_by_role("combobox")
        select.click(timeout=10_000)
        page.get_by_role("option", name="this workspace" if layer == "project" else "all workspaces", exact=True).click(timeout=10_000)
        row = editor.locator(f"[data-plugin-setting='{setting}']")
        row.get_by_role("textbox").fill(value, timeout=10_000)
        offset = page.evaluate("() => window.__litheSettingsAcceptance.calls.length")
        row.get_by_role("button", name=re.compile(r": Save$")).click(timeout=10_000)
        call = self.wait(lambda: page.evaluate("""([offset,id,scope]) => window.__litheSettingsAcceptance.calls.slice(offset).find(c =>
            c.command === 'declarative_plugins_store_setting' && c.args.settingId === id && c.args.scope === scope && c.settled)""",
            [offset, setting, layer]), "explicit save settled")
        if call.get("error"):
            raise AssertionError(f"settings save failed: {call['error']}")
        if editor.get_by_role("alert").count():
            raise AssertionError(editor.get_by_role("alert").inner_text(timeout=5000))
        return call["value"]

    def compare_package(self, name):
        for version, before in self.package_baselines.items():
            package_root = self.args.app_local_data / "plugins" / PLUGIN_ID / version
            after = snapshot_resources(package_root)
            self.driver.write_json(self.evidence / f"{name}-{version}-package-after.json", after)
            difference = resource_diff(before, after)
            self.driver.write_json(self.evidence / f"{name}-{version}-package-diff.json", difference)
            assert_resources(before, after)

    def install(self, version):
        asset = self.plan["archives"][version]
        review = self.driver.import_review(self.page, self.session.process.pid, confined(self.root, asset["path"]))
        if "Unverified publisher" not in review.inner_text(timeout=5000):
            raise AssertionError("the controlled fixture was not shown as an unverified publisher")
        self.driver.confirm_review(self.page, review)
        self.wait(lambda: (row if (row := self.catalog(self.page)) and row["status"] == "accepted"
                           and row["version"] == version and row["enabled"] else None), "accepted complete package")
        record = json.loads((self.args.app_local_data / "plugins" / PLUGIN_ID / "installation.json").read_text(encoding="utf-8"))
        if record["disk"]["archiveSha256"] != asset["sha256"] or record["disk"]["approvedPrograms"]:
            raise AssertionError("installed approval does not match the settings-only archive")
        self.package_root = self.args.app_local_data / "plugins" / PLUGIN_ID / version
        before = snapshot_resources(self.package_root)
        self.package_baselines[version] = before
        self.driver.write_json(self.evidence / f"{version}-package-before.json", before)

    def explicit_save(self):
        before = self.snapshot(self.page, self.workspace)
        self.editor(self.page)
        if self.snapshot(self.page, self.workspace) != before:
            raise AssertionError("opening settings mutated its snapshot")
        self.save(self.page, "message", "global-value")
        saved = self.snapshot(self.page, self.workspace)
        if saved["globalValues"].get("message") != "global-value":
            raise AssertionError("UI save did not persist the global value")
        # A real concurrent writer uses the production command; stale CAS must
        # reject without clobbering either store. Never edit the store on disk.
        try:
            self.native(self.page, "declarative_plugins_store_setting", {"pluginId": PLUGIN_ID, "settingId": "message",
                "scope": "global", "workspacePath": str(self.workspace), "value": "lost-update", "expectedIdentity": before["identity"]})
        except Exception as error:
            if "plugin.settings.conflict" not in str(error):
                raise
        else:
            raise AssertionError("stale settings CAS was accepted")
        if self.snapshot(self.page, self.workspace) != saved:
            raise AssertionError("failed CAS changed settings")
        self.save(self.page, "message", "", "project")
        if self.snapshot(self.page, self.workspace)["projectValues"].get("message") != "":
            raise AssertionError("explicit empty project value was lost")
        row = self.editor(self.page).locator("[data-plugin-setting='message']")
        # Select the intended layer explicitly when revisiting the editor.
        row_scope = self.page.locator(f"[data-plugin-settings='{PLUGIN_ID}']").get_by_role("combobox")
        row_scope.click(timeout=10_000)
        self.page.get_by_role("option", name="this workspace", exact=True).click(timeout=10_000)
        row.get_by_role("button", name=re.compile(r": Use inherited value$")).click(timeout=10_000)
        self.wait(lambda: "message" not in self.snapshot(self.page, self.workspace)["projectValues"], "project reset")
        self.compare_package("explicit-save")

    def two_windows(self):
        with self.page.context.expect_page(timeout=30_000) as new_page:
            label = self.native(self.page, "create_app_window", {"request": {"type": "directory", "path": str(confined(self.root, "two"))}})
        self.second = new_page.value
        self.second.wait_for_load_state("domcontentloaded", timeout=15_000)
        self.second.wait_for_function("() => Boolean(window.__TAURI_INTERNALS__?.invoke)", timeout=15_000)
        self.driver.finish_onboarding(self.second)
        self.second.evaluate(OBSERVER)
        first_receipt = self.save(self.page, "message", "window-one", "project")
        second_receipt = self.save(self.second, "message", "window-two", "project")
        first_context, second_context = first_receipt.get("reloadContext"), second_receipt.get("reloadContext")
        if (not first_context or not second_context
                or first_context["windowIncarnation"] == second_context["windowIncarnation"]
                or first_context["workspaceId"] == second_context["workspaceId"]):
            raise AssertionError("two product windows lack distinct native window/workspace receipts")
        first, second = self.snapshot(self.page, self.workspace), self.snapshot(self.second, confined(self.root, "two"))
        if first["projectValues"].get("message") != "window-one" or second["projectValues"].get("message") != "window-two":
            raise AssertionError("real product windows leaked workspace settings")
        self.driver.write_json(self.evidence / "two-windows.json", {"secondLabel": label, "first": first, "second": second,
                               "firstContext": first_context, "secondContext": second_context})

    def reload(self, scope):
        self.save(self.page, "reload", f"{scope}-reload", scope, registered=True)
        notice = self.page.locator(f"[data-plugin-reload='{PLUGIN_ID}'][data-plugin-reload-scope='{scope}']")
        notice.wait_for(state="visible", timeout=10_000)
        notice.locator("[data-plugin-reload-confirm]").click(timeout=10_000)
        # A vanished notice alone is insufficient: the read-only observer must
        # see a settled real production call with a native snapshot receipt.
        call = self.wait(lambda: self.page.evaluate("""scope => window.__litheSettingsAcceptance.calls.findLast(c =>
            c.command === 'declarative_plugins_reload_settings' && c.args.scope === scope && c.settled)""", scope), "native reload result")
        if call.get("error") or not call.get("value"):
            raise AssertionError(f"native reload failed: {call}")
        args = call["args"]
        if not args.get("expectedIdentity") or not args.get("expectedPackageIdentity") or (scope == "project" and not args.get("project")):
            raise AssertionError("reload did not consume the actual settings/package/project receipt")
        notice.wait_for(state="detached", timeout=15_000)
        if self.snapshot(self.second, confined(self.root, "two"))["projectValues"].get("message") != "window-two":
            raise AssertionError("reload changed another workspace's settings")
        self.driver.write_json(self.evidence / f"{scope}-reload.json", call)
        self.compare_package(scope + "-reload")

    def lifecycle(self):
        self.compare_package("before-upgrade")
        self.install("1.1.0")
        self.compare_package("after-upgrade")
        self.details(self.page).get_by_role("button", name="Disable", exact=True).click(timeout=10_000)
        self.wait(lambda: not self.catalog(self.page)["enabled"], "disable")
        self.compare_package("disabled")
        self.details(self.page).get_by_role("button", name="Enable", exact=True).click(timeout=10_000)
        self.wait(lambda: self.catalog(self.page)["enabled"], "enable")
        self.details(self.page).get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
        self.wait(lambda: self.catalog(self.page) is None, "uninstall")
        if (self.args.app_local_data / "plugins" / PLUGIN_ID).exists() or (self.args.app_local_data / "plugin-state" / PLUGIN_ID).exists():
            raise AssertionError("uninstall retained package/state")

    def stop_observers(self):
        errors = []
        for index, page in enumerate((self.page, self.second)):
            if page is None:
                continue
            try:
                observed = page.evaluate("() => window.__litheSettingsAcceptance?.snapshot()")
                self.driver.write_json(self.evidence / f"observed-calls-{index}.json", observed)
                if observed and observed["dropped"]:
                    raise AssertionError("acceptance observer truncated its evidence")
            except Exception as error:
                errors.append(f"window {index} snapshot: {error}")
            finally:
                try:
                    page.evaluate("() => window.__litheSettingsAcceptance?.stop()")
                except Exception as error:
                    errors.append(f"window {index} observer cleanup: {error}")
        if errors:
            raise RuntimeError("; ".join(errors))

    def run(self):
        resources_before = snapshot_resources(self.args.run_image)
        self.driver.write_json(self.evidence / "resources-before.json", resources_before)
        try:
            with self.step("trusted-install-review"):
                identity = verify_host(self.args.settings_functions_host_identity, self.args.executable, self.plan)
                if missing_capabilities(self.plan["requires"], source_capabilities()):
                    raise RuntimeError("controlled settings complete package requires closed host capabilities")
                self.page, self.session = self.restart(self.workspace)
                self.page.evaluate(OBSERVER)
                node = Path(shutil.which("node") or "missing-node").resolve(strict=True)
                node_version = self.driver.run_bounded_process([str(node), "--version"], 10)
                if node_version.returncode:
                    raise RuntimeError("could not establish the native Node tool identity")
                self.driver.write_json(self.evidence / "identity.json", {"host": identity, "fixture": self.plan,
                    "architecture": platform.machine(), "python": {"version": sys.version, "executableSha256": sha256(Path(sys.executable))},
                    "node": {"version": node_version.stdout.strip(), "executableSha256": sha256(node)},
                    "sdkExecuted": False})
                self.install("1.0.0")
            with self.step("explicit-save-empty-reset-CAS"):
                self.explicit_save()
            with self.step("two-window-isolation"):
                self.two_windows()
            with self.step("project-reload-receipt"):
                self.reload("project")
            with self.step("global-reload"):
                self.reload("global")
            with self.step("upgrade-disable-uninstall"):
                self.lifecycle()
        finally:
            try:
                with self.step("observer-cleanup"):
                    self.stop_observers()
            finally:
                with self.step("resource-invariance"):
                    after = snapshot_resources(self.args.run_image)
                    self.driver.write_json(self.evidence / "resources-after.json", after)
                    self.driver.write_json(self.evidence / "resources-diff.json", resource_diff(resources_before, after))
                    assert_resources(resources_before, after)
                    if self.package_root is not None and self.package_root.exists():
                        self.compare_package("final")
        record_unreached_cases(self.reporter, self.plan)
        # No signed compatible real-functions archive/entry exists at this
        # frozen baseline. A successful controlled subset must still fail M10.


# Transparent IPC observation only. Original results/errors pass unchanged;
# the window's production frontend owns calls, approvals and effect dispatch.
OBSERVER = r"""() => {
  if (window.__litheSettingsAcceptance) throw new Error('observer already active');
  const internals=window.__TAURI_INTERNALS__, original=internals.invoke;
  const state={calls:[],dropped:0};
  internals.invoke=function(command,args,...rest) {
    if (!command.startsWith('declarative_plugins_')) return original.call(this,command,args,...rest);
    const call={command,args,settled:false};
    if(state.calls.length<2048) state.calls.push(call); else state.dropped++;
    return original.call(this,command,args,...rest).then(value=>{call.settled=true;call.value=value;return value;},
      error=>{call.settled=true;call.error=String(error);throw error;});
  };
  state.snapshot=()=>({calls:state.calls,dropped:state.dropped});
  state.stop=()=>{internals.invoke=original;delete window.__litheSettingsAcceptance;};
  window.__litheSettingsAcceptance=state;
}"""


def main() -> int:
    parser = argparse.ArgumentParser(description="M10 preflight only; never starts an application.")
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000, "complete": False, "tests": []}
    try:
        plan = load_plan(args.fixture_root)
        report.update(fixture=plan, hostCapabilities=source_capabilities(), tests=pending_cases(plan, source_capabilities()))
        code = 2
    except Exception as error:
        report["tests"].append({"name": "settings/functions preflight", "suite": SUITE, "status": "failed",
            "durationMs": 0, "maxMs": 10_000, "details": f"{type(error).__name__}: {error}"})
        code = 1
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("M10 pending; no product executed." if code == 2 else "M10 preflight failed.")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
