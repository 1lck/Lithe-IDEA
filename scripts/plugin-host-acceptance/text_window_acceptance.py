#!/usr/bin/env python3
"""Real Windows x64 ui:1 literal rendering; passive request observation only."""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import http.client
import importlib.metadata
import json
import os
import platform
import re
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from build_fixture import confined, json_bytes
from settings_functions_acceptance import assert_resources, resource_diff, snapshot_resources, verify_host, wait_for
from text_window_fixture import DISPLAY_NAME, PLUGIN_ID, WINDOW_ID, declaration, generate, literal_text, load_plan, sha256
from web_bridge_fallback_acceptance import SNAPSHOT, assert_transport, cdp_send, require_x64_executable

ORIGIN = "http://lithe-plugin." + PLUGIN_ID
TEXT_URL = ORIGIN + "/__lithe_host__/text/" + WINDOW_ID.encode().hex() + ".html"
BRIDGE_URL = ORIGIN + "/__lithe_host__/bridge.js"
CASES = ("identity-and-install-review", "preload-passive-observer", "private-host-text-page",
         "literal-dom-and-transport", "hide-and-reopen", "literal-network-and-ui-observation",
         "close-and-uninstall", "product-profile-counter-cleanup", "resource-invariance")


def read(page, expression):
    # Page.evaluate has no public timeout. Bound the pinned observer bridge,
    # including synchronous DOM/descriptor reads if a renderer stops replying.
    return page._sync(asyncio.wait_for(page._impl_obj.evaluate(expression), timeout=10))


def snapshot(page):
    result = read(page, SNAPSHOT)
    for descriptor in result["descriptors"].values():
        if descriptor and descriptor.get("source") is not None:
            descriptor["sourceSha256"] = hashlib.sha256(descriptor["source"].encode()).hexdigest()
    return result


class Counter:
    """One loopback server, bound before fixture generation, with bounded teardown."""
    def __init__(self):
        self.records = []
        self.controls = []
        records = self.records
        controls = self.controls
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                (controls if self.path == "/counter-control" else records).append({"method": self.command, "path": self.path})
                self.send_response(204)
                self.end_headers()
            do_POST = do_HEAD = do_OPTIONS = do_GET
            def log_message(self, *_args):
                pass
        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        # Accepted sockets cannot hold shutdown indefinitely.
        self.server.timeout = 0.2
        original = self.server.get_request
        def get_request():
            sock, address = original()
            sock.settimeout(1)
            return sock, address
        self.server.get_request = get_request
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve, name="literal-counter", daemon=True)
        self.endpoint = f"http://127.0.0.1:{self.server.server_port}/literal-probe"
        self.closed = False

    def serve(self):
        while not self.stop.is_set():
            self.server.handle_request()

    def start(self):
        self.thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        try:
            connection.request("GET", "/counter-control")
            response = connection.getresponse()
            response.read()
            if response.status != 204 or self.controls != [{"method": "GET", "path": "/counter-control"}]:
                raise AssertionError("counter positive control failed")
        finally:
            connection.close()

    def close(self):
        self.stop.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=3)
        self.server.server_close()
        self.closed = not self.thread.is_alive()
        if not self.closed:
            raise RuntimeError("literal counter survived its cleanup deadline")


