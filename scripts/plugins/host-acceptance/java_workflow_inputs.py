#!/usr/bin/env python3
"""Fixed inputs and evidence checks for real generated Java workflow acceptance.

This module never probes tools, installs packages, or starts the product. The
coordinator supplies source-bound A/B evidence; the product still owns trust,
runtime discovery, Java project facts, compilation, and execution.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit

from build_fixture import json_bytes
from settings_functions_fixture import sha256

PLUGIN_ID = "dev.lithe.plugin.java-support"
REQUIRES = {"languages": 1, "languageServers": 1, "serverProcess": 1,
            "settings": 2, "projectGenerators": 1, "packageTrust": 1}
CASES = ("trusted-complete-package", "generate-open-real-jdk", "java-import-ready",
         "edit-save-synchronize", "prepare-launch-run-output", "stop-run-owner",
         "compile-error-refused", "product-profile-cleanup", "resource-invariance",
         "disable-uninstall-cleanup", "workspace-switch-restore", "compile-error-explicit-recovery")
BUILD_CASES = ("trusted-build-package", "approved-build-model", "approved-build-model-task", "declarative-build-run-binding", "build-compile-error-terminal")
PENDING = {
    "other-java-variants": "Other variants require independent reports; a successful JDT session alone does not establish build-plugin acceptance.",
    "signed-installer-upgrade": "Not executed: signed installer, installed-directory immutability and upgrade require independent channel evidence.",
    "windows-arm64": "Not executed: this driver is x64 only; ARM64 needs a fixed native EXE, package, JDK and environment.",
    "complete-M10": "Pending: Java workflow helpers/preflight and the plain runtime subset cannot establish all M8/M10 capabilities.",
}
VARIANTS = ("plain", "maven", "gradle")
# These are generated-input expectations, never project/classpath/build models.
DESCRIPTORS = {"plain": (), "maven": ("pom.xml",), "gradle": ("build.gradle", "settings.gradle")}


def controlled_run(plan: dict) -> bool:
    assurance = plan.get("assurance", "production")
    if assurance not in ("production", "controlled"):
        raise ValueError("unknown Java workflow assurance")
    if assurance == "controlled":
        key = plan.get("controlledHost", {})
        if (not re.fullmatch(r"lithe-controlled-java-[0-9a-f]{16}", key.get("keyId", ""))
                or not re.fullmatch(r"[A-Za-z0-9+/]{43}=", key.get("publicKeyBase64", ""))):
            raise ValueError("controlled execution needs a distinct frozen verification key")
        return True
    return False


def controlled_package(plan: dict, package: dict) -> None:
    """Normal native signature verification remains mandatory at install time."""
    with zipfile.ZipFile(read_reference(package["archive"])) as source:
        entries = archive_entries(source)
        signature = json.loads(source.read(entries["lithe-plugin-signature.json"]))
    if signature.get("keyId") != plan["controlledHost"]["keyId"]:
        raise ValueError("controlled package has another signing key")


def workflow_variant(plan: dict) -> str:
    if not isinstance(plan, dict):
        raise ValueError("expected a Java workflow object")
    if plan.get("schemaVersion") == 1 and plan.get("kind") == "windows-plain-java-workflow":
        if plan.get("variant", "plain") != "plain":
            raise ValueError("legacy plain plan cannot be relabelled as another variant")
        return "plain"
    if (plan.get("schemaVersion") == 2 and plan.get("kind") == "windows-java-workflow"
            and plan.get("variant") in VARIANTS):
        return plan["variant"]
    raise ValueError("expected a versioned Java workflow variant")


def variant_plan(base: dict, variant: str, group_id="org.example.acceptance", artifact_id="workflow") -> dict:
    """Prepare a new fixed-input plan without adopting another variant's receipts."""
    if variant not in ("maven", "gradle"):
        raise ValueError("choose maven or gradle")
    if len(group_id) > 200 or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", group_id):
        raise ValueError("expected a Java package groupId")
    if len(artifact_id) > 200 or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", artifact_id):
        raise ValueError("expected a generator artifactId")
    plan = {key: copy.deepcopy(base[key]) for key in ("sourceCommit", "sourceInventory", "package", "jdk")}
    for key in ("assurance", "controlledHost"):
        if key in base:
            plan[key] = copy.deepcopy(base[key])
    plan.update(schemaVersion=2, kind="windows-java-workflow", variant=variant)
    plan["project"] = {"name": base["project"]["name"] + " " + variant.title(), "buildSystem": variant,
                       "groupId": group_id, "artifactId": artifact_id,
                       "sourcePath": "src/main/java/" + group_id.replace(".", "/") + "/Main.java",
                       "mainClass": group_id + ".Main", "configurationName": "Main"}
    return plan


