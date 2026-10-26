#!/usr/bin/env python3
"""Bounded fixture/locator regressions. These are never native product acceptance."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import acceptance_driver as driver
from marketplace_acceptance import (
    CONTROLLED_CASES, PUBLIC_CASES, MarketplaceAcceptance, add_arguments,
    choose_source, expect_rejected, marketplace, native_call, offer_row,
    read_review_programs, record_unreached_cases, source_row, validate_arguments,
)
from marketplace_fixture import (
    FixtureCatalog, FixtureServer, HttpsRedirects, PHASES,
    generate_fixture, https_base,
)
from playwright.sync_api import expect, sync_playwright


BASE = "https://marketplace.acceptance.invalid:8443/run"
SERVER = Path(__file__).with_name("fake-lsp-server.mjs")


def rejects(action, error_type=ValueError):
    try:
        action()
    except error_type:
        return
    raise AssertionError(f"expected {error_type.__name__}")


def fixture_case(action):
    with tempfile.TemporaryDirectory(prefix="lithe-market-fixture-") as directory:
        root = Path(directory) / "fixture"
        generate_fixture(root, BASE, SERVER)
        action(root)


def deterministic_archives():
    with tempfile.TemporaryDirectory(prefix="lithe-market-determinism-") as directory:
        roots = [Path(directory) / name for name in ("one", "two")]
        plans = [generate_fixture(root, BASE, SERVER) for root in roots]
        assert plans[0] == plans[1]
        for name, asset in plans[0]["assets"].items():
            first, second = (root / asset["file"] for root in roots)
            assert first.read_bytes() == second.read_bytes(), name
            assert hashlib.sha256(first.read_bytes()).hexdigest() == asset["sha256"]
            with zipfile.ZipFile(first) as archive:
                manifest = json.loads(archive.read("plugin.json"))
                assert manifest["id"] == driver.PLUGIN_ID
                assert manifest["version"] == asset["version"]
                assert manifest["vendor"]["signatureRequirement"] == "none"
                assert manifest["permissions"] == ["languageServer.launch"]
                assert manifest["languageServers"][0]["arguments"][-1] == asset["marker"]
                if name == "untrusted":
                    signature = json.loads(archive.read("lithe-plugin-signature.json"))
                    assert signature["keyId"] == "acceptance-untrusted"
                else:
                    assert "lithe-plugin-signature.json" not in archive.namelist()
        rejects(lambda: generate_fixture(roots[0], BASE, SERVER), FileExistsError)


def https_configuration_only():
    assert https_base(BASE + "/") == BASE
    for invalid in ("http://localhost:8000", "file:///fixture", "https://user:secret@example.com",
                    "https://example.com/a?token=secret", "https://example.com/#section",
                    "https://example.com/../other", "https://example.com:0"):
        rejects(lambda: https_base(invalid))
    redirect = HttpsRedirects()
    rejects(lambda: redirect.redirect_request(None, None, 302, "", {}, "http://example.com/index.json"))
    parser = argparse.ArgumentParser()
    add_arguments(parser)
    plain = parser.parse_args(["--marketplace"])
    validate_arguments(parser, plain)
    with contextlib.redirect_stderr(io.StringIO()):
        partial = parser.parse_args(["--marketplace", "--marketplace-fixture-root", "fixture"])
        rejects(lambda: validate_arguments(parser, partial), SystemExit)


def phases_and_corruption(root):
    catalog = FixtureCatalog(root)
    a = catalog.prefix + "/source-a/index.json"
    b = catalog.prefix + "/source-b/index.json"
    assert json.loads(catalog.response(b)[0])["plugins"][0]["versions"][0]["version"] == "9.0.0"
    for phase in PHASES:
        catalog.stage(phase)
        document = json.loads(catalog.response(a)[0])
        version = document["plugins"][0]["versions"][0]
        download = version["downloads"][0]
        assert download["platforms"] == ["windows-x64"]
        assert download["downloadURL"].startswith(BASE + "/packages/")
        if phase == "bad-digest":
            assert download["sha256"] == "0" * 64
    rejects(lambda: catalog.stage("outside-plan"))
    assert catalog.response(catalog.prefix + "/../plan.json")[0] is None
    (root / "packages/a1.zip").write_bytes(b"changed after generation")
    rejects(lambda: FixtureCatalog(root))


def gated_http_unit(root):
    catalog = FixtureCatalog(root)
    gate = catalog.gate_next_archive()
    replies = []
    with FixtureServer(catalog, ("127.0.0.1", 0), None) as server:
        url = f"http://127.0.0.1:{server.server.server_port}{catalog.prefix}/packages/a1.zip"
        def request():
            try:
                with urllib.request.urlopen(url, timeout=3) as response:
                    replies.append(response.read())
            except Exception as error:
                replies.append(error)
        client = threading.Thread(target=request, name="marketplace-unit-client")
        client.start()
        try:
            assert gate.arrived.wait(timeout=2)
            assert not gate.finished.is_set()
            gate.release.set()
            assert gate.finished.wait(timeout=2)
        finally:
            gate.release.set()
            client.join(timeout=4)
            assert not client.is_alive(), "the unit HTTP client survived its deadline"
        assert len(replies) == 1 and isinstance(replies[0], bytes), replies
        assert hashlib.sha256(replies[0]).hexdigest() == catalog.plan["assets"]["a1"]["sha256"]
        with urllib.request.urlopen(
            f"http://127.0.0.1:{server.server.server_port}{catalog.prefix}/source-a/index.json", timeout=2,
        ) as response:
            assert json.load(response) == catalog.plan["indexes"]["initial"]
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{server.server.server_port}/plan.json", timeout=2)
        except urllib.error.HTTPError as error:
            assert error.code == 404
        else:
            raise AssertionError("the fixture exposed its local plan or arbitrary files")
    assert not server.thread.is_alive()


def shutdown_releases_gate(root):
    catalog = FixtureCatalog(root)
    gate = catalog.gate_next_archive()
    server = FixtureServer(catalog, ("127.0.0.1", 0), None)
    replies = []
    def request():
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{server.server.server_port}{catalog.prefix}/packages/a1.zip", timeout=3,
            ) as response:
                replies.append(response.read())
        except Exception as error:
            replies.append(error)
    client = threading.Thread(target=request, name="marketplace-cancelled-unit-client")
    try:
        with server:
            client.start()
            assert gate.arrived.wait(timeout=2)
            # Assertion failures and cancellation must not leave a held request.
    finally:
        gate.release.set()
        client.join(timeout=4)
    assert not client.is_alive() and not server.thread.is_alive()
    assert gate.finished.is_set()
    assert len(replies) == 1 and isinstance(replies[0], Exception), replies


def missing_native_prerequisites(root):
    reporter = driver.Reporter()
    args = SimpleNamespace(artifact_root=root / "evidence", marketplace_fixture_root=None)
    scenario = MarketplaceAcceptance(driver, args, reporter, None, None, set())
    with patch.object(scenario, "run_public"), patch.object(scenario, "run_controlled") as controlled:
        scenario.run()
        controlled.assert_not_called()
    controlled_records = [test for test in reporter.tests if test["name"] in CONTROLLED_CASES]
    assert len(controlled_records) == len(CONTROLLED_CASES)
    assert all(test["status"] == "skipped" for test in controlled_records)
    record_unreached_cases(reporter)
    assert all(test["status"] == "skipped" for test in reporter.tests)
    assert all(any(test["name"] == name for test in reporter.tests) for name in PUBLIC_CASES + CONTROLLED_CASES)


def marketplace_dom(browser_channel: str):
    """Selectors and IPC argument regression against explicit HTML/native doubles."""
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=browser_channel, headless=True, timeout=10_000)
        try:
            page = browser.new_page()
            page.set_default_timeout(2_000)
            programs = [
                {"kind": "runtime", "tool": "node"},
                {"kind": "runtimeLanguageServer", "tool": "node", "packagedRuntime": None,
                 "entry": "server/fake-lsp-server.mjs", "runtimeArguments": [],
                 "arguments": ["--stdio", "--state-dir", "${workspaceStateDir}",
                               "--fixture-version", "market-a-1"], "validationArguments": [],
                 "languageID": "litheaccept"},
            ]
            page.set_content(f"""
              <div data-testid="marketplace-page"><select data-testid="marketplace-source-select">
                <option value="trap">Unrelated</option></select>
                <li data-testid="marketplace-plugin-{driver.PLUGIN_ID}">Trap</li></div>
              <div data-settings-content="declarative-plugins">
                <div data-testid="declarative-marketplace-sources">
                  <ul><li><div><p data-testid="declarative-marketplace-source-a">Same name</p></div>
                    <button role="switch" aria-checked="true">Enabled</button>
                    <button onclick="document.body.dataset.removed='a'">Remove</button></li>
                  <li><div><p data-testid="declarative-marketplace-source-b">Same name</p></div>
                    <button role="switch" aria-checked="false">Disabled</button>
                    <button onclick="document.body.dataset.trap='true'">Remove</button></li></ul>
                </div>
                <section data-testid="marketplace-page">
                  <select data-testid="marketplace-source-select">
                    <option value="all">All sources</option><option value="a">Same name</option>
                    <option value="b">Same name</option></select>
                  <ul><li data-testid="marketplace-plugin-{driver.PLUGIN_ID}">
                    {driver.DISPLAY_NAME} · 1.0.0
                    <button data-testid="marketplace-install-{driver.PLUGIN_ID}"
                      onclick="document.querySelector('#review').hidden=false">Install</button></li></ul>
                  <div id="review" data-testid="marketplace-review-card" role="dialog" hidden>
                    <p data-testid="marketplace-unverified-notice">Publisher not verified</p>
                    <ul><li>languageServer.launch</li></ul>
                    <button data-testid="marketplace-review-programs-toggle"
                      onclick="document.querySelector('#programs').hidden=false">Program declaration (2)</button>
                    <pre id="programs" hidden></pre>
                    <button data-testid="marketplace-review-confirm"
                      onclick="document.body.dataset.confirmed='true'">Install</button>
                    <button data-testid="marketplace-review-cancel"
                      onclick="this.closest('[role=dialog]').remove()">Cancel</button>
                  </div>
                </section>
              </div>
            """, timeout=2_000)
            page.locator("#programs").evaluate("(node, value) => node.textContent = JSON.stringify(value)", programs)
            choose_source(page, "b")
            expect(marketplace(page).get_by_test_id("marketplace-source-select")).to_have_value("b")
            expect(offer_row(page, driver.PLUGIN_ID)).to_have_count(1)
            source_row(page, "a").get_by_role("button", name="Remove", exact=True).click()
            expect(page.locator("body")).to_have_attribute("data-removed", "a")
            offer_row(page, driver.PLUGIN_ID).get_by_test_id(f"marketplace-install-{driver.PLUGIN_ID}").click()
            assert read_review_programs(page, marker="market-a-1") == programs
            # A truncated declaration must fail; the regression cannot merely
            # check that 'node' appears somewhere in the approval card.
            page.locator("#programs").evaluate("(node) => node.textContent = '[{\"tool\":\"node\"}]'")
            rejects(lambda: read_review_programs(page, marker="market-a-1"), AssertionError)
            marketplace(page).get_by_test_id("marketplace-review-cancel").click()
            expect(marketplace(page).get_by_test_id("marketplace-review-card")).to_have_count(0)
            page.evaluate("""() => {
              window.__TAURI_INTERNALS__ = {invoke: async (command, args) => {
                window.__observed = {command, args};
                if (args.approved === false) throw new Error('explicit approval is required');
                return {fixtureOnly: true};
              }};
            }""")
            expect_rejected(page, "declarative_marketplace_confirm", {
                "operationId": "unit-review", "manifestDigest": "a" * 64, "approved": False,
            }, "approval is required")
            observed = page.evaluate("() => window.__observed")
            assert observed["args"]["approved"] is False
            assert observed["command"] == "declarative_marketplace_confirm"
            assert native_call(page, "unit-observer-only") == {"fixtureOnly": True}
            assert page.locator("body").get_attribute("data-trap") is None
        finally:
            browser.close()


def run_tests(args) -> int:
    tests = []
    def case(name, action, max_ms=10_000):
        started = time.monotonic()
        status, details = "passed", ""
        try:
            action()
        except Exception as error:
            status, details = "failed", f"{type(error).__name__}: {error}"
        tests.append({"name": name, "suite": "plugin-marketplace-acceptance / fixture-and-locator-unit",
                      "status": status, "durationMs": round((time.monotonic() - started) * 1000, 3),
                      "maxMs": max_ms, "details": details})
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 2000, "maxMs": 10000, "tests": tests})
        if status != "passed":
            raise AssertionError(details)
    case("marketplace fixture archives and approval inputs are deterministic", deterministic_archives)
    case("native fixture configuration rejects HTTP and partial TLS arguments", https_configuration_only)
    case("fixture phases preserve selected bytes and reject modified archives", lambda: fixture_case(phases_and_corruption))
    case("unit HTTP gate releases the exact archive and denies arbitrary paths", lambda: fixture_case(gated_http_unit))
    case("fixture teardown releases a held request and listener", lambda: fixture_case(shutdown_releases_gate))
    case("missing native prerequisites remain explicitly skipped", lambda: fixture_case(missing_native_prerequisites))
    if args.dom_browser:
        def dom_child():
            result = driver.run_bounded_process([
                sys.executable, "-B", str(Path(__file__).resolve()),
                "--dom-browser", args.dom_browser, "--dom-fixture-child",
            ], timeout_seconds=30)
            assert result.returncode == 0, result.stderr or result.stdout
        case("HTML marketplace selectors and approval IPC preserve scope and full declarations", dom_child, max_ms=35_000)
    else:
        tests.append({"name": "HTML marketplace locator regression", "suite": "plugin-marketplace-acceptance / fixture-and-locator-unit",
                      "status": "skipped", "durationMs": 0, "maxMs": 35_000,
                      "details": "Pass --dom-browser msedge; no Lithe product is launched by this unit fixture."})
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 2000, "maxMs": 10000, "tests": tests})
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--dom-browser", choices=["msedge"])
    parser.add_argument("--test-child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--dom-fixture-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.dom_fixture_child:
        if not args.dom_browser:
            parser.error("--dom-fixture-child requires --dom-browser")
        marketplace_dom(args.dom_browser)
        return 0
    if not args.report:
        parser.error("--report is required")
    if args.test_child:
        return run_tests(args)
    command = [sys.executable, "-B", str(Path(__file__).resolve()), "--report", str(args.report.resolve()), "--test-child"]
    if args.dom_browser:
        command.extend(["--dom-browser", args.dom_browser])
    try:
        result = driver.run_bounded_process(command, timeout_seconds=90)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result.returncode
    except TimeoutError as error:
        report = json.loads(args.report.read_text(encoding="utf-8")) if args.report.exists() else {"runner": "acceptance", "tests": []}
        report["tests"].append({"name": "marketplace unit process watchdog", "suite": "plugin-marketplace-acceptance / fixture-and-locator-unit",
                                "status": "timeout", "durationMs": 90000, "maxMs": 90000, "details": str(error)})
        driver.write_json(args.report, report)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