class PassiveRequests:
    """Subscribe before opening a target; never route, intercept, or replace APIs.

    Pinned Playwright initializes Network before resuming a newly attached page.
    Requiring the original Document AND host bridge records detects a late or
    wrong-context observer instead of passing an empty trace.
    """
    def __init__(self, browser):
        self.contexts = list(browser.contexts)
        self.requests, self.responses, self.events, self.handlers = [], [], [], []
        for context in self.contexts:
            context.on("request", self.on_request)
            context.on("response", self.on_response)
            context.on("dialog", self.on_dialog)
            context.on("page", self.on_page)

    def on_request(self, request):
        try:
            owner = request.frame.page
        except Exception:
            owner = None
        self.requests.append((owner, {"url": request.url, "method": request.method,
                                    "resourceType": request.resource_type}))

    def on_response(self, response):
        try:
            owner = response.request.frame.page
        except Exception:
            owner = None
        self.responses.append((owner, response))

    def response_evidence(self, page):
        rows = []
        for owner, response in self.responses:
            if owner is page:
                body = response._sync(asyncio.wait_for(response._impl_obj.body(), timeout=10))
                headers = response.headers
                rows.append({"url": response.url, "status": response.status, "bytes": len(body),
                             "sha256": hashlib.sha256(body).hexdigest(),
                             "csp": headers.get("content-security-policy"), "contentType": headers.get("content-type")})
        if ({row["url"] for row in rows} != {TEXT_URL, BRIDGE_URL}
                or any(row["status"] != 200 or not row["csp"] for row in rows)):
            raise AssertionError("original host responses/CSP were not captured")
        return rows

    def on_dialog(self, dialog):
        self.events.append({"kind": "dialog", "type": dialog.type, "message": dialog.message})
        dialog.dismiss()

    def on_page(self, page):
        def download(item):
            self.events.append({"kind": "download", "url": item.url})
            item.cancel()
        def popup(item):
            self.events.append({"kind": "popup", "url": item.url})
        page.on("download", download)
        page.on("popup", popup)
        self.handlers.append((page, download, popup))

    def rows(self, page):
        if page.context not in self.contexts:
            raise AssertionError("private page was created outside pre-observed contexts")
        return [row for owner, row in self.requests if owner is page]

    def assert_page(self, page):
        rows = self.rows(page)
        expected = {(TEXT_URL, "GET", "document"), (BRIDGE_URL, "GET", "script")}
        actual = [(r["url"], r["method"], r["resourceType"]) for r in rows]
        if len(actual) != 2 or set(actual) != expected or self.events:
            raise AssertionError(f"unexpected/missing original request or UI side effect: {actual}; {self.events}")
        return rows

    def close(self):
        for context in self.contexts:
            context.remove_listener("request", self.on_request)
            context.remove_listener("response", self.on_response)
            context.remove_listener("dialog", self.on_dialog)
            context.remove_listener("page", self.on_page)
        for page, download, popup in self.handlers:
            page.remove_listener("download", download)
            page.remove_listener("popup", popup)


DOM = r"""() => ({url:location.href, text:document.querySelector('pre')?.textContent,
 bodyTags:[...document.body.querySelectorAll('*')].map(x=>x.tagName),
 scripts:[...document.scripts].map(x=>({src:x.src,text:x.textContent})),
 dangerous:document.querySelectorAll('iframe,img,object,embed,form,a,link').length,
 injected:Object.prototype.hasOwnProperty.call(window,'__literalExecuted'),
 context:window.lithe.context, ready:document.readyState})"""


def assert_dom(result, endpoint):
    if (result["url"] != TEXT_URL or result["text"] != literal_text(endpoint)
            or result["bodyTags"] != ["PRE"] or result["dangerous"] or result["injected"]
            or result["scripts"] != [{"src": BRIDGE_URL, "text": ""}]
            or result["context"]["pluginID"] != PLUGIN_ID or result["context"]["windowID"] != WINDOW_ID):
        raise AssertionError("literal text, host shell/script or scoped identity mismatch")