def archive_entries(source) -> dict:
    """Normalize either a flat package or the single release-package directory.

    These bounds cover the real JDT/JDK archive, unlike small UI fixtures. No
    extraction or trust inference occurs here; native install verifies again.
    """
    entries = source.infolist()
    names = [item.filename for item in entries]
    if (len(entries) > 100_000 or sum(item.file_size for item in entries) > 2 * 1024**3
            or len(names) != len(set(name.casefold() for name in names))):
        raise ValueError("package exceeds bounded unique inventory limits")
    for item in entries:
        name = item.filename.rstrip('/')
        if (not name or '\\' in name or ':' in name or name.startswith('/')
                or any(part in ('', '.', '..') for part in name.split('/'))
                or (item.external_attr >> 16) & 0o170000 == 0o120000):
            raise ValueError("package has an unsafe or linked archive entry")
    prefix = ''
    if 'plugin.json' not in names:
        candidates = [name[:-len('plugin.json')] for name in names
                      if name.endswith('/plugin.json') and len(PurePosixPath(name).parts) == 2]
        if len(candidates) != 1:
            raise ValueError("expected one complete package root")
        prefix = candidates[0]
        if any(not name.startswith(prefix) for name in names):
            raise ValueError("archive includes bytes outside its package root")
    return {item.filename[len(prefix):]: item for item in entries if item.filename != prefix}


def archive_manifest(package: dict) -> tuple[dict, set[str]]:
    archive = read_reference(package["archive"])
    with zipfile.ZipFile(archive) as source:
        entries = archive_entries(source)
        if entries["plugin.json"].file_size > 4 * 1024**2:
            raise ValueError("manifest exceeds bounded JSON size")
        raw = source.read(entries["plugin.json"])
    manifest = json.loads(raw)
    if (not isinstance(manifest, dict) or not isinstance(manifest.get("requires"), dict)
            or hashlib.sha256(raw).hexdigest() != package["manifestSha256"] or manifest["requires"] != package["requires"]):
        raise ValueError("archive manifest/requires identity mismatch")
    return manifest, set(entries)


def verify_installed_package(root: Path, archive: Path, evidence: Path) -> None:
    from settings_functions_acceptance import assert_resources, resource_diff, snapshot_resources
    expected = {}
    with zipfile.ZipFile(archive) as source:
        for name, entry in archive_entries(source).items():
            for parent in PurePosixPath(name.rstrip('/')).parents:
                if parent.as_posix() != '.':
                    expected[parent.as_posix() + '/'] = {'kind': 'directory'}
            if entry.is_dir():
                expected[name] = {'kind': 'directory'}
            else:
                with source.open(entry) as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                expected[name] = {'kind': 'file', 'bytes': entry.file_size, 'sha256': digest}
    actual = snapshot_resources(root, max_bytes=2 * 1024**3)
    evidence.write_bytes(json_bytes({'archiveSha256': sha256(archive), 'expected': expected,
                                    'actual': actual, 'diff': resource_diff(expected, actual)}))
    assert_resources(expected, actual)


