#!/usr/bin/env python3
"""Deterministic marketplace inputs; TLS and publisher trust stay production-owned.

Generated files are disposable test inputs under the caller's artifact directory,
never a reusable build cache or installed resource. Native serving requires an
existing certificate trusted for the supplied HTTPS hostname. This module neither
creates certificates nor modifies client trust, DNS, or the production transport.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import ssl
import threading
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from generate_packages import DISPLAY_NAME, PLUGIN_ID, write_package


PUBLIC_SOURCES = (
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json",
)
PHASES = ("initial", "update", "bad-digest", "bad-signature")
MAX_INDEX_BYTES = 1024 * 1024


def https_base(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or any(part in (".", "..") for part in parsed.path.split("/"))):
        raise ValueError("the fixture needs a credential-free HTTPS base URL without query/fragment")
    if parsed.port == 0:
        raise ValueError("the public HTTPS endpoint needs a fixed port")
    return value.rstrip("/")


def json_bytes(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def entry(base: str, version: str, archive_name: str, digest: str) -> dict:
    return {
        "id": PLUGIN_ID, "name": DISPLAY_NAME, "author": "Lithe acceptance fixture",
        "repository": "https://github.com/example/lithe-marketplace-acceptance",
        "description": "Controlled Windows marketplace acceptance fixture",
        "tags": ["acceptance", "language"], "license": "MIT",
        "versions": [{"version": version, "pluginAPIVersion": 2,
                      "releaseDate": "2026-01-01", "downloads": [{
                          "platforms": ["windows-x64"],
                          "downloadURL": f"{base}/packages/{archive_name}", "sha256": digest,
                      }]}],
    }


def generate_fixture(output: Path, base_url: str, server_source: Path) -> dict:
    base = https_base(base_url)
    # Never clear an existing directory: it may contain another run's evidence.
    output.mkdir(parents=True, exist_ok=False)
    packages = output / "packages"
    packages.mkdir()
    specs = (("a1", "1.0.0", "market-a-1"), ("a2", "1.1.0", "market-a-2"),
             ("b9", "9.0.0", "market-b-9"), ("untrusted", "1.2.0", "market-untrusted"))
    assets = {}
    for name, version, marker in specs:
        path = write_package(packages, server_source, name, version, marker)
        if name == "untrusted":
            # An untrusted publisher document must be rejected even for an
            # otherwise unsigned community package; no test key is trusted.
            with zipfile.ZipFile(path, "a", compression=zipfile.ZIP_DEFLATED) as archive:
                info = zipfile.ZipInfo("lithe-plugin-signature.json", (2026, 1, 1, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                archive.writestr(info, json_bytes({
                    "schemaVersion": 1, "algorithm": "ed25519", "keyId": "acceptance-untrusted",
                    "pluginId": PLUGIN_ID, "pluginVersion": version, "files": {},
                    "signature": "AA==",
                }))
        assets[name] = {"file": f"packages/{name}.zip", "version": version, "marker": marker,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    indexes = {}
    for phase, asset_name in zip(PHASES, ("a1", "a2", "a2", "untrusted")):
        asset = assets[asset_name]
        digest = "0" * 64 if phase == "bad-digest" else asset["sha256"]
        indexes[phase] = {"schemaVersion": 1, "plugins": [
            entry(base, asset["version"], Path(asset["file"]).name, digest),
        ]}
    b = assets["b9"]
    plan = {"schemaVersion": 1, "baseURL": base, "pluginId": PLUGIN_ID,
            "assets": assets, "indexes": indexes,
            "competingIndex": {"schemaVersion": 1, "plugins": [
                entry(base, b["version"], "b9.zip", b["sha256"]),
            ]},
            "trust": "unsigned third-party fixture; explicit native approval required; never official"}
    (output / "plan.json").write_bytes(json_bytes(plan))
    return plan


class RequestGate:
    """The test owns arrival/release; a broken scenario cannot hold a server forever."""

    def __init__(self):
        self.arrived = threading.Event()
        self.release = threading.Event()
        self.finished = threading.Event()


class FixtureCatalog:
    def __init__(self, root: Path):
        self.plan = json.loads((root / "plan.json").read_text(encoding="utf-8"))
        if self.plan.get("schemaVersion") != 1 or self.plan.get("pluginId") != PLUGIN_ID:
            raise ValueError("unsupported marketplace fixture plan")
        self.base = https_base(self.plan["baseURL"])
        self.prefix = urllib.parse.urlsplit(self.base).path
        self.assets = {}
        for name, asset in self.plan["assets"].items():
            if name not in ("a1", "a2", "b9", "untrusted") or asset["file"] != f"packages/{name}.zip":
                raise ValueError("unexpected fixture asset path")
            path = root / asset["file"]
            if path.is_symlink() or path.parent.is_symlink() or path.parent.is_junction():
                raise ValueError("fixture archives cannot be linked outside the fixture root")
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != asset["sha256"]:
                raise ValueError(f"fixture archive changed: {name}")
            self.assets[f"{self.prefix}/{asset['file']}"] = data
        if set(self.plan["indexes"]) != set(PHASES):
            raise ValueError("the fixture is missing a required index phase")
        self.phase = "initial"
        self.lock = threading.Lock()
        self.gates: dict[str, RequestGate] = {}
        self.requests: list[dict] = []

    def stage(self, phase: str) -> None:
        if phase not in PHASES:
            raise ValueError(f"unknown fixture phase: {phase}")
        with self.lock:
            self.phase = phase

    def gate_next_archive(self, name: str = "a1") -> RequestGate:
        path = f"{self.prefix}/packages/{name}.zip"
        with self.lock:
            if path not in self.assets or path in self.gates:
                raise ValueError("unknown or already gated archive")
            gate = RequestGate()
            self.gates[path] = gate
            return gate

    def response(self, path: str):
        with self.lock:
            self.requests.append({"path": path, "phase": self.phase})
            gate = self.gates.pop(path, None)
            if path == f"{self.prefix}/source-a/index.json":
                return json_bytes(self.plan["indexes"][self.phase]), "application/json", gate
            if path == f"{self.prefix}/source-b/index.json":
                return json_bytes(self.plan["competingIndex"]), "application/json", gate
            return self.assets.get(path), "application/zip", gate


class FixtureServer:
    """Own one bounded listener thread. HTTP without TLS is only used by unit tests.

    Native callers must use `native`; it has no HTTP mode, extra client roots,
    certificate-ignore option, or public control endpoint. Staging and gates are
    local Python objects, so downloaded content cannot control the test host.
    """

    def __init__(self, catalog: FixtureCatalog, address, tls_context: ssl.SSLContext | None):
        self.catalog = catalog
        self.stop = threading.Event()
        self.active_socket = None
        self.active_gate = None
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                data, content_type, gate = catalog.response(self.path)
                if data is None:
                    self.send_error(404)
                    return
                owner.active_gate = gate
                try:
                    if gate is not None:
                        gate.arrived.set()
                        if not gate.release.wait(timeout=30):
                            self.send_error(504, "fixture gate exceeded its local deadline")
                            return
                    if owner.stop.is_set():
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(data)
                except (ConnectionError, OSError):
                    # Cancellation deliberately closes the native download.
                    pass
                finally:
                    if gate is not None:
                        gate.finished.set()
                    owner.active_gate = None

            def log_message(self, _format, *_args):
                pass

        class Server(HTTPServer):
            def get_request(self):
                connection, client = super().get_request()
                connection.settimeout(5)
                owner.active_socket = connection
                try:
                    if tls_context is not None:
                        connection = tls_context.wrap_socket(connection, server_side=True,
                                                             do_handshake_on_connect=False)
                        owner.active_socket = connection
                        connection.do_handshake()
                    return connection, client
                except Exception:
                    connection.close()
                    owner.active_socket = None
                    raise

            def handle_error(self, _request, _client):
                owner.errors.append("fixture request handler failed")

            def close_request(self, request):
                super().close_request(request)
                owner.active_socket = None

        self.server = Server(address, Handler)
        self.server.timeout = 0.1
        self.thread = threading.Thread(target=self._run, name="marketplace-fixture-server")

    @classmethod
    def native(cls, catalog: FixtureCatalog, cert: Path, key: Path, listen_host: str):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert, keyfile=key)
        port = urllib.parse.urlsplit(catalog.base).port or 443
        return cls(catalog, (listen_host, port), context)

    def _run(self):
        while not self.stop.is_set():
            self.server.handle_request()

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.stop.set()
        if self.active_gate is not None:
            self.active_gate.release.set()
        connection = self.active_socket
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(timeout=6)
        self.server.server_close()
        if self.thread.is_alive():
            raise RuntimeError("the fixture listener survived its six-second cleanup deadline")
        if self.errors:
            raise RuntimeError("; ".join(self.errors))


class HttpsRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        https_base(url)
        return super().redirect_request(request, response, code, message, headers, url)


def probe_public_sources() -> dict:
    """Network inventory only; neither Core validation nor native acceptance."""
    opener = urllib.request.build_opener(HttpsRedirects())
    results = []
    for url in PUBLIC_SOURCES:
        result = {"url": url, "nativeAcceptance": False}
        try:
            with opener.open(url, timeout=10) as response:
                data = response.read(MAX_INDEX_BYTES + 1)
            if len(data) > MAX_INDEX_BYTES:
                raise ValueError("public index exceeds the probe's byte limit")
            document = json.loads(data)
            windows = []
            for plugin in document["plugins"]:
                for version in plugin.get("versions", []):
                    for download in version.get("downloads", []):
                        if "windows-x64" in download.get("platforms", []):
                            windows.append({"id": plugin["id"], "version": version["version"]})
            result.update(sha256=hashlib.sha256(data).hexdigest(),
                          pluginCount=len(document["plugins"]), windowsX64Downloads=windows)
        except Exception as error:
            result["error"] = f"{type(error).__name__}: {error}"
        results.append(result)
    return {"kind": "HTTPS index inventory; no product was launched", "sources": results}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    generate = sub.add_parser("generate")
    generate.add_argument("--output", required=True, type=Path)
    generate.add_argument("--base-url", required=True)
    generate.add_argument("--server", type=Path, default=Path(__file__).with_name("fake-lsp-server.mjs"))
    probe = sub.add_parser("probe-public")
    probe.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        generate_fixture(args.output.resolve(), args.base_url, args.server.resolve())
        print(f"Fixture prepared: {args.output.resolve() / 'plan.json'}; native execution remains pending")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(json_bytes(probe_public_sources()))
        print(f"Public HTTPS inventory: {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