def run(args, driver, reporter):
    evidence = args.artifact_root
    evidence.mkdir(parents=True, exist_ok=False)
    baseline = snapshot_resources(args.run_image)
    session = page = plugin = observer = counter = None
    first_failure = None
    package_before = plan = None
    archive_before = None
    shutdown_completed = False
    package_root = args.app_local_data / "plugins" / PLUGIN_ID / "1.0.0"
    def write(name, value):
        driver.write_json(evidence / (name + ".json"), value)
    def step(name):
        return reporter.step("controlled-ui1-literal / " + name, max_ms=420_000 if name == CASES[0] else 120_000)
    def wait(predicate, description):
        return wait_for(predicate, description, pump=lambda: read(page, "() => true"), seconds=15)
    def catalog():
        return next((row for row in driver.invoke(page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)
    def details():
        driver.open_plugin_settings(page)
        page.locator(f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']").get_by_role("button").click(timeout=10_000)
        region = page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=DISPLAY_NAME, exact=True)
        region.wait_for(state="visible", timeout=15_000)
        return region
    try:
        with driver.sync_playwright() as playwright:
            try:
                with step(CASES[0]):
                    counter = Counter()
                    counter.start()
                    generate(args.fixture_root, counter.endpoint)
                    plan = load_plan(args.fixture_root)
                    archive_before = plan["archive"]["sha256"]
                    identity = verify_host(args.host_identity, args.executable, plan)
                    config = args.host_identity.with_name("tauri.host-acceptance.conf.json")
                    if (identity.get("configSha256") != sha256(config) or identity.get("sourceInventory") != plan["sourceInventory"]
                            or platform.machine().lower() not in ("amd64", "x86_64") or identity["gitRevision"] != plan["sourceCommit"]):
                        raise ValueError("full run-source/config/x64 host identity mismatch")
                    write("identity", {"host": identity, "fixture": plan, "peMachine": require_x64_executable(args.executable),
                        "acceptanceSources": {name: sha256(Path(__file__).with_name(name)) for name in
                            ("text_window_fixture.py", "text_window_acceptance.py", "text_window_acceptance_test.py")}})
                    write("resources-before", baseline)
                    session = driver.AppSession(playwright, args.executable, args.fixture_root / "workspace", args.webview_data, evidence / "app", 1)
                    reporter.capture_failure = lambda: driver.capture_session_failure(session, evidence)
                    page = session.start()
                    page.set_default_timeout(10_000)
                    driver.finish_onboarding(page)
                    settings = page.get_by_role("button", name=re.compile(r"^(Settings|设置)$")).first
                    settings.wait_for(state="visible", timeout=15_000)
                    if settings.get_attribute("aria-label") == "设置":
                        settings.click(timeout=15_000)
                        page.locator("[data-settings-category='general']").click(timeout=15_000)
                        general = page.locator("[data-settings-content='general']")
                        general.locator("[data-setting-primary-control]").filter(has_text="简体中文").click(timeout=15_000)
                        page.get_by_role("option", name="English", exact=True).click(timeout=15_000)
                        general.locator("[data-setting-primary-control]").filter(has_text="English").wait_for(state="visible", timeout=15_000)
                        page.get_by_role("button", name="Close", exact=True).last.click(timeout=15_000)
                        general.wait_for(state="hidden", timeout=15_000)
                    driver.finish_onboarding(page)
                    review = driver.import_review(page, session.process.pid, confined(args.fixture_root, plan["archive"]["path"]))
                    review_text = review.inner_text(timeout=5000)
                    permissions = review.locator("li").all_text_contents()
                    write("install-review", {"text": review_text, "permissions": permissions, "programCount": 0, "archive": plan["archive"]})
                    if ("Unverified publisher" not in review_text or permissions != ["ui.contribute"]
                            or review.get_by_role("button", name=re.compile(r"^Program declaration \(")).count()):
                        raise AssertionError("unsigned ui:1-only trust/permission/program review mismatch")
                    driver.confirm_review(page, review)
                    wait(lambda: (row if (row := catalog()) and row["status"] == "accepted" and row["enabled"] else None), "accepted literal package")
                    record = json.loads((package_root.parent / "installation.json").read_text(encoding="utf-8"))
                    write("installation", record)
                    if record["disk"]["archiveSha256"] != archive_before or record["disk"]["approvedPrograms"] != []:
                        raise AssertionError("installation approval/archive identity mismatch")
                    package_before = snapshot_resources(package_root)
                    data = json_bytes(declaration(counter.endpoint))
                    assert_resources({"plugin.json": {"kind": "file", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}}, package_before)
                    write("package-before", package_before)
                with step(CASES[1]):
                    import playwright as playwright_package
                    if importlib.metadata.version("playwright") != "1.60.0":
                        raise ValueError("passive observer requires pinned Playwright 1.60.0")
                    observer_source = Path(playwright_package.__file__).parent / "driver/package/lib/coreBundle.js"
                    observer = PassiveRequests(session.browser)
                    write("preload-observer", {"contexts": len(observer.contexts), "beforeOpen": True,
                        "mechanism": "Playwright BrowserContext request subscription; no route/Fetch/transport replacement",
                        "playwrightVersion": importlib.metadata.version("playwright"),
                        "observerSourceSha256": sha256(observer_source), "browserVersion": session.browser.version,
                        "coverageGuard": "original Document and bridge requests must both be captured on each page"})
                window_row = page.get_by_test_id("declarative-web-window-list").locator("li").filter(has_text=DISPLAY_NAME)
                def open_page():
                    window_row.get_by_role("button", name="Open", exact=True).click(timeout=10_000)
                    def find():
                        matches = [p for c in session.browser.contexts for p in c.pages if p.url == TEXT_URL]
                        if len(matches) > 1:
                            raise AssertionError("ambiguous private text page")
                        return matches[0] if matches else None
                    opened = wait(find, "host-owned private text page")
                    opened.set_default_timeout(10_000)
                    opened.wait_for_load_state("load", timeout=15_000)
                    opened.wait_for_function("() => Boolean(window.lithe?.request)", timeout=15_000)
                    return opened
                with step(CASES[2]):
                    plugin = open_page()
                    cdp = plugin.context.new_cdp_session(plugin)
                    try:
                        target = cdp_send(cdp, "Target.getTargetInfo")["targetInfo"]
                        if target["url"] != TEXT_URL or target["type"] != "page":
                            raise AssertionError("wrong real private CDP target")
                        write("private-target", target)
                    finally:
                        cdp._sync(asyncio.wait_for(cdp._impl_obj.detach(), timeout=10))
                with step(CASES[3]):
                    dom = read(plugin, DOM)
                    assert_dom(dom, counter.endpoint)
                    before = snapshot(plugin)
                    assert_transport(before, before)
                    write("dom-first", dom)
                    write("transport-first", before)
                    observer.assert_page(plugin)
                    write("host-responses-first", observer.response_evidence(plugin))
                    plugin.screenshot(path=str(evidence / "literal-first.png"), timeout=15_000)
                with step(CASES[4]):
                    # The production Close control hides content by destroying
                    # its WebView; Open creates a fresh host-owned page.
                    first_final = snapshot(plugin)
                    assert_transport(before, first_final)
                    write("transport-first-final", first_final)
                    with plugin.expect_event("close", timeout=15_000):
                        window_row.get_by_role("button", name="Close", exact=True).click(timeout=10_000)
                    first_page = plugin
                    plugin = open_page()
                    if plugin is first_page:
                        raise AssertionError("hide did not recreate the native page")
                    dom = read(plugin, DOM)
                    assert_dom(dom, counter.endpoint)
                    reopened = snapshot(plugin)
                    assert_transport(before, reopened)
                    write("dom-reopened", dom)
                    write("transport-reopened", reopened)
                    observer.assert_page(plugin)
                    write("host-responses-reopened", observer.response_evidence(plugin))
                    assert_resources(package_before, snapshot_resources(package_root))
                with step(CASES[5]):
                    # No native roundtrip is sent from the plugin. This passive
                    # browser trace observes network requests, not postMessage
                    # IPC; drained callback snapshots cannot count completed IPC.
                    read(page, "() => true")
                    rows = {"first": observer.assert_page(first_page), "reopened": observer.assert_page(plugin)}
                    if counter.records:
                        raise AssertionError("literal loopback URL received an HTTP request")
                    final = snapshot(plugin)
                    assert_transport(reopened, final)
                    write("transport-final", final)
                    write("network-and-ui-events", {"requests": rows, "events": observer.events,
                          "counterEndpoint": counter.endpoint, "counterRequests": counter.records,
                          "counterPositiveControl": counter.controls,
                          "observedPluginNetworkRequests": sum(len(value) for value in rows.values()),
                          "observedUnexpectedPluginNetworkRequests": sum(
                              row["url"] not in (TEXT_URL, BRIDGE_URL) for value in rows.values() for row in value),
                          "transportDescriptorSnapshots": ["transport-first", "transport-first-final", "transport-reopened", "transport-final"],
                          "ipcObservation": {"postMessageCount": None,
                              "limitation": "BrowserContext network events cannot observe postMessage IPC; callback snapshots prove only their sampled state."}})
                with step(CASES[6]):
                    with plugin.expect_event("close", timeout=15_000):
                        window_row.get_by_role("button", name="Close", exact=True).click(timeout=10_000)
                    write("package-after", snapshot_resources(package_root))
                    assert_resources(package_before, snapshot_resources(package_root))
                    details().get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
                    wait(lambda: catalog() is None, "uninstall literal package")
                    if package_root.parent.exists() or (args.app_local_data / "plugin-state" / PLUGIN_ID).exists():
                        raise AssertionError("uninstall retained package/state")
                    write("uninstall", {"pageClosed": plugin.is_closed(), "packageAndStateAbsent": True})
            except Exception as error:
                first_failure = error
                write("first-failure", {"type": type(error).__name__, "message": str(error)})
            finally:
                cleanup_errors = []
                try:
                    with step(CASES[7]):
                        try:
                            if observer is not None:
                                try:
                                    if first_failure is None:
                                        observer.assert_page(first_page)
                                        observer.assert_page(plugin)
                                    write("all-observed-requests", {"requests": [row for _, row in observer.requests], "events": observer.events})
                                finally:
                                    observer.close()
                        except Exception as error:
                            cleanup_errors.append(str(error))
                        try:
                            if session is not None:
                                write("shutdown", session.stop())
                                shutdown_completed = True
                        except Exception as error:
                            cleanup_errors.append(str(error))
                        finally:
                            for owner in list(driver.owned_processes.values()):
                                if owner.running():
                                    try:
                                        driver.terminate_process_tree(owner.pid)
                                    except Exception as error:
                                        cleanup_errors.append(str(error))
                            survivors = [owner.pid for owner in driver.owned_processes.values() if owner.running()]
                            if not survivors:
                                for path, name in ((args.app_local_data, driver.ACCEPTANCE_IDENTIFIER),
                                                   (args.app_roaming_data, driver.ACCEPTANCE_IDENTIFIER), (args.webview_data, "webview2")):
                                    try:
                                        driver.safe_remove_owned_directory(path, path.parent, name)
                                    except Exception as error:
                                        cleanup_errors.append(str(error))
                            try:
                                if counter is not None:
                                    counter.close()
                                    write("counter-final", {"endpoint": counter.endpoint, "requests": counter.records,
                                          "positiveControl": counter.controls, "closed": counter.closed})
                                    if counter.records:
                                        cleanup_errors.append("literal URL counter received requests")
                            except Exception as error:
                                cleanup_errors.append(str(error))
                            profiles_absent = not any(p.exists() for p in (args.app_local_data, args.app_roaming_data, args.webview_data))
                            write("cleanup", {"ownedSurvivors": survivors, "errors": cleanup_errors,
                                "profilesAbsent": profiles_absent, "counterClosed": counter is None or counter.closed})
                        if survivors or cleanup_errors or not profiles_absent:
                            raise RuntimeError(f"cleanup failures: {cleanup_errors}; survivors: {survivors}; profilesAbsent={profiles_absent}")
                except Exception as error:
                    first_failure = first_failure or error
    except Exception as error:
        first_failure = first_failure or error
    finally:
        # Also runs when creating Playwright or writing first-failure evidence
        # fails; server lifetime cannot depend on report serialization.
        if counter is not None and not counter.closed:
            try:
                counter.close()
            except Exception as error:
                first_failure = first_failure or error
        try:
            with step(CASES[8]):
                after = snapshot_resources(args.run_image)
                write("resources-after", after)
                write("resources-diff", resource_diff(baseline, after))
                assert_resources(baseline, after)
                if plan is not None and sha256(confined(args.fixture_root, plan["archive"]["path"])) != archive_before:
                    raise AssertionError("fixture archive changed")
                if package_before is not None and package_root.exists():
                    assert_resources(package_before, snapshot_resources(package_root))
                if not shutdown_completed:
                    raise AssertionError("native workflow/shutdown did not complete before final resource comparison")
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
    import acceptance_driver as driver
    for path in (args.app_local_data, args.app_roaming_data, args.webview_data, args.fixture_root, args.artifact_root):
        if path.exists():
            parser.error("run-owned inputs/profiles/evidence must be absent")
    if (args.app_local_data != Path(os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.app_roaming_data != Path(os.environ["APPDATA"]) / driver.ACCEPTANCE_IDENTIFIER or args.webview_data.name != "webview2"):
        parser.error("unexpected acceptance profile identity")
    # Progress lacks the normalized runner envelope; keep it with raw evidence
    # so directory report aggregation consumes only final timing reports.
    reporter = driver.Reporter(args.artifact_root / "progress.json")
    code = 0
    try:
        run(args, driver, reporter)
    except Exception as error:
        print(f"{type(error).__name__}: {error}", flush=True)
        code = 1
    finally:
        completed = {row["name"].split(" / ")[-1] for row in reporter.tests}
        for name in CASES:
            if name not in completed:
                reporter.document_pending("controlled-ui1-literal / " + name, "Not reached; helpers cannot establish runtime acceptance.")
        reporter.document_pending("complete-M10", "partial/pending: physical input/network faults, ui2/functions/ui3, arm64, publisher-signed complete packages and all other M10 remain unverified; all gates unchanged.")
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
                          "complete": False, "controlledSubsetPassed": code == 0, "tests": reporter.tests})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
