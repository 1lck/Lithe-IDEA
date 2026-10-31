#!/usr/bin/env python3
"""Fixed inputs and evidence checks for real generated Java workflow acceptance.

This module never probes tools, installs packages, or starts the product. The
coordinator supplies source-bound A/B evidence; the product still owns trust,
runtime discovery, Java project facts, compilation, and execution.
"""
from __future__ import annotations

import hashlib
import json
import re
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from build_fixture import json_bytes
from settings_functions_fixture import sha256

PLUGIN_ID = "dev.lithe.plugin.java-support"
REQUIRES = {"languages": 1, "languageServers": 1, "serverProcess": 1,
            "settings": 2, "projectGenerators": 1, "packageTrust": 1}
CASES = ("trusted-complete-package", "generate-open-real-jdk", "java-import-ready",
         "edit-save-synchronize", "prepare-launch-run-output", "stop-run-owner",
         "compile-error-refused", "product-profile-cleanup", "resource-invariance")
PENDING = {
    "maven-gradle": "Not executed: requires each complete production-trusted build package and its own workflow evidence; existing JDT integration does not establish declarative build-plugin acceptance.",
    "signed-installer-upgrade": "Not executed: signed installer, installed-directory immutability and upgrade require independent channel evidence.",
    "windows-arm64": "Not executed: this driver is x64 only; ARM64 needs a fixed native EXE, package, JDK and environment.",
    "complete-M10": "Pending: this plain Java subset cannot establish all M8/M10 capabilities.",
}


def same_path(left: str | Path, right: str | Path) -> bool:
    return str(left).replace("\\", "/").rstrip("/").casefold() == str(right).replace("\\", "/").rstrip("/").casefold()


def file_path(uri: str) -> str:
    parsed = urlsplit(uri)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise ValueError("expected a local file URI")
    path = unquote(parsed.path)
    return path[1:] if re.match(r"^/[A-Za-z]:/", path) else path


def read_reference(reference: dict, *, json_document=False):
    path = Path(reference["path"])
    if not path.is_absolute() or not re.fullmatch(r"[0-9a-f]{64}", reference["sha256"]):
        raise ValueError("input references need absolute paths and SHA256")
    if (path.stat().st_size > 2 * 1024**3 or path.is_symlink() or path.is_junction()
            or sha256(path) != reference["sha256"]):
        raise ValueError("fixed input bytes changed: " + str(path))
    if json_document and path.stat().st_size > 4 * 1024**2:
        raise ValueError("input receipt exceeds bounded JSON size")
    return json.loads(path.read_text(encoding="utf-8-sig")) if json_document else path