def receipt_blockers(plan: dict, key: str, expected: dict) -> list[str]:
    reference = plan.get(key)
    if reference is None:
        return [key + " missing"]
    receipt = read_reference(reference, json_document=True)
    if not isinstance(receipt, dict):
        raise ValueError(key + " must be a receipt object")
    if (receipt.get("status") != "passed" or receipt.get("productionTrusted") is not True
            or any(receipt.get(name) != value for name, value in expected.items())
            or not isinstance(receipt.get("evidence"), list) or not receipt["evidence"]):
        return [key + " is candidate/incomplete or has another package/JDK/variant/source identity"]
    for evidence in receipt["evidence"]:
        read_reference(evidence)
    if key == "workspaceEvidence" and workflow_variant(plan) != "plain":
        root = Path(receipt.get("workspaceRoot", ""))
        files = receipt.get("generatedFiles", {})
        if not root.is_absolute():
            return ["workspaceEvidence lacks an absolute generated workspace"]
        for relative in (*DESCRIPTORS[plan["variant"]], plan["project"]["sourcePath"], ".lithe/run/local.json"):
            if relative not in files:
                return ["workspaceEvidence missing generated file " + relative]
            path = read_reference(files[relative])
            if (root.resolve() not in path.resolve().parents
                    or not same_path(path.resolve(), (root / relative).resolve())):
                return ["workspaceEvidence generated file belongs to another workspace"]
        config = read_reference(files[".lithe/run/local.json"], json_document=True)
        if not generated_jdk_matches(config, plan["jdk"]["home"]):
            return ["workspaceEvidence generated configuration has another JDK"]
    return []


def validate_build_package(plan: dict) -> list[str]:
    package = plan.get("buildPackage")
    if package is None:
        return ["buildPackage missing", "buildPackageEvidence missing"]
    manifest, _ = archive_manifest(package)
    required = manifest["requires"]
    systems = [system for system in manifest.get("buildSystems", []) if system.get("id") == package.get("buildSystemId")]
    if (manifest.get("id") != package.get("pluginId") or manifest["id"] == PLUGIN_ID
            or not isinstance(required.get("buildSystems"), int) or required["buildSystems"] < 1
            or manifest.get("vendor", {}).get("signatureRequirement") != "publisherPackage"
            or len(systems) != 1 or systems[0]["id"] != plan["variant"]):
        raise ValueError("independent complete production-trusted variant build package is required")
    if systems[0].get("provider") and not required.get("buildProviders"):
        raise ValueError("provider build package must retain its buildProviders requirement")
    selection = plan.get("buildTask", {})
    task = next((row for row in systems[0].get("tasks", []) if row.get("id") == selection.get("taskId")), None)
    if (not task or task.get("execution", "task") != "task" or task.get("requiresUserArguments")
            or selection.get("scope") not in (["project"] if task.get("fromModel") else task.get("scopes", []))
            or (task.get("fromModel") and not selection.get("modelTaskId"))):
        return ["buildTask must select an actual declared build task and scope from the independent package"]
    if controlled_run(plan):
        controlled_package(plan, package)
        return []
    return receipt_blockers(plan, "buildPackageEvidence", {
        "variant": plan["variant"], "sourceCommit": plan["sourceCommit"],
        "pluginId": manifest["id"], "buildSystemId": package["buildSystemId"],
        "packageSha256": package["archive"]["sha256"], "manifestSha256": package["manifestSha256"]})


def path_key(value: str | Path) -> str:
    """Compare Win32 extended-length spellings without resolving another owner."""
    path = str(value).replace("\\", "/")
    if path[:8].casefold() == "//?/unc/":
        path = "//" + path[8:]
    elif re.match(r"^//\?/[A-Za-z]:/", path):
        path = path[4:]
    return path.rstrip("/").casefold()


def same_path(left: str | Path, right: str | Path) -> bool:
    return path_key(left) == path_key(right)


