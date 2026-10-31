"""Optional real-editor LSP lifecycle checks for the native acceptance driver.

Events are evidence only after an action's byte offsets, for the exact document
and package marker, and from a currently live fixture whose native identity the
driver retained. PID counts alone never establish editor attachment.
"""

from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from playwright.sync_api import expect


REOPEN_CASE = "LSP existing editor closes and immediately reopens three times"
GATE_CASE = "LSP initialize gate survives closing and reopening the same editor"
RETAINED_CASES = tuple(f"LSP retained editor reattaches after {action}" for action in
                       ("disable and enable", "same-version replacement", "update", "rollback"))
CASES = (REOPEN_CASE, GATE_CASE, *RETAINED_CASES)


def scoped_event_files(state_root: Path):
    root = state_root.resolve()
    if not root.exists():
        return []
    result = []
    for candidate in root.rglob("events.jsonl"):
        if candidate.is_symlink() or not candidate.is_file():
            raise ValueError("a fixture event log must be an ordinary owned file")
        actual = candidate.resolve()
        if root not in actual.parents:
            raise ValueError("a fixture event log escaped its plugin state root")
        result.append(actual)
    return sorted(result)


def event_offsets(state_root: Path) -> dict[str, int]:
    root = state_root.resolve()
    return {str(path.relative_to(root)): path.stat().st_size for path in scoped_event_files(root)}


def events_after(state_root: Path, offsets: dict[str, int]):
    root = state_root.resolve()
    result = []
    for path in scoped_event_files(root):
        offset = offsets.get(str(path.relative_to(root)), 0)
        if offset < 0 or path.stat().st_size < offset:
            raise ValueError("a fixture event log was truncated after its action snapshot")
        with path.open("rb") as stream:
            stream.seek(offset)
            data = stream.read()
        # A concurrent append may expose a partial final line. Only completed
        # JSON records count; malformed completed records remain a hard error.
        for line in data.split(b"\n")[:-1]:
            if line:
                event = json.loads(line.decode("utf-8"))
                if not isinstance(event, dict):
                    raise ValueError("a fixture event must be an object")
                result.append({**event, "stateDirectory": str(path.parent)})
    return result


def canonical_file_uri(uri: str) -> str | None:
    value = urllib.parse.urlsplit(uri)
    if value.scheme != "file" or value.netloc not in ("", "localhost") or value.query or value.fragment:
        return None
    return os.path.normcase(str(Path(urllib.request.url2pathname(value.path)).resolve()))


def matching_did_open(events, marker: str, uri: str, live: set[int], identity_live):
    expected = canonical_file_uri(uri)
    if expected is None:
        raise ValueError("the acceptance target must be a local file URI")
    for event in events:
        pid = event.get("pid")
        if (event.get("event") == "message" and event.get("method") == "textDocument/didOpen"
                and event.get("fixtureVersion") == marker
                and isinstance(event.get("uri"), str)
                and canonical_file_uri(event["uri"]) == expected
                and isinstance(event.get("documentVersion"), int)
                and event["documentVersion"] >= 0
                and pid in live and identity_live(pid)):
            return event
    return None


class InitializeGate:
    """One bounded server gate in writable per-workspace plugin state."""

    def __init__(self, state_directory: Path, state_root: Path):
        self.directory = state_directory.resolve()
        if state_root.resolve() not in self.directory.parents:
            raise ValueError("initialize gates must stay below this plugin's state root")
        if not self.directory.is_dir() or self.directory.is_symlink():
            raise ValueError("initialize gates require an existing ordinary workspace state directory")
        self.token = uuid.uuid4().hex
        self.path = self.directory / "lsp-initialize-gate.json"
        self.release_path = self.directory / f"lsp-initialize-release-{self.token}"

    def __enter__(self):
        with self.path.open("x", encoding="utf-8") as stream:
            json.dump({"schemaVersion": 1, "token": self.token}, stream)
        return self

    def release(self):
        self.release_path.touch(exist_ok=True)

    def __exit__(self, *_):
        # Release first on failures so no live fixture can retain a watcher.
        self.release()
        self.path.unlink(missing_ok=True)
        # The release marker stays until plugin-state teardown. A late reader
        # that already consumed the config must still see its release token.