def validate_plan(plan: dict) -> tuple[dict, list[str]]:
    """Return the actual archive manifest and closed execution prerequisites.

    A candidate receipt is deliberately insufficient even when static helper
    tests pass. Receipts refer to original evidence, not a new trust authority.
    Native install/scan must validate the supplied package again at runtime.
    """
    if (plan.get("schemaVersion") != 1 or plan.get("kind") != "windows-plain-java-workflow"
            or not re.fullmatch(r"[0-9a-f]{40}", plan.get("sourceCommit", ""))
            or not isinstance(plan.get("sourceInventory"), dict) or not plan["sourceInventory"]):
        raise ValueError("complete fixed source identity is required")
    package = plan["package"]
    archive = read_reference(package["archive"])
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > 100_000 or sum(item.file_size for item in entries) > 2 * 1024**3:
            raise ValueError("Java package exceeds bounded inventory limits")
        if source.getinfo("plugin.json").file_size > 4 * 1024**2:
            raise ValueError("Java manifest exceeds bounded JSON size")
        raw = source.read("plugin.json")
    manifest = json.loads(raw)
    if (hashlib.sha256(raw).hexdigest() != package["manifestSha256"]
            or manifest.get("id") != PLUGIN_ID or manifest.get("requires") != package["requires"]
            or any(manifest["requires"].get(key) != level for key, level in REQUIRES.items())
            or manifest.get("vendor", {}).get("signatureRequirement") != "publisherPackage"):
        raise ValueError("complete official Java manifest/requires/trust identity mismatch")
    generator = next((item for item in manifest.get("projectGenerators", []) if item["id"] == "java"), None)
    if not generator or not any(item.get("languageID") == "java" and item.get("hostIntegration", {}).get("id") == "jdt"
                                for item in manifest.get("languageServers", [])):
        raise ValueError("complete Java generator and JDT integration are required")
    project = plan["project"]
    if (project.get("sourcePath") != "src/Main.java" or project.get("mainClass") != "Main"
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9 -]{0,60}", project.get("name", ""))
            or not project.get("configurationName")):
        raise ValueError("first workflow must use a plain generated Main project")
    jdk = plan["jdk"]
    home = Path(jdk["home"])
    if (not home.is_absolute() or not jdk.get("version") or
            sha256(home / "bin/java.exe") != jdk["javaSha256"] or
            sha256(home / "bin/javac.exe") != jdk["javacSha256"]):
        raise ValueError("real fixed JDK java/javac bytes are required")
    blocked = []
    for key, expected in (("packageEvidence", {"packageSha256": package["archive"]["sha256"],
                                              "manifestSha256": package["manifestSha256"]}),
                          ("workspaceEvidence", {"javaHome": jdk["home"], "javaVersion": jdk["version"],
                                                "javaSha256": jdk["javaSha256"]})):
        reference = plan.get(key)
        if reference is None:
            blocked.append(key + " missing")
            continue
        receipt = read_reference(reference, json_document=True)
        if (receipt.get("status") != "passed" or receipt.get("productionTrusted") is not True
                or any(receipt.get(name) != value for name, value in expected.items())
                or not receipt.get("evidence")):
            blocked.append(key + " is candidate/incomplete or has another package/JDK identity")
        else:
            for evidence in receipt["evidence"]:
                read_reference(evidence)
    return manifest, blocked


def pending_rows(reason: str) -> list[dict]:
    return [{"name": "plain-java / " + name, "suite": "plugin-host-acceptance / java-workflow",
             "status": "skipped", "durationMs": 0, "maxMs": 120_000, "details": reason}
            for name in CASES]


def assert_observer(snapshot: dict) -> list[dict]:
    if snapshot.get("dropped") or snapshot.get("errors"):
        raise AssertionError("Java IPC evidence was dropped or could not be decoded")
    return snapshot["calls"]


def core_calls(calls: list[dict], command: str) -> list[dict]:
    return [call for call in calls if call.get("core", {}).get("command") == command]


def core_value(call: dict) -> dict:
    value = call.get("value")
    if call.get("error") or not isinstance(value, dict) or value.get("ok") is not True:
        raise AssertionError("native Core call did not succeed: " + str(call))
    return value.get("data", {})


def ready_session(calls: list[dict], root: Path, package_root: Path) -> dict | None:
    for start in core_calls(calls, "lsp.startServer"):
        if not start.get("settled"):
            continue
        payload = start["core"]["payload"]
        if payload.get("pluginId") != PLUGIN_ID or not same_path(file_path(payload["rootUri"]), root):
            continue
        resources = payload.get("jdtlsLaunchResources") or {}
        # Core may assemble JDT's final arguments from typed resources. Bind
        # the actual launcher, not a substring that a sibling path can mimic.
        entries = [resources.get("launcherJarPath", ""), *payload.get("arguments", [])]
        prefix = str(package_root.resolve()).replace("\\", "/").rstrip("/").casefold() + "/"
        if not any(str(value).replace("\\", "/").casefold().startswith(prefix) for value in entries):
            raise AssertionError("Java server did not use the admitted plugin resources")
        session_id = core_value(start)["sessionId"]
        for call in core_calls(calls, "lsp.waitEvents"):
            if call["core"]["payload"].get("sessionId") != session_id or not call.get("settled"):
                continue
            data = core_value(call)
            if any(event.get("type") == "stateChanged" and event.get("state") == "ready" for event in data.get("events", [])):
                return {"sessionId": session_id, "start": start, "readiness": call}
    return None


