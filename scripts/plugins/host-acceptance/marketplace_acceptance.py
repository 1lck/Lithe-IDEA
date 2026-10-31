"""Optional real-marketplace lane for acceptance_driver; no mocked native answers.

Public-source browsing is usable without a controlled publisher. The transaction
lane additionally needs the generated fixture and a certificate already trusted
for its reachable HTTPS hostname. Host IPC checks are named separately from UI
actions; lightweight HTML locator checks are never reported as native execution.
"""

from __future__ import annotations

import json
import re
import uuid
from pathlib import Path

from playwright.sync_api import Page, expect

from marketplace_fixture import FixtureCatalog, FixtureServer, PUBLIC_SOURCES


PUBLIC_CASES = (
    "marketplace public HTTPS refresh and search",
    "marketplace public source add, disable, remove, and official protection",
)
LATE_UI_CASE = "marketplace native UI cancels late prepare on cancel, scope switch, and page close"
CONTROLLED_CASES = (
    "marketplace controlled source management and same-ID offers",
    "marketplace host rejects missing approval and a wrong review digest",
    "marketplace UI cancel and source switch discard prepared reviews",
    "marketplace late prepare is cancelled by source disable and removal",
    "marketplace UI shows complete permissions and programs before install",
    "marketplace installation and source provenance survive restart",
    "marketplace competing source cannot take over an installed ID",
    "marketplace rejects archive digest and untrusted publisher signatures",
    "marketplace source refresh invalidates an earlier host review",
    "marketplace disabled installation updates only from its original source",
    "marketplace disable and uninstall revoke processes and stale reviews",
    LATE_UI_CASE,
)
SIGNATURE_GAP = "marketplace official publisher-signed Windows package"


def add_arguments(parser) -> None:
    parser.add_argument("--marketplace", action="store_true",
                        help="Also exercise real HTTPS marketplace UI/IPC after the disk/LSP lane.")
    parser.add_argument("--marketplace-fixture-root", type=Path,
                        help="Generated marketplace_fixture.py directory; never an installed app directory.")
    parser.add_argument("--marketplace-tls-cert", type=Path,
                        help="Existing certificate chain valid and already trusted for the plan's HTTPS hostname.")
    parser.add_argument("--marketplace-tls-key", type=Path,
                        help="Existing TLS key file; its contents are never copied into artifacts.")
    parser.add_argument("--marketplace-listen-host", default="127.0.0.1")


def validate_arguments(parser, args) -> None:
    supplied = (args.marketplace_fixture_root, args.marketplace_tls_cert, args.marketplace_tls_key)
    if any(supplied) and (not args.marketplace or not all(supplied)):
        parser.error("controlled marketplace execution requires --marketplace, --marketplace-fixture-root, --marketplace-tls-cert and --marketplace-tls-key together")


def settings(page: Page):
    return page.locator("[data-settings-content='declarative-plugins']")


def marketplace(page: Page):
    return settings(page).get_by_test_id("marketplace-page")


def source_row(page: Page, source_id: str):
    return settings(page).get_by_test_id(f"declarative-marketplace-source-{source_id}").locator("xpath=ancestor::li[1]")


def offer_row(page: Page, plugin_id: str):
    return marketplace(page).get_by_test_id(f"marketplace-plugin-{plugin_id}")


def choose_source(page: Page, source_id: str) -> None:
    select = marketplace(page).get_by_test_id("marketplace-source-select")
    expect(select).to_be_enabled(timeout=15_000)
    select.select_option(source_id, timeout=15_000)
    expect(select).to_have_value(source_id, timeout=15_000)


def native_call(page: Page, command: str, arguments: dict | None = None):
    # Fetches have the production host's 60s deadline. The observer allows
    # another 10s for cancellation/publication without weakening that deadline.
    timeout_ms = 70_000 if command.endswith(("_refresh", "_prepare")) else 10_000
    result = page.evaluate("""async ([command, args, timeout]) => {
      let timer;
      try {
        const value = await Promise.race([
          window.__TAURI_INTERNALS__.invoke(command, args),
          new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(`acceptance IPC deadline: ${command}`)), timeout);
          }),
        ]);
        return {ok: true, value};
      } catch (error) { return {ok: false, error: String(error)}; }
      finally { clearTimeout(timer); }
    }""", [command, arguments or {}, timeout_ms])
    if not result["ok"]:
        raise RuntimeError(result["error"])
    return result["value"]