class LspLifecycleAcceptance:
    def __init__(self, driver, args, reporter, owned_pids: set[int]):
        self.driver = driver
        self.args = args
        self.reporter = reporter
        self.owned_pids = owned_pids
        self.state_root = args.app_local_data / "plugin-state" / driver.PLUGIN_ID
        self.target = args.workspace_one.resolve() / "acceptance.litheaccept"
        self.uri = self.target.as_uri()
        self.evidence = args.artifact_root.resolve() / "lsp-lifecycle"
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.last_open = None

    def snapshot(self):
        return event_offsets(self.state_root)

    def require_did_open(self, offsets, marker: str, name: str):
        def ready():
            live = self.driver.live_fixture_pids(self.state_root)
            self.owned_pids.update(live)
            event = matching_did_open(events_after(self.state_root, offsets), marker, self.uri, live,
                                      lambda pid: self.driver.fixture_processes[pid].running())
            return event
        event = self.driver.wait_until(ready, 30, f"a fresh owned didOpen for {name}")
        self.last_open = event
        self.driver.write_json(self.evidence / (re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") + ".json"),
                               {"offsets": offsets, "expectedURI": self.uri, "expectedMarker": marker, "didOpen": event})
        return event

    def select_existing(self, page):
        self.driver.close_settings(page)
        tab = page.get_by_role("tab", name=re.compile(r"^acceptance\.litheaccept"))
        expect(tab).to_have_count(1, timeout=15_000)
        tab.click()
        expect(tab).to_have_attribute("aria-selected", "true", timeout=15_000)

    def close_reopen(self, page):
        self.select_existing(page)
        tab = page.get_by_role("tab", name=re.compile(r"^acceptance\.litheaccept"))
        tab.hover()
        tab.get_by_role("button").click()
        expect(tab).to_have_count(0, timeout=15_000)
        self.driver.open_fixture_file(page)

    def repeat_reopen(self, page, marker: str):
        with self.reporter.step(REOPEN_CASE):
            for iteration in range(3):
                offsets = self.snapshot()
                self.close_reopen(page)
                self.require_did_open(offsets, marker, f"close-reopen-{iteration + 1}")

    def retained(self, page, marker: str, action: str, offsets):
        with self.reporter.step(f"LSP retained editor reattaches after {action}"):
            self.select_existing(page)
            self.require_did_open(offsets, marker, action)

    def initialize_close_reopen(self, page, marker: str):
        if self.last_open is None:
            raise AssertionError("a verified prior didOpen is required to scope the initialize gate")
        with self.reporter.step(GATE_CASE):
            directory = Path(self.last_open["stateDirectory"])
            with InitializeGate(directory, self.state_root) as gate:
                self.driver.open_plugin_settings(page)
                self.driver.set_plugin_enabled(page, False)
                self.driver.wait_catalog(page, "1.0.0", False)
                offsets = self.snapshot()
                self.driver.set_plugin_enabled(page, True)
                self.driver.wait_catalog(page, "1.0.0", True)
                self.select_existing(page)
                gated = self.driver.wait_until(
                    lambda: next((event for event in events_after(self.state_root, offsets)
                                  if event.get("event") == "initialize-gated" and event.get("token") == gate.token
                                  and event.get("fixtureVersion") == marker), None),
                    10, "the fixture to reach its controlled initialize boundary")
                # No initialize response is possible until this exact token is
                # released. Close/reopen while the old attach is still waiting.
                self.close_reopen(page)
                gate.release()
                event = self.require_did_open(offsets, marker, "initialize-close-reopen")
                self.driver.write_json(self.evidence / "initialize-order.json", {"gated": gated, "didOpen": event})


def record_unreached_cases(reporter):
    completed = {test["name"] for test in reporter.tests}
    for name in CASES:
        if name not in completed:
            reporter.document_pending(name, "An earlier native acceptance step failed; this lifecycle case was not executed.",
                                      "plugin-host-acceptance / native-lsp-lifecycle")