def generated_jdk_matches(document: dict, home: str) -> bool:
    """The generated run configuration uses Core's current version-two shape."""
    return document.get("version") == 2 and same_path(
        document.get("toolchain", {}).get("java", {}).get("homePath", ""), home)


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
    limit = 4 * 1024**2 if json_document else 2 * 1024**3
    if (path.stat().st_size > limit or not path.is_file() or path.is_symlink() or path.is_junction()
            or sha256(path) != reference["sha256"]):
        raise ValueError("fixed input bytes changed: " + str(path))
    return json.loads(path.read_text(encoding="utf-8-sig")) if json_document else path


def validate_plan(plan: dict) -> tuple[dict, list[str]]:
    """Return the actual archive manifest and closed execution prerequisites.

    A candidate receipt is deliberately insufficient even when static helper
    tests pass. Receipts refer to original evidence, not a new trust authority.
    Native install/scan must validate the supplied package again at runtime.
    """
    variant = workflow_variant(plan)
    controlled = controlled_run(plan)
    if (not re.fullmatch(r"[0-9a-f]{40}", plan.get("sourceCommit", ""))
            or not isinstance(plan.get("sourceInventory"), dict) or not plan["sourceInventory"]):
        raise ValueError("complete fixed source identity is required")
    package = plan["package"]
    manifest, names = archive_manifest(package)
    if (manifest.get("id") != PLUGIN_ID
            or any(manifest["requires"].get(key) != level for key, level in REQUIRES.items())
            or manifest.get("vendor", {}).get("signatureRequirement") != "publisherPackage"):
        raise ValueError("complete official Java manifest/requires/trust identity mismatch")
    generator = next((item for item in manifest.get("projectGenerators", []) if item["id"] == "java"), None)
    if not generator or not any(item.get("languageID") == "java" and item.get("hostIntegration", {}).get("id") == "jdt"
                                for item in manifest.get("languageServers", [])):
        raise ValueError("complete Java generator and JDT integration are required")
    project = plan["project"]
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9 -]{0,60}", project.get("name", "")) or not project.get("configurationName"):
        raise ValueError("expected a named generated Java project and run configuration")
    if variant == "plain":
        if project.get("sourcePath") != "src/Main.java" or project.get("mainClass") != "Main":
            raise ValueError("plain workflow must use a plain generated Main project")
    else:
        group = project.get("groupId", "")
        if (len(group) > 200 or len(project.get("artifactId", "")) > 200
                or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", group)
                or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", project.get("artifactId", ""))
                or project.get("buildSystem") != variant or project.get("mainClass") != group + ".Main"
                or project.get("sourcePath") != "src/main/java/" + group.replace(".", "/") + "/Main.java"):
            raise ValueError("variant project must bind buildSystem, group/artifact, generated source and qualified Main")
        build = next((field for field in generator.get("fields", []) if field.get("id") == "buildSystem"), {})
        if (not any(option.get("value") == variant for option in build.get("options", []))
                or not any(item.get("buildSystemID") == variant and item.get("when") == {"field": "buildSystem", "equals": variant}
                           for item in generator.get("requirements", []))
                or not {"templates/standard/Main.java", *("templates/" + variant + "/" + name for name in DESCRIPTORS[variant])} <= names):
            raise ValueError("complete Java archive lacks variant generator requirements/templates")
    jdk = plan["jdk"]
    home = Path(jdk["home"])
    if (not home.is_absolute() or not jdk.get("version") or
            sha256(home / "bin/java.exe") != jdk["javaSha256"] or
            sha256(home / "bin/javac.exe") != jdk["javacSha256"]):
        raise ValueError("real fixed JDK java/javac bytes are required")
    blocked = []
    binding = {} if variant == "plain" else {"variant": variant, "sourceCommit": plan["sourceCommit"]}
    if controlled:
        # The actual generate/open/JDT/save cases establish workspace evidence
        # in this run. Requiring an earlier product receipt is circular. This
        # branch confers no trust: native signature checks and all capabilities
        # still gate execution, and every result is labelled non-production.
        controlled_package(plan, package)
    for key, expected in (() if controlled else (("packageEvidence", {"packageSha256": package["archive"]["sha256"],
                                              "manifestSha256": package["manifestSha256"]}),
                          ("workspaceEvidence", {"javaHome": jdk["home"], "javaVersion": jdk["version"],
                                                "javaSha256": jdk["javaSha256"]}))):
        if variant != "plain" and key == "workspaceEvidence":
            expected.update(project=project, generatorId="java", javacSha256=jdk["javacSha256"],
                            packageSha256=package["archive"]["sha256"])
        blocked.extend(receipt_blockers(plan, key, {**expected, **binding}))
    if variant != "plain":
        blocked.extend(validate_build_package(plan))
    return manifest, blocked