def saved_and_synced(calls: list[dict], source: Path, content: str, session_id: str) -> dict | None:
    saves = [call for call in calls if call["command"] == "save_document_file"
             and same_path(call["args"].get("path", ""), source) and call["args"].get("content") == content
             and call.get("settled") and call.get("value", {}).get("status") == "saved"]
    for save in saves:
        for sync in core_calls(calls, "lsp.syncDocument"):
            payload = sync["core"]["payload"]
            if (payload.get("sessionId") == session_id and same_path(file_path(payload["uri"]), source)
                    and payload.get("text") == content and sync.get("settled")):
                for notified in core_calls(calls, "lsp.saveDocument"):
                    saved = notified["core"]["payload"]
                    if (notified["sequence"] >= save["sequence"] and saved.get("sessionId") == session_id
                            and same_path(file_path(saved["uri"]), source) and saved.get("text") == content
                            and notified.get("settled")):
                        core_value(notified)
                        return {"save": save, "sync": sync, "notification": notified,
                                "documentVersion": core_value(sync)["documentVersion"]}
    return None


def completed_preparation(calls: list[dict], source: Path, main_class: str, session_id: str,
                          after: int, expected: str) -> dict | None:
    for prepared in core_calls(calls, "java.prepareLaunch"):
        payload = prepared["core"]["payload"]
        if (prepared["sequence"] <= after or payload.get("sessionId") != session_id
                or not same_path(payload.get("sourcePath", ""), source) or payload.get("mainClass") != main_class
                or not prepared.get("settled")):
            continue
        operation_id = core_value(prepared)["operationId"]
        for drain in core_calls(calls, "lsp.waitEvents"):
            if drain["core"]["payload"].get("sessionId") != session_id or not drain.get("settled"):
                continue
            for event in core_value(drain).get("events", []):
                if event.get("type") != "requestCompleted" or event.get("operationId") != operation_id:
                    continue
                result = event.get("result", {})
                if event.get("error") or result.get("kind") != expected:
                    raise AssertionError("actual java.prepareLaunch result differs: " + str(event))
                return {"request": prepared, "operationId": operation_id, "completion": event,
                        "result": result}
    return None


def java_source(marker: str, *, invalid=False) -> str:
    # This JDK-only program stays alive for Stop. The existing suite Job bounds
    # its lifetime even when a product assertion or cancellation fails.
    expression = 'missingAcceptanceSymbol' if invalid else json.dumps(marker)
    return ("public class Main {\n    public static void main(String[] args) throws Exception {\n"
            f"        System.out.println({expression});\n"
            "        System.out.flush();\n        System.in.read();\n    }\n}\n")


def assert_actual_launch(launch: dict, target: dict, root: Path, java_home: Path) -> None:
    if (not same_path(launch["executable"], java_home / "bin/java.exe")
            or not same_path(launch["workingDirectory"], root) or "Main" not in launch["arguments"]):
        raise AssertionError("actual run did not use the selected project JDK/workspace/main")
    for key, flags in (("classPaths", ("-cp", "-classpath", "--class-path")),
                       ("modulePaths", ("-p", "--module-path"))):
        expected = target.get(key, [])
        if not expected:
            continue
        arguments = launch["arguments"]
        positions = [index for index, value in enumerate(arguments) if value in flags]
        if len(positions) != 1 or positions[0] + 1 >= len(arguments):
            raise AssertionError("actual launch omitted JDT " + key)
        actual = arguments[positions[0] + 1].split(";")
        if len(actual) < len(expected) or any(not same_path(left, right) for left, right in zip(actual, expected)):
            raise AssertionError("actual launch did not preserve JDT " + key)
    if not target.get("classPaths") and not target.get("modulePaths"):
        raise AssertionError("JDT returned no runtime paths")