def expect_rejected(page: Page, command: str, arguments: dict, pattern: str) -> str:
    try:
        native_call(page, command, arguments)
    except RuntimeError as error:
        assert re.search(pattern, str(error), re.IGNORECASE), str(error)
        return str(error)
    raise AssertionError(f"the real host unexpectedly accepted {command}")


def read_review_programs(page: Page, *, marker: str | None = None) -> list[dict]:
    card = marketplace(page).get_by_test_id("marketplace-review-card")
    expect(card).to_be_visible(timeout=75_000)
    expect(card.get_by_test_id("marketplace-unverified-notice")).to_be_visible()
    expect(card.get_by_test_id("marketplace-official-badge")).to_have_count(0)
    assert card.locator("ul li").all_text_contents() == ["languageServer.launch"]
    declaration = card.locator("pre")
    if not declaration.is_visible():
        card.get_by_test_id("marketplace-review-programs-toggle").click()
    expect(declaration).to_be_visible(timeout=5_000)
    programs = json.loads(declaration.inner_text(timeout=5_000))
    if marker is not None:
        # This is the fixture's expected public review contract, including the
        # discovered runtime, every argument and the empty validation probe.
        expected = [
            {"kind": "runtime", "tool": "node"},
            {"kind": "runtimeLanguageServer", "tool": "node", "packagedRuntime": None,
             "entry": "server/fake-lsp-server.mjs", "runtimeArguments": [],
             "arguments": ["--stdio", "--state-dir", "${workspaceStateDir}",
                           "--fixture-version", marker], "validationArguments": [],
             "languageID": "litheaccept"},
        ]
        canonical = lambda entries: sorted(json.dumps(item, sort_keys=True) for item in entries)
        assert canonical(programs) == canonical(expected), programs
    return programs