def pending_rows(reason: str, variant="plain") -> list[dict]:
    cases = CASES if variant == "plain" else (*CASES, *BUILD_CASES)
    return [{"name": variant + "-java / " + name, "suite": "plugin-host-acceptance / java-workflow",
             "status": "skipped", "durationMs": 0, "maxMs": 120_000, "details": reason}
            for name in cases]


def assert_observer(snapshot: dict) -> list[dict]:
    if snapshot.get("dropped") or snapshot.get("errors"):
        raise AssertionError("Java IPC evidence was dropped or could not be decoded")
    return snapshot["calls"]


def generated_operation(calls: list[dict], plan: dict, target: Path) -> dict | None:
    """Link real form, package incarnation, approval and generated root."""
    for generated in calls:
        if generated["command"] != "declarative_plugins_generator_generate" or not generated.get("settled"):
            continue
        if generated.get("error"):
            raise AssertionError("native Java generation failed: " + str(generated["error"]))
        if not same_path(generated.get("value", {}).get("root", ""), target):
            continue
        for prepared in calls:
            if (prepared["command"] != "declarative_plugins_generator_prepare" or not prepared.get("settled")
                    or prepared["sequence"] >= generated["sequence"]
                    or prepared.get("value", {}).get("id") != generated["args"].get("id")):
                continue
            request = prepared["args"]["request"]
            form = request["form"]
            values = dict(form["values"])
            variant = workflow_variant(plan)
            if variant == "plain" and "buildSystem" not in values:
                # Untouched defaults are absent from the public form request.
                # Accept one only when Core evaluated these exact reviewed
                # inputs and package as valid before prepare.
                evaluated_args = {key: request[key] for key in ("pluginId", "generatorId", "packageIdentity", "form")}
                verified_default = any(
                    call["command"] == "declarative_plugins_generator_form" and call.get("settled")
                    and not call.get("error") and call["sequence"] < prepared["sequence"]
                    and call.get("args") == evaluated_args and call.get("value", {}).get("valid") is True
                    and [field.get("value") for field in call["value"].get("fields", [])
                         if field.get("id") == "buildSystem"] == ["none"]
                    for call in calls)
                if not verified_default:
                    raise AssertionError("default Java build variant lacks its exact valid Core form evaluation")
                values["buildSystem"] = "none"
            expected = {"buildSystem": "none" if variant == "plain" else variant}
            if variant != "plain":
                expected.update(groupId=plan["project"]["groupId"], artifactId=plan["project"]["artifactId"])
            runtime = form.get("runtimes", {}).get("jdk", {})
            if (request.get("pluginId") != PLUGIN_ID or request.get("generatorId") != "java"
                    or not request.get("packageIdentity") or form.get("projectName") != plan["project"]["name"]
                    or any(values.get(key) != value for key, value in expected.items())
                    or not same_path(runtime.get("home", ""), plan["jdk"]["home"]) or runtime.get("version") != plan["jdk"]["version"]):
                raise AssertionError("generated operation changed Java package/form/variant/JDK")
            return {"prepare": prepared, "generate": generated}
    return None


def core_calls(calls: list[dict], command: str) -> list[dict]:
    return [call for call in calls if call.get("core", {}).get("command") == command]


def core_value(call: dict) -> dict:
    value = call.get("value")
    if call.get("error") or not isinstance(value, dict) or value.get("ok") is not True:
        raise AssertionError("native Core call did not succeed: " + str(call))
    return value.get("data", {})


