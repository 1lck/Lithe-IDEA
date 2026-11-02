#!/usr/bin/env python3
"""Real ui:2 fetch failure -> pinned Tauri postMessage fallback, through CDP only.

No transport/callback replacement, native reply fabrication or capability change.
This controlled unsigned x64 subset never establishes complete M10 acceptance.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import platform
import re
import struct
import sys
from pathlib import Path
from urllib.parse import urlsplit

from build_fixture import ROOT, confined, json_bytes
from settings_functions_acceptance import assert_resources, resource_diff, snapshot_resources, verify_host, wait_for
from web_bridge_fallback_fixture import DISPLAY_NAME, FILES, PLUGIN_ID, declaration, load_plan, sha256, source_inventory

IPC_URL = "http://ipc.localhost/plugin%3Adeclarative-web%7Crequest"
WARNING = "IPC custom protocol failed, Tauri will now use the postMessage interface instead"
ORIGIN = "http://lithe-plugin." + PLUGIN_ID
CASES = ("identity-and-install-review", "production-private-page", "first-fetch-failure-real-fallback",
         "second-state-sticky-path", "transport-and-callback-invariants", "close-and-uninstall",
         "fetch-session-cleanup", "product-and-profile-cleanup", "resource-invariance")

# Read descriptors, function sources and the real debugging Map. Never assign a
# transport, touch Map entries, invoke callbacks, or retain page globals.
SNAPSHOT = r"""() => {
 const i=window.__TAURI_INTERNALS__;
 const describe=(owner,key)=>{const d=Object.getOwnPropertyDescriptor(owner,key);
   return d?{writable:d.writable??null,configurable:d.configurable,enumerable:d.enumerable,
     frozen:Object.isFrozen(d.value),type:typeof d.value,
     source:typeof d.value==='function'?Function.prototype.toString.call(d.value):null,
     get:d.get?Function.prototype.toString.call(d.get):null}:null;};
 return {url:location.href,pattern:i.__TAURI_PATTERN__.pattern,
   callbacks:{isMap:i.callbacks instanceof Map,size:i.callbacks.size,ids:[...i.callbacks.keys()]},
   descriptors:{lithe:describe(window,'lithe'),request:describe(window.lithe,'request'),
     invoke:describe(i,'invoke'),ipc:describe(i,'ipc'),postMessage:describe(i,'postMessage'),
     nativePostMessage:describe(window.ipc,'postMessage'),fetch:describe(window,'fetch'),
     callbacks:describe(i,'callbacks')},bridgeFrozen:Object.isFrozen(window.lithe)};
}"""


def cdp_send(session, method, params=None):
    # Public sync send has no timeout. Bound the same pinned Playwright bridge.
    return session._sync(asyncio.wait_for(session._impl_obj.send(method, params or {}), timeout=10))


def classify_request(event: dict, frame_id: str, nonce: str, already_failed: bool) -> tuple[str, str | None]:
    request = event["request"]
    url = request["url"]
    if event.get("frameId") != frame_id:
        return "continue", "paused request belongs to an unexpected frame"
    if url == IPC_URL:
        headers = {key.lower(): value for key, value in request.get("headers", {}).items()}
        # The pinned native IPC protocol separately handles OPTIONS without
        # invoking a command. If Chromium exposes a CORS preflight, release
        # only that exact origin/method/header set; it is not a second fetch.
        if request.get("method") == "OPTIONS":
            requested_headers = {part.strip().lower() for part in headers.get("access-control-request-headers", "").split(",")}
            if (not already_failed and headers.get("origin") == ORIGIN
                    and headers.get("access-control-request-method") == "POST"
                    and requested_headers == {"content-type", "tauri-callback", "tauri-error", "tauri-invoke-key"}
                    and not request.get("postData")):
                return "continue", None
            return "continue", "unexpected IPC preflight; refusing generalized interception"
        try:
            body = json.loads(request.get("postData", ""))
            exact = (request.get("method") == "POST" and body.get("method") == "ui.setState"
                     and body.get("params") == {"state": {"nonce": nonce}}
                     and type(body.get("generation")) is int and body["generation"] > 0
                     and set(body) == {"method", "params", "generation"}
                     and all(str(headers.get(key, "")).isdigit() for key in ("tauri-callback", "tauri-error"))
                     and bool(headers.get("tauri-invoke-key")))
        except (ValueError, TypeError, AttributeError):
            exact = False
        if not exact or already_failed:
            return "continue", "unexpected/duplicate IPC request; refusing generalized fault injection"
        return "fail", None
    if urlsplit(url).hostname == "ipc.localhost" or url.startswith("ipc:"):
        return "continue", "extra IPC command observed"
    if url.startswith(ORIGIN + "/"):
        return "continue", None
    return "continue", "unexpected external request observed"


class FetchFault:
    """One owner for the plugin-target Fetch domain and every paused request."""
    def __init__(self, session, frame_id, nonce):
        self.session, self.frame_id, self.nonce = session, frame_id, nonce
        self.paused, self.records, self.errors = set(), [], []
        self.failed = 0
        self.enabled = False

    def on_paused(self, event):
        request_id = event["requestId"]
        self.paused.add(request_id)
        request = event["request"]
        row = {"requestId": request_id, "networkId": event.get("networkId"), "frameId": event.get("frameId"),
               "url": request["url"], "method": request["method"], "postData": request.get("postData"),
               "headers": {k: v for k, v in request.get("headers", {}).items()
                           if k.lower() in ("content-type", "tauri-callback", "tauri-error", "origin",
                                            "access-control-request-method", "access-control-request-headers")}}
        self.records.append(row)
        try:
            decision, error = classify_request(event, self.frame_id, self.nonce, self.failed != 0)
            if error:
                self.errors.append(error)
            row.update(decision=decision, classificationError=error)
            if decision == "fail":
                cdp_send(self.session, "Fetch.failRequest", {"requestId": request_id, "errorReason": "Failed"})
                self.failed += 1
            else:
                cdp_send(self.session, "Fetch.continueRequest", {"requestId": request_id})
            row["released"] = True
            self.paused.discard(request_id)
        except Exception as error:
            row["releaseError"] = str(error)
            self.errors.append(str(error))

    def start(self):
        self.session.on("Fetch.requestPaused", self.on_paused)
        # Observe all requests on this private target only; fail exactly one
        # confirmed IPC POST. All others are released and unexpected ones fail
        # acceptance. No other WebView2 session receives Fetch.enable.
        self.enabled = True
        cdp_send(self.session, "Fetch.enable", {"patterns": [{"urlPattern": "*", "requestStage": "Request"}]})

    def close(self):
        errors = []
        try:
            for request_id in list(self.paused):
                try:
                    cdp_send(self.session, "Fetch.continueRequest", {"requestId": request_id})
                    self.paused.discard(request_id)
                    self.records.append({"requestId": request_id, "decision": "cleanup-continue", "released": True})
                except Exception as error:
                    errors.append(str(error))
        finally:
            try:
                if self.enabled:
                    cdp_send(self.session, "Fetch.disable")
                    self.enabled = False
                    # Disabling Fetch releases any requests that raced cleanup.
                    self.paused.clear()
            except Exception as error:
                errors.append(str(error))
            finally:
                self.session.remove_listener("Fetch.requestPaused", self.on_paused)
                self.session._sync(asyncio.wait_for(self.session._impl_obj.detach(), timeout=10))
        if errors:
            raise RuntimeError("Fetch cleanup: " + "; ".join(errors))

    def assert_one(self):
        ipc = [row for row in self.records if urlsplit(row.get("url", "")).hostname == "ipc.localhost" and row.get("method") == "POST"]
        if self.errors or self.failed != 1 or len(ipc) != 1 or self.paused:
            raise AssertionError(f"fault was not exactly one released IPC fetch: {self.errors}; {self.failed}/{len(ipc)}; paused={self.paused}")


def snapshot(page) -> dict:
    result = page.evaluate(SNAPSHOT)
    for descriptor in result["descriptors"].values():
        if descriptor and descriptor.get("source") is not None:
            descriptor["sourceSha256"] = hashlib.sha256(descriptor["source"].encode()).hexdigest()
    return result


def require_x64_executable(path: Path) -> str:
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError("acceptance executable is not PE")
        offset = struct.unpack_from("<I", header, 60)[0]
        if not 64 <= offset <= 1024 * 1024:
            raise ValueError("invalid PE header offset")
        stream.seek(offset)
        if stream.read(6) != b"PE\0\0\x64\x86":
            raise ValueError("acceptance executable is not Windows x64")
    return "IMAGE_FILE_MACHINE_AMD64"


def assert_transport(before, after):
    if (before["descriptors"] != after["descriptors"] or before["url"] != after["url"]
            or not after["bridgeFrozen"] or after["pattern"] != "brownfield"
            or not after["callbacks"]["isMap"] or after["callbacks"]["size"] != 0):
        raise AssertionError("transport identity/descriptor changed or real callback Map did not drain")
    for key in ("lithe", "invoke", "ipc", "postMessage"):
        if after["descriptors"][key]["writable"] is not False or after["descriptors"][key]["configurable"]:
            raise AssertionError("production transport was not non-replaceable: " + key)


def request(page, method, params):
    return page.evaluate("""async ([method,params]) => {
      let timer;
      try {return await Promise.race([window.lithe.request(method,params),
        new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('ui2 request deadline')),10000);})]);}
      finally {clearTimeout(timer);}
    }""", [method, params])


def run(args, driver, reporter):
    plan = load_plan(args.fixture_root)
    evidence = args.artifact_root
    evidence.mkdir(parents=True, exist_ok=False)
    baseline = snapshot_resources(args.run_image)
    archive_before = sha256(confined(args.fixture_root, plan["archive"]["path"]))
    driver.write_json(evidence / "resources-before.json", baseline)
    session = page = plugin = fault = cdp = None
    first_failure = None
    package_root = args.app_local_data / "plugins" / PLUGIN_ID / "1.0.0"
    package_before = None
    shutdown_completed = False
    console = []
    def step(name):
        return reporter.step("controlled-ui2-fallback / " + name, max_ms=420_000 if name == CASES[0] else 120_000)
    def wait(predicate, description):
        return wait_for(predicate, description, pump=lambda: page.evaluate("() => true"), seconds=15)
    def catalog():
        return next((row for row in driver.invoke(page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)
    def details():
        driver.open_plugin_settings(page)
        row = page.locator(f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']")
        row.get_by_role("button").click(timeout=10_000)
        region = page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=DISPLAY_NAME, exact=True)
        region.wait_for(state="visible", timeout=15_000)
        return region
    try:
        with driver.sync_playwright() as playwright:
            try:
                with step(CASES[0]):
                    identity = verify_host(args.host_identity, args.executable, plan)
                    config = args.host_identity.with_name("tauri.host-acceptance.conf.json")
                    if (identity.get("configSha256") != sha256(config) or identity.get("sourceInventory") != source_inventory()
                            or platform.machine().lower() not in ("amd64", "x86_64")):
                        raise ValueError("full source/config/x64 host identity mismatch")
                    driver.write_json(evidence / "identity.json", {"host": identity, "fixture": plan,
                        "osArchitecture": platform.machine(), "executableSha256": sha256(args.executable),
                        "peMachine": require_x64_executable(args.executable),
                        "acceptanceSources": {name: sha256(Path(__file__).with_name(name)) for name in
                            ("web_bridge_fallback_fixture.py", "web_bridge_fallback_acceptance.py", "web_bridge_fallback_acceptance_test.py")}})
                    session = driver.AppSession(playwright, args.executable, args.fixture_root / "workspace", args.webview_data, evidence / "app", 1)
                    reporter.capture_failure = lambda: driver.capture_session_failure(session, evidence)
                    page = session.start()
                    page.set_default_timeout(10_000)
                    driver.finish_onboarding(page)
                    # Clean profiles use the product's Chinese default. Change
                    # only this owned profile through the real settings control
                    # before reusing the existing English import-review helper.
                    settings_button = page.get_by_role("button", name=re.compile(r"^(Settings|设置)$")).first
                    settings_button.wait_for(state="visible", timeout=15_000)
                    if settings_button.get_attribute("aria-label") == "设置":
                        settings_button.click(timeout=15_000)
                        page.locator("[data-settings-category='general']").click(timeout=15_000)
                        general = page.locator("[data-settings-content='general']")
                        general.locator("[data-setting-primary-control]").filter(has_text="简体中文").click(timeout=15_000)
                        page.get_by_role("option", name="English", exact=True).click(timeout=15_000)
                        general.locator("[data-setting-primary-control]").filter(has_text="English").wait_for(state="visible", timeout=15_000)
                        page.get_by_role("button", name="Close", exact=True).last.click(timeout=15_000)
                        general.wait_for(state="hidden", timeout=15_000)
                    driver.finish_onboarding(page)
                    driver.write_json(evidence / "test-locale.json", {"language": "en-US", "method": "owned profile production settings UI"})
                    review = driver.import_review(page, session.process.pid, confined(args.fixture_root, plan["archive"]["path"]))
                    text = review.inner_text(timeout=5000)
                    driver.write_json(evidence / "install-review.json", {"text": text, "archive": plan["archive"]})
                    if any(value not in text for value in ("Unverified publisher", "ui.contribute", "ui.web")):
                        raise AssertionError("complete unsigned permissions/trust were not disclosed")
                    # The production UI omits ProgramDeclarationList when the
                    # native review's programs array is empty (not a disabled
                    # "(0)" button). The installation receipt independently
                    # binds that empty approval to the exact ZIP digest.
                    if review.get_by_role("button", name=re.compile(r"^Program declaration \(")).count():
                        raise AssertionError("static fixture unexpectedly declares programs")
                    disclosed = review.locator("li").all_text_contents()
                    if sorted(disclosed) != ["ui.contribute", "ui.web"]:
                        raise AssertionError("review permissions differ from the complete package")
                    driver.confirm_review(page, review)
                    wait(lambda: (row if (row := catalog()) and row["status"] == "accepted" and row["enabled"] else None), "accepted ui2 package")
                    record = json.loads((package_root.parent / "installation.json").read_text(encoding="utf-8"))
                    if record["disk"]["archiveSha256"] != plan["archive"]["sha256"] or record["disk"]["approvedPrograms"] != []:
                        raise AssertionError("installation approval/archive identity mismatch")
                    driver.write_json(evidence / "installation.json", record)
                    package_before = snapshot_resources(package_root)
                    driver.write_json(evidence / "package-before.json", package_before)
                    expected_package = {"ui/": {"kind": "directory"}}
                    for name, data in {"plugin.json": json_bytes(declaration()), **FILES}.items():
                        expected_package[name] = {"kind": "file", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                    assert_resources(expected_package, package_before)
                with step(CASES[1]):
                    window_row = page.get_by_test_id("declarative-web-window-list").locator("li").filter(has_text=DISPLAY_NAME)
                    window_row.get_by_role("button", name="Open", exact=True).click(timeout=10_000)
                    def private_page():
                        matches = [p for context in session.browser.contexts for p in context.pages if p.url == ORIGIN + "/ui/index.html"]
                        if len(matches) > 1:
                            raise AssertionError("ambiguous private plugin page")
                        return matches[0] if matches else None
                    plugin = wait(private_page, "production private WebView2")
                    plugin.set_default_timeout(10_000)
                    plugin.wait_for_function("() => Boolean(window.lithe?.request)", timeout=15_000)
                    before = snapshot(plugin)
                    assert_transport(before, before)
                    driver.write_json(evidence / "transport-before.json", before)
                    cdp = plugin.context.new_cdp_session(plugin)
                    target = cdp_send(cdp, "Target.getTargetInfo")["targetInfo"]
                    frame_id = cdp_send(cdp, "Page.getFrameTree")["frameTree"]["frame"]["id"]
                    if target["url"] != ORIGIN + "/ui/index.html" or target["type"] != "page":
                        raise AssertionError("CDP target is not the owning plugin page")
                    driver.write_json(evidence / "cdp-target.json", target)
                    nonce = os.urandom(16).hex()
                    plugin.on("console", lambda message: console.append({"type": message.type, "text": message.text}))
                    fault = FetchFault(cdp, frame_id, nonce)
                    fault.start()
                with step(CASES[2]):
                    first = request(plugin, "ui.setState", {"state": {"nonce": nonce}})
                    fault.assert_one()
                    first_snapshot = snapshot(plugin)
                    assert_transport(before, first_snapshot)
                    driver.write_json(evidence / "transport-first-settled.json", first_snapshot)
                    warnings = [row for row in console if row["type"] == "warning" and row["text"].startswith(WARNING)]
                    if first != {} or len(warnings) != 1:
                        raise AssertionError("original Promise/warning did not prove pinned native fallback")
                    driver.write_json(evidence / "first-fallback.json", {"nonce": nonce, "result": first, "warnings": warnings,
                        "ipcFetchCount": 1, "injection": "CDP Fetch.failRequest Failed, exactly once on the private target"})
                with step(CASES[3]):
                    if not fault.enabled:
                        raise AssertionError("Fetch interception was disabled before sticky request")
                    second = request(plugin, "ui.getState", None)
                    fault.assert_one()
                    if second != {"state": {"nonce": nonce}}:
                        raise AssertionError("sticky native read did not return the written nonce")
                    if len([row for row in console if row["text"].startswith(WARNING)]) != 1:
                        raise AssertionError("unexpected repeated fallback warning")
                    driver.write_json(evidence / "sticky-state.json", {"result": second, "ipcFetchCount": 1, "fetchStillEnabled": True})
                with step(CASES[4]):
                    after = snapshot(plugin)
                    driver.write_json(evidence / "transport-after.json", after)
                    assert_transport(before, after)
                    fault.assert_one()
                with step(CASES[6]):
                    fault.close()
                    cdp = None
                    driver.write_json(evidence / "fetch-cleanup.json", {"disabled": not fault.enabled, "paused": sorted(fault.paused), "detached": True})
                with step(CASES[5]):
                    with plugin.expect_event("close", timeout=15_000):
                        window_row.get_by_role("button", name="Close", exact=True).click(timeout=10_000)
                    package_after = snapshot_resources(package_root)
                    driver.write_json(evidence / "package-after.json", package_after)
                    assert_resources(package_before, package_after)
                    details().get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
                    wait(lambda: catalog() is None, "uninstall static package")
                    if package_root.parent.exists() or (args.app_local_data / "plugin-state" / PLUGIN_ID).exists():
                        raise AssertionError("uninstall retained package/state")
                    driver.write_json(evidence / "uninstall.json", {"pageClosed": plugin.is_closed(), "packageAndStateAbsent": True})
            except Exception as error:
                first_failure = error
                driver.write_json(evidence / "first-failure.json", {"type": type(error).__name__, "message": str(error)})
            finally:
                try:
                    if cdp is not None:
                        with step("failure-fetch-session-cleanup"):
                            if fault is not None:
                                fault.close()
                            else:
                                cdp._sync(asyncio.wait_for(cdp._impl_obj.detach(), timeout=10))
                except Exception as error:
                    first_failure = first_failure or error
                finally:
                    try:
                        if fault is not None:
                            driver.write_json(evidence / "paused-requests.json", {"records": fault.records, "errors": fault.errors,
                                "failedCount": fault.failed, "paused": sorted(fault.paused), "fetchEnabled": fault.enabled})
                        driver.write_json(evidence / "console.json", console)
                    except Exception as error:
                        # Evidence failure must not skip native/profile cleanup.
                        first_failure = first_failure or error
                    try:
                        with step(CASES[7]):
                            cleanup_errors = []
                            try:
                                if plugin is not None and not plugin.is_closed():
                                    final_callbacks = snapshot(plugin)
                                    driver.write_json(evidence / "failure-transport-final.json", final_callbacks)
                                if package_before is not None and package_root.exists():
                                    failed_package = snapshot_resources(package_root)
                                    driver.write_json(evidence / "failure-package-final.json", failed_package)
                                    assert_resources(package_before, failed_package)
                            except Exception as error:
                                cleanup_errors.append(str(error))
                            try:
                                if session is not None:
                                    driver.write_json(evidence / "shutdown.json", session.stop())
                            except Exception as error:
                                cleanup_errors.append(str(error))
                            finally:
                                # Retained native handles, never a process name,
                                # authorize last-resort cleanup after quit fails.
                                for owner in list(driver.owned_processes.values()):
                                    if owner.running():
                                        try:
                                            driver.terminate_process_tree(owner.pid)
                                        except Exception as error:
                                            cleanup_errors.append(str(error))
                                survivors = [owner.pid for owner in driver.owned_processes.values() if owner.running()]
                                if not survivors:
                                    for path, name in ((args.app_local_data, driver.ACCEPTANCE_IDENTIFIER),
                                                       (args.app_roaming_data, driver.ACCEPTANCE_IDENTIFIER),
                                                       (args.webview_data, "webview2")):
                                        try:
                                            driver.safe_remove_owned_directory(path, path.parent, name)
                                        except Exception as error:
                                            cleanup_errors.append(str(error))
                                profiles_absent = not any(p.exists() for p in (args.app_local_data, args.app_roaming_data, args.webview_data))
                                if not profiles_absent:
                                    cleanup_errors.append("isolated profiles remain")
                                driver.write_json(evidence / "cleanup.json", {"ownedSurvivors": survivors, "errors": cleanup_errors,
                                    "profilesAbsent": profiles_absent})
                            if survivors or cleanup_errors:
                                raise RuntimeError(f"cleanup failures: {cleanup_errors}; survivors: {survivors}")
                            shutdown_completed = session is not None and session.process is not None
                    except Exception as error:
                        first_failure = first_failure or error
    except Exception as error:
        # Playwright context teardown can fail after a more useful native error.
        first_failure = first_failure or error
    finally:
        try:
            with step(CASES[8]):
                after = snapshot_resources(args.run_image)
                driver.write_json(evidence / "resources-after.json", after)
                driver.write_json(evidence / "resources-diff.json", resource_diff(baseline, after))
                assert_resources(baseline, after)
                if sha256(confined(args.fixture_root, plan["archive"]["path"])) != archive_before:
                    raise AssertionError("fixture archive changed")
                if package_before is not None and package_root.exists():
                    assert_resources(package_before, snapshot_resources(package_root))
                if not shutdown_completed:
                    raise AssertionError("native workflow/shutdown did not complete before the final resource comparison")
        except Exception as error:
            first_failure = first_failure or error
        for owner in driver.owned_processes.values():
            owner.close()
        driver.owned_processes.clear()
    if first_failure:
        raise first_failure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("fixture-root", "host-identity", "executable", "run-image", "artifact-root", "report", "app-local-data", "app-roaming-data", "webview-data"):
        parser.add_argument("--" + key, required=True, type=Path)
    args = parser.parse_args()
    for key, value in vars(args).items():
        setattr(args, key, Path(os.path.abspath(value)))
    # Load native Windows bindings only in the explicit product invocation.
    import acceptance_driver as driver
    for path in (args.app_local_data, args.app_roaming_data, args.webview_data):
        if path.exists():
            parser.error("isolated profiles must be absent before this invocation")
    if (args.app_local_data != Path(os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.app_roaming_data != Path(os.environ["APPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.webview_data.name != "webview2"):
        parser.error("unexpected acceptance profile identity")
    reporter = driver.Reporter(args.report.with_suffix(".progress.json"))
    exit_code = 0
    try:
        run(args, driver, reporter)
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        exit_code = 1
    finally:
        completed = {row["name"].split(" / ")[-1] for row in reporter.tests}
        for name in CASES:
            if name not in completed:
                reporter.document_pending("controlled-ui2-fallback / " + name, "Not reached; never inferred from helper checks.")
        reporter.document_pending("complete-M10", "partial/pending: physical network faults, ui1/functions/ui3, keyboard/IME, arm64, publisher-signed complete packages and all other M10 remain unverified; gates unchanged.")
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
            "complete": False, "controlledSubsetPassed": exit_code == 0, "tests": reporter.tests})
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