class MarketplaceAcceptance:
    def __init__(self, driver, args, reporter, page: Page, restart, owned_fixture_pids: set[int]):
        self.driver = driver
        self.args = args
        self.reporter = reporter
        self.page = page
        self.restart = restart
        self.pids = owned_fixture_pids
        self.evidence = args.artifact_root.resolve() / "marketplace"
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.operations: set[str] = set()

    def sources(self):
        return native_call(self.page, "declarative_marketplace_sources_state")["sources"]

    def indexes(self):
        return native_call(self.page, "declarative_marketplace_list")

    def source(self, url: str):
        return next((item for item in self.sources() if item["indexURL"].lower() == url.lower()), None)

    def add_source(self, url: str):
        form = settings(self.page).get_by_test_id("declarative-marketplace-sources")
        form.locator("input[type='text']").fill(url)
        form.get_by_role("button", name="Add source", exact=True).click()
        source = self.driver.wait_until(lambda: self.source(url), 15, "the UI-added native source")
        expect(source_row(self.page, source["id"])).to_be_visible(timeout=15_000)
        return source

    def enable_source(self, source_id: str, enabled: bool):
        toggle = source_row(self.page, source_id).get_by_role("switch")
        expect(toggle).to_be_enabled(timeout=15_000)
        if toggle.get_attribute("aria-checked") != str(enabled).lower():
            toggle.click()
        expect(toggle).to_have_attribute("aria-checked", str(enabled).lower(), timeout=15_000)
        self.driver.wait_until(lambda: any(item["id"] == source_id and item["isEnabled"] is enabled
                                          for item in self.sources()), 15, "native source enabled state")

    def remove_source(self, source_id: str):
        row = source_row(self.page, source_id)
        row.get_by_role("button", name="Remove", exact=True).click(timeout=15_000)
        expect(row).to_have_count(0, timeout=15_000)
        assert all(item["id"] != source_id for item in self.sources())

    def refresh(self, source_id: str, *, digest: str | None = None):
        choose_source(self.page, source_id)
        button = marketplace(self.page).get_by_test_id("marketplace-refresh-button")
        expect(button).to_be_enabled(timeout=15_000)
        button.click()
        def ready():
            item = next((item for item in self.indexes() if item["sourceId"] == source_id), None)
            if not item or item["index"] is None:
                return None
            if digest is not None and not any(plugin.get("availability", {}).get("sha256") == digest
                                              for plugin in item["index"]["plugins"]):
                return None
            return item["index"]
        index = self.driver.wait_until(ready, 75, "Core-validated HTTPS source cache")
        expect(button).to_have_text("Refresh", timeout=75_000)
        expect(marketplace(self.page).get_by_test_id(f"marketplace-source-status-{source_id}")
               .get_by_role("alert")).to_have_count(0)
        self.driver.write_json(self.evidence / f"index-{source_id}.json", index)
        return index

    def search(self, index: dict):
        field = marketplace(self.page).get_by_test_id("marketplace-search-input")
        if index["plugins"]:
            first = index["plugins"][0]
            field.fill(first["name"])
            expect(offer_row(self.page, first["id"])).to_be_visible()
        field.fill("lithe-acceptance-no-match-" + uuid.uuid4().hex)
        expect(marketplace(self.page).get_by_test_id("marketplace-empty")).to_be_visible()
        field.fill("")

    def operation(self) -> str:
        value = "acceptance-" + uuid.uuid4().hex
        self.operations.add(value)
        return value

    def prepare(self, source_id: str):
        operation = self.operation()
        return native_call(self.page, "declarative_marketplace_prepare", {
            "operationId": operation, "sourceId": source_id, "pluginId": self.driver.PLUGIN_ID,
        })

    def cancel(self, operation: str):
        native_call(self.page, "declarative_marketplace_cancel", {"operationId": operation})
        self.operations.discard(operation)

    def no_snapshots(self):
        root = self.args.app_local_data / "plugin-temp"
        self.driver.wait_until(lambda: not root.exists() or not any(root.iterdir()),
                               15, "cancelled marketplace downloads and snapshots")

    def no_install(self):
        assert not (self.args.app_local_data / "plugins" / self.driver.PLUGIN_ID).exists()
        self.no_snapshots()

    def ui_prepare(self, source_id: str):
        choose_source(self.page, source_id)
        row = offer_row(self.page, self.driver.PLUGIN_ID)
        row.get_by_test_id(f"marketplace-install-{self.driver.PLUGIN_ID}").click(timeout=15_000)
        card = marketplace(self.page).get_by_test_id("marketplace-review-card")
        result = marketplace(self.page).locator(
            "[data-testid='marketplace-review-card'], "
            f"[data-testid='marketplace-plugin-{self.driver.PLUGIN_ID}'] [role='alert']"
        )
        result.first.wait_for(state="visible", timeout=75_000)
        assert card.is_visible(), row.inner_text(timeout=5_000)
        return card

    def assert_record(self, source: dict, asset: dict, programs: list[dict] | None = None):
        record = self.driver.installation_record(self.args.app_local_data)
        market = record["marketplace"]
        assert record["schemaVersion"] == 2 and record["origin"] == "community"
        assert record.get("disk") is None
        assert record["version"] == asset["version"]
        assert market["sourceId"] == source["id"] and market["indexUrl"] == source["indexURL"]
        assert market["archiveSha256"] == asset["sha256"]
        assert market["archiveUrl"].endswith("/" + asset["file"])
        assert re.fullmatch(r"[0-9a-f]{64}", market["contentDigest"])
        if programs is not None:
            approved = [json.loads(program) for program in market["approvedPrograms"]]
            assert sorted(json.dumps(p, sort_keys=True) for p in approved) == sorted(
                json.dumps(p, sort_keys=True) for p in programs)
        assert self.driver.active_fixture_marker(self.args.app_local_data, asset["version"]) == asset["marker"]
        self.driver.write_json(self.evidence / f"installation-{asset['version']}.json", record)
        return record

    def confirm_rejected(self, review: dict, pattern: str, *, approved=True, digest=None):
        try:
            return expect_rejected(self.page, "declarative_marketplace_confirm", {
                "operationId": review["operationId"], "approved": approved,
                "manifestDigest": review["prepared"]["manifestDigest"] if digest is None else digest,
            }, pattern)
        finally:
            self.cancel(review["operationId"])

    def run_public(self):
        self.driver.open_plugin_settings(self.page)
        with self.reporter.step(PUBLIC_CASES[0]):
            current = self.sources()
            public_indexes = []
            for url in PUBLIC_SOURCES:
                source = next((item for item in current if item["indexURL"] == url), None)
                assert source is not None, f"the public preset is missing: {url}"
                self.enable_source(source["id"], True)
                index = self.refresh(source["id"])
                self.search(index)
                public_indexes.append({"source": source, "index": index})
                for plugin in index["plugins"]:
                    row = offer_row(self.page, plugin["id"])
                    expect(row).to_be_visible()
                    if plugin["availability"]["status"] != "available":
                        expect(row.get_by_test_id(f"marketplace-install-{plugin['id']}")).to_have_count(0)
            self.driver.write_json(self.evidence / "public-catalogs.json", public_indexes)
        with self.reporter.step(PUBLIC_CASES[1]):
            official = next(item for item in self.sources() if item["isOfficial"])
            expect(source_row(self.page, official["id"]).get_by_role("button", name="Remove", exact=True)).to_have_count(0)
            expect_rejected(self.page, "declarative_marketplace_sources_remove", {
                "sourceId": official["id"],
            }, "officialSourceCannotBeRemoved")
            community = self.source(PUBLIC_SOURCES[1])
            self.enable_source(community["id"], False)
            self.driver.wait_until(lambda: all(item["sourceId"] != community["id"] for item in self.indexes()),
                                   15, "disabled public source to leave the catalog")
            self.enable_source(community["id"], True)
            self.remove_source(community["id"])
            added = self.add_source(PUBLIC_SOURCES[1])
            assert added["id"] == community["id"]

    def late_prepare(self, fixture: FixtureCatalog, source: dict, *, remove: bool):
        gate = fixture.gate_next_archive()
        operation = self.operation()
        # Start one genuine host request without awaiting it. Observation lives
        # in a separate JS slot; invoke and its result are never replaced.
        self.page.evaluate("""([operationId, sourceId, pluginId]) => {
          window.__marketplaceAcceptanceResult = {done: false};
          window.__TAURI_INTERNALS__.invoke('declarative_marketplace_prepare',
            {operationId, sourceId, pluginId}).then(
              value => { window.__marketplaceAcceptanceResult = {done: true, ok: true, value}; },
              error => { window.__marketplaceAcceptanceResult = {done: true, ok: false, error: String(error)}; },
          );
        }""", [operation, source["id"], self.driver.PLUGIN_ID])
        try:
            assert gate.arrived.wait(timeout=10), "the real HTTPS archive request did not reach the fixture"
            if remove:
                self.remove_source(source["id"])
            else:
                self.enable_source(source["id"], False)
            self.page.wait_for_function("() => window.__marketplaceAcceptanceResult?.done", timeout=15_000)
            result = self.page.evaluate("() => window.__marketplaceAcceptanceResult")
            assert not result["ok"] and "cancel" in result["error"].lower(), result
            self.driver.write_json(self.evidence / f"late-prepare-{'removed' if remove else 'disabled'}.json", result)
        finally:
            gate.release.set()
            self.cancel(operation)
            assert gate.finished.wait(timeout=6), "the gated archive handler survived cancellation"
        self.no_install()

    def late_ui_prepare(self, fixture: FixtureCatalog, source: dict, other: dict, mode: str):
        """Hold real HTTPS bytes until the UI has released its owning context."""
        if mode not in ("cancel", "scope", "dispose"):
            raise ValueError(f"unsupported late UI action: {mode}")
        gate = fixture.gate_next_archive()
        try:
            choose_source(self.page, source["id"])
            row = offer_row(self.page, self.driver.PLUGIN_ID)
            row.get_by_test_id(f"marketplace-install-{self.driver.PLUGIN_ID}").click(timeout=15_000)
            assert gate.arrived.wait(timeout=10), "the UI's real archive request did not reach the fixture"
            if mode == "cancel":
                row.get_by_role("button", name="Cancel", exact=True).click(timeout=15_000)
            elif mode == "scope":
                choose_source(self.page, other["id"])
            elif mode == "dispose":
                self.driver.close_settings(self.page)
        except Exception:
            # Unmounting the page releases its own native operation even if
            # the assertion failed before we could click the expected action.
            self.driver.close_settings(self.page)
            raise
        finally:
            gate.release.set()
            # If starting the request itself failed, teardown owns the unused
            # gate. A request that arrived must release its active handler here.
            if gate.arrived.is_set():
                assert gate.finished.wait(timeout=6), "the UI's gated archive handler survived cancellation"
        self.no_install()
        self.driver.open_plugin_settings(self.page)
        choose_source(self.page, source["id"])
        expect(marketplace(self.page).get_by_test_id("marketplace-review-card")).to_have_count(0)
        expect(offer_row(self.page, self.driver.PLUGIN_ID)
               .get_by_test_id(f"marketplace-install-{self.driver.PLUGIN_ID}")).to_be_enabled(timeout=15_000)
        self.driver.write_json(self.evidence / f"late-ui-{mode}.json", {
            "action": mode, "archiveRequestReachedFixture": True,
            "reviewAfterRelease": False, "installedPackageAfterRelease": False,
        })

    def run_controlled(self, fixture: FixtureCatalog):
        assets = fixture.plan["assets"]
        urls = [f"{fixture.base}/source-{name}/index.json" for name in ("a", "b")]
        with self.reporter.step(CONTROLLED_CASES[0]):
            for source in self.sources():
                if source["isEnabled"]:
                    self.enable_source(source["id"], False)
            a, b = (self.add_source(url) for url in urls)
            self.enable_source(a["id"], False)
            self.enable_source(a["id"], True)
            self.remove_source(b["id"])
            b = self.add_source(urls[1])
            index = self.refresh(a["id"], digest=assets["a1"]["sha256"])
            self.refresh(b["id"], digest=assets["b9"]["sha256"])
            choose_source(self.page, "all")
            expect(offer_row(self.page, self.driver.PLUGIN_ID)).to_have_count(1)
            expect(offer_row(self.page, self.driver.PLUGIN_ID)).to_contain_text("1.0.0")
            choose_source(self.page, b["id"])
            expect(offer_row(self.page, self.driver.PLUGIN_ID)).to_contain_text("9.0.0")
            choose_source(self.page, a["id"])
            self.search(index)
        with self.reporter.step(CONTROLLED_CASES[1]):
            review = self.prepare(a["id"])
            assert review["requiresConfirmation"] is True
            assert review["officialPublisherVerified"] is False
            self.confirm_rejected(review, "explicit approval is required", approved=False)
            self.no_install()
            self.confirm_rejected(self.prepare(a["id"]), "review digest does not match", digest="0" * 64)
            self.no_install()
        with self.reporter.step(CONTROLLED_CASES[2]):
            card = self.ui_prepare(a["id"])
            read_review_programs(self.page, marker=assets["a1"]["marker"])
            card.get_by_test_id("marketplace-review-cancel").click()
            expect(card).to_have_count(0)
            self.no_install()
            card = self.ui_prepare(a["id"])
            choose_source(self.page, b["id"])
            expect(card).to_have_count(0)
            self.no_install()
        with self.reporter.step(LATE_UI_CASE):
            for mode in ("cancel", "scope", "dispose"):
                self.late_ui_prepare(fixture, a, b, mode)
        with self.reporter.step(CONTROLLED_CASES[3]):
            self.late_prepare(fixture, a, remove=False)
            self.enable_source(a["id"], True)
            self.late_prepare(fixture, a, remove=True)
            a = self.add_source(urls[0])
            self.refresh(a["id"], digest=assets["a1"]["sha256"])
            # Cancellation may arrive before registration too.
            operation = self.operation()
            self.cancel(operation)
            expect_rejected(self.page, "declarative_marketplace_prepare", {
                "operationId": operation, "sourceId": a["id"], "pluginId": self.driver.PLUGIN_ID,
            }, "cancel")
            self.no_install()
        with self.reporter.step(CONTROLLED_CASES[4]):
            card = self.ui_prepare(a["id"])
            assert a["indexURL"] in card.inner_text()
            programs = read_review_programs(self.page, marker=assets["a1"]["marker"])
            card.get_by_test_id("marketplace-review-confirm").click()
            expect(card).to_have_count(0, timeout=45_000)
            self.driver.wait_catalog(self.page, "1.0.0", True)
            self.assert_record(a, assets["a1"], programs)
        with self.reporter.step(CONTROLLED_CASES[5]):
            self.page = self.restart()
            self.driver.open_plugin_settings(self.page)
            self.driver.wait_catalog(self.page, "1.0.0", True)
            self.assert_record(a, assets["a1"], programs)
            assert self.source(urls[0])["id"] == a["id"]
        with self.reporter.step(CONTROLLED_CASES[6]):
            choose_source(self.page, b["id"])
            expect(offer_row(self.page, self.driver.PLUGIN_ID)
                   .get_by_test_id(f"marketplace-install-{self.driver.PLUGIN_ID}")).to_have_count(0)
            operation = self.operation()
            expect_rejected(self.page, "declarative_marketplace_prepare", {
                "operationId": operation, "sourceId": b["id"], "pluginId": self.driver.PLUGIN_ID,
            }, "source|marketplace")
            self.cancel(operation)
            self.assert_record(a, assets["a1"])
        with self.reporter.step(CONTROLLED_CASES[7]):
            for phase, digest, pattern in (
                ("bad-digest", "0" * 64, "SHA-256|sha256|digest|hash"),
                ("bad-signature", assets["untrusted"]["sha256"], "signature|signing|key|publisher"),
            ):
                fixture.stage(phase)
                self.refresh(a["id"], digest=digest)
                operation = self.operation()
                error = expect_rejected(self.page, "declarative_marketplace_prepare", {
                    "operationId": operation, "sourceId": a["id"], "pluginId": self.driver.PLUGIN_ID,
                }, pattern)
                self.driver.write_json(self.evidence / f"rejected-{phase}.json", {"error": error})
                self.cancel(operation)
                self.no_snapshots()
                self.assert_record(a, assets["a1"])
        fixture.stage("update")
        self.refresh(a["id"], digest=assets["a2"]["sha256"])
        with self.reporter.step(CONTROLLED_CASES[8]):
            review = self.prepare(a["id"])
            self.refresh(a["id"], digest=assets["a2"]["sha256"])
            self.confirm_rejected(review, "changed|cancel|no longer|pending|unknown")
            self.assert_record(a, assets["a1"])
        with self.reporter.step(CONTROLLED_CASES[9]):
            self.driver.close_settings(self.page)
            self.driver.open_fixture_file(self.page)
            state = self.args.app_local_data / "plugin-state" / self.driver.PLUGIN_ID
            live = self.driver.wait_for_server_count(state, 2)
            self.pids.update(live)
            self.driver.open_plugin_settings(self.page)
            self.driver.set_plugin_enabled(self.page, False)
            self.driver.wait_pids_dead(live, "marketplace plugin disable")
            choose_source(self.page, "all")
            # A newer 9.0.0 offer cannot displace the installed source's 1.1.0.
            row = offer_row(self.page, self.driver.PLUGIN_ID)
            expect(row).to_contain_text("1.1.0")
            expect(row).not_to_contain_text("9.0.0")
            card = self.ui_prepare(a["id"])
            programs = read_review_programs(self.page, marker=assets["a2"]["marker"])
            card.get_by_test_id("marketplace-review-confirm").click()
            expect(card).to_have_count(0, timeout=45_000)
            self.driver.wait_catalog(self.page, "1.1.0", False)
            assert self.assert_record(a, assets["a2"], programs)["enabled"] is False
        with self.reporter.step(CONTROLLED_CASES[10]):
            self.driver.set_plugin_enabled(self.page, True)
            self.driver.open_fixture_file(self.page)
            live = self.driver.wait_for_server_count(state, 2)
            self.pids.update(live)
            self.driver.open_plugin_settings(self.page)
            stale = self.prepare(a["id"])
            details = self.driver.select_plugin_details(self.page)
            details.get_by_role("button", name="Uninstall", exact=True).click()
            expect(self.driver.plugin_row(self.page)).to_have_count(0, timeout=45_000)
            self.driver.wait_pids_dead(live, "marketplace plugin uninstall")
            self.confirm_rejected(stale, "changed|cancel|no longer|pending|unknown")
            assert not state.exists()
            self.no_install()

    def run(self):
        self.reporter.document_pending(SIGNATURE_GAP,
            "Requires a real Windows artifact signed by the pinned official publisher. Fixture packages are unsigned third-party packages and never establish official-publisher acceptance.")
        try:
            self.run_public()
            if self.args.marketplace_fixture_root is None:
                for name in CONTROLLED_CASES:
                    self.reporter.document_pending(name,
                        "Needs marketplace_fixture.py generate output plus a reachable HTTPS hostname and an already-trusted certificate/key. No trust-store changes or TLS bypass are permitted.")
            else:
                fixture = FixtureCatalog(self.args.marketplace_fixture_root.resolve())
                with FixtureServer.native(fixture, self.args.marketplace_tls_cert,
                                          self.args.marketplace_tls_key, self.args.marketplace_listen_host):
                    try:
                        self.run_controlled(fixture)
                    finally:
                        self.driver.write_json(self.evidence / "fixture-requests.json", fixture.requests)
        finally:
            cleanup_errors = []
            for operation in list(self.operations):
                try:
                    self.cancel(operation)
                except Exception as error:
                    cleanup_errors.append(str(error))
            if cleanup_errors:
                raise RuntimeError("marketplace operation cleanup failed: " + "; ".join(cleanup_errors))


def record_unreached_cases(reporter) -> None:
    completed = {test["name"] for test in reporter.tests}
    for name in PUBLIC_CASES + CONTROLLED_CASES + (SIGNATURE_GAP,):
        if name not in completed:
            reporter.document_pending(name, "An earlier acceptance case failed; this native marketplace case was not executed.")