def ready_session(calls: list[dict], root: Path, package_root: Path) -> dict | None:
    for start in reversed(core_calls(calls, "lsp.startServer")):
        if not start.get("settled"):
            continue
        payload = start["core"]["payload"]
        if payload.get("pluginId") != PLUGIN_ID or not same_path(file_path(payload["rootUri"]), root):
            continue
        resources = payload.get("jdtlsLaunchResources") or {}
        # Core may assemble JDT's final arguments from typed resources. Bind
        # the actual launcher, not a substring that a sibling path can mimic.
        entries = [resources.get("launcherJarPath", ""), *payload.get("arguments", [])]
        prefix = path_key(package_root.resolve(strict=True)) + "/"

        def belongs_to_package(value):
            try:
                path = Path(value)
                return path.is_file() and path_key(path.resolve(strict=True)).startswith(prefix)
            except (OSError, ValueError):
                return False

        # MSIX can expose one file through logical AppData and its redirected
        # physical path. Resolve both existing owners before containment checks.
        if not any(belongs_to_package(value) for value in entries):
            raise AssertionError("Java server did not use the admitted plugin resources")
        session_id = core_value(start)["sessionId"]
        if any(call["core"]["payload"].get("sessionId") == session_id and call["sequence"] > start["sequence"]
               for call in core_calls(calls, "lsp.stopServer")):
            return None
        drains = [call for call in core_calls(calls, "lsp.waitEvents")
                  if call["core"]["payload"].get("sessionId") == session_id and call.get("settled")]
        if any(event.get("type") == "stateChanged" and event.get("state") in ("stopped", "failed")
               for call in drains for event in core_value(call).get("events", [])):
            return None
        for call in drains:
            if call["core"]["payload"].get("sessionId") != session_id or not call.get("settled"):
                continue
            data = core_value(call)
            if any(event.get("type") == "stateChanged" and event.get("state") == "ready" for event in data.get("events", [])):
                return {"sessionId": session_id, "start": start, "readiness": call}
    return None


def ready_document_session(calls, root, package_root, source):
    session = ready_session(calls, root, package_root)
    if session is None:
        return None
    for synced in reversed(core_calls(calls, "lsp.syncDocument")):
        payload = synced["core"]["payload"]
        if (synced.get("settled") and payload.get("sessionId") == session["sessionId"]
                and same_path(file_path(payload.get("uri", "")), source)):
            # Calls are observed before completion: even a pending close makes
            # this old sync insufficient proof of the current attachment.
            if any(closed["sequence"] > synced["sequence"]
                   and closed["core"]["payload"].get("sessionId") == session["sessionId"]
                   and same_path(file_path(closed["core"]["payload"].get("uri", "")), source)
                   for closed in core_calls(calls, "lsp.closeDocument")):
                return None
            version = core_value(synced).get("documentVersion")
            if type(version) is int:
                return {**session, "document": synced}
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
    preparations = [call for call in core_calls(calls, "java.prepareLaunch")
                    if call["sequence"] > after and call["core"]["payload"].get("sessionId") == session_id
                    and same_path(call["core"]["payload"].get("sourcePath", ""), source)
                    and call["core"]["payload"].get("mainClass") == main_class]
    if len(preparations) > 1:
        raise AssertionError("one Run must issue exactly one Core java.prepareLaunch")
    for prepared in preparations:
        payload = prepared["core"]["payload"]
        if (prepared["sequence"] <= after or payload.get("sessionId") != session_id
                or not same_path(payload.get("sourcePath", ""), source) or payload.get("mainClass") != main_class
                or not prepared.get("settled")):
            continue
        operation_id = core_value(prepared)["operationId"]
        if any(call["core"]["payload"].get("operationId") == operation_id
               and call["sequence"] > prepared["sequence"] for call in core_calls(calls, "lsp.cancelOperation")):
            raise AssertionError("java.prepareLaunch was cancelled; a late result cannot establish success")
        completions = []
        for drain in core_calls(calls, "lsp.waitEvents"):
            if drain["core"]["payload"].get("sessionId") != session_id or not drain.get("settled"):
                continue
            for event in core_value(drain).get("events", []):
                if event.get("type") != "requestCompleted" or event.get("operationId") != operation_id:
                    continue
                completions.append(event)
                result = event.get("result", {})
                if event.get("error") or result.get("kind") != expected:
                    raise AssertionError("actual java.prepareLaunch result differs: " + str(event))
        if len(completions) > 1:
            raise AssertionError("java.prepareLaunch must have one terminal result")
        if completions:
            return {"request": prepared, "operationId": operation_id, "completion": completions[0],
                    "result": completions[0]["result"]}
    return None


def java_source(marker: str, *, invalid=False, package_name=None) -> str:
    # This JDK-only program stays alive for Stop. The existing suite Job bounds
    # its lifetime even when a product assertion or cancellation fails.
    expression = 'missingAcceptanceSymbol' if invalid else json.dumps(marker)
    if package_name is not None and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", package_name):
        raise ValueError("invalid Java package name")
    prefix = "package " + package_name + ";\n\n" if package_name else ""
    return (prefix + "public class Main {\n    public static void main(String[] args) throws Exception {\n"
            f"        System.out.println({expression});\n"
            "        System.out.flush();\n        System.in.read();\n    }\n}\n")


def assert_actual_launch(launch: dict, target: dict, root: Path, java_home: Path, main_class="Main") -> None:
    if (not same_path(launch["executable"], java_home / "bin/java.exe")
            or not same_path(launch["workingDirectory"], root) or main_class not in launch["arguments"]):
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


def main():
    parser = argparse.ArgumentParser(description="Prepare variant-specific inputs; never launch, sign, download or adopt plain receipts.")
    parser.add_argument("--base-plan", type=Path, required=True)
    parser.add_argument("--variant", choices=("plain", "maven", "gradle"), required=True)
    parser.add_argument("--host-identity", type=Path, help="Freeze a new plan against A's final controlled build identity after temporary public-key/capability configuration")
    parser.add_argument("--group-id", default="org.example.acceptance")
    parser.add_argument("--artifact-id", default="workflow")
    parser.add_argument("--build-package-input", type=Path, help="Fixed buildPackage object (archive/requires/manifestSha256/pluginId/buildSystemId)")
    parser.add_argument("--build-task-input", type=Path, help="Explicit buildTask selection from the admitted package: taskId, scope, optional projectId/targetId/modelTaskId")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    base = json.loads(args.base_plan.read_text(encoding="utf-8-sig"))
    plan = base if workflow_variant(base) == args.variant else variant_plan(base, args.variant, args.group_id, args.artifact_id)
    if args.host_identity:
        # Core presents a unique Java entry under its simple class name. The
        # qualified main and exact source still bind prepareLaunch below.
        plan["project"]["configurationName"] = "Main"
        if not controlled_run(plan):
            parser.error("host rebinding is only for an explicitly controlled plan")
        from text_window_fixture import source_inventory
        identity = json.loads(args.host_identity.read_text(encoding="utf-8-sig"))
        if (identity.get("identifier") != "app.lithe.windows.host-acceptance"
                or identity.get("sourceInventory") != source_inventory()):
            parser.error("controlled host identity must match the current full source inventory")
        plan.update(sourceCommit=identity["gitRevision"], sourceInventory=identity["sourceInventory"])
    if args.build_package_input:
        plan["buildPackage"] = json.loads(args.build_package_input.read_text(encoding="utf-8-sig"))
    if args.build_task_input:
        plan["buildTask"] = json.loads(args.build_task_input.read_text(encoding="utf-8-sig"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("xb") as output:
        output.write(json_bytes(plan))
    print("Prepared " + args.variant + " inputs; receipts and actual product acceptance remain required.")


if __name__ == "__main__":
    main()
