#!/usr/bin/env python3
"""Generated plain/Maven/Gradle Java UI/JDT/build-registry/run acceptance.

Preflight starts nothing. Runtime needs final source/config/EXE identity and
complete signed packages. Production receipts and explicit controlled-key runs
have separate assurance. Unsigned candidates remain blocked. AppSession and the gated
Windows Job own every product, JDT, Java and observer process.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
import zipfile
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

from build_acceptance import missing_capabilities, source_capabilities
from generator_acceptance import choose_runtime, cleanup_session, runtime_paths
from java_workflow_build import JavaBuildWorkflow
from java_workflow_inputs import (CASES, BUILD_CASES, PENDING, PLUGIN_ID, REQUIRES, DESCRIPTORS, archive_manifest, assert_actual_launch, assert_observer, completed_preparation,
                                  java_source, json_bytes, pending_rows, read_reference,
                                  generated_operation, ready_document_session, ready_session, same_path, saved_and_synced, sha256, validate_plan, workflow_variant)
from java_workflow_inputs import controlled_run, generated_jdk_matches, verify_installed_package
from settings_functions_acceptance import (assert_resources, resource_diff, snapshot_resources,
                                          verify_host, wait_for)
from text_window_fixture import source_inventory
from web_bridge_fallback_acceptance import require_x64_executable

OBSERVER = Path(__file__).with_name("java_workflow_observer.js").read_text(encoding="utf-8")
SUITE_SECONDS = 1500
WORK_SECONDS = 1260


def click_generator_action(page, name, wait):
    # Complete runtime packages are verified before catalog/prepare replies.
    # Await the exact public action inside the existing case/work deadlines;
    # an early screenshot or an unrelated enabled button is not readiness.
    action = page.get_by_role("button", name=name, exact=True)
    wait(lambda: action.is_visible() and action.is_enabled(), "generator action " + name, 60)
    action.click(timeout=5000)


def click_java_run_action(row, wait):
    # The public Run pane may still be identifying the restored project.
    # Wait for this exact configuration, then dispatch once; a timeout fails.
    action = row.get_by_role("button", name="Run", exact=True)
    wait(lambda: action.is_visible() and action.is_enabled(), "generated Java Run action", 60)
    action.click(timeout=5000)


def workspace_tab(page, workspace):
    matches = []
    for title in page.get_by_role("tab").evaluate_all("elements => elements.map(element => element.getAttribute('title'))"):
        if not title or not Path(title).is_absolute():
            continue
        try:
            if same_path(Path(title).resolve(strict=True), workspace.resolve(strict=True)):
                matches.append(title)
        except (OSError, ValueError):
            continue
    if len(matches) > 1:
        raise AssertionError("workspace has more than one public project tab")
    return page.get_by_role("tab").and_(page.get_by_title(matches[0], exact=True)) if matches else None


def switch_workspace_tab(page, workspace, wait):
    tab = wait(lambda: workspace_tab(page, workspace), "actual public workspace tab")
    # Selection can precede initialization. Observe the public action boundary
    # before continuing, within the existing case and workflow deadlines.
    wait(lambda: tab.is_enabled(), "workspace tab ready for switching", 60)
    tab.click(timeout=10_000)
    wait(lambda: tab.get_attribute("aria-selected") == "true" and tab.is_enabled(),
         "selected Java workflow workspace initialized", 60)


def wait_saved_source(source, content, wait):
    read_error = None

    def saved():
        nonlocal read_error
        try:
            actual = source.read_bytes()
            read_error = None
            return actual == content.encode("utf-8")
        except (PermissionError, FileNotFoundError) as error:
            # Native save may briefly own its handle or replace its old path.
            # Keep the exact byte assertion and the existing local deadline.
            read_error = error
            return False

    try:
        wait(saved, "saved Java bytes")
    except TimeoutError as error:
        if read_error is not None:
            raise TimeoutError("saved Java bytes remained inaccessible: " + str(read_error)) from error
        raise


def workflow_result(plan, tests, runtime_executed):
    variant = workflow_variant(plan)
    passed = {row["name"] for row in tests if row["status"] == "passed" and row["durationMs"] < row.get("maxMs", 120_000)}
    required = CASES if variant == "plain" else (*CASES, *BUILD_CASES)
    failures = {row["name"] for row in tests if row["status"] not in ("passed", "skipped")
                or row["durationMs"] >= row.get("maxMs", 120_000)}
    all_passed = runtime_executed and not failures and all(variant + "-java / " + name in passed for name in required)
    build_passed = runtime_executed and variant != "plain" and all(variant + "-java / " + name in passed
        for name in (*BUILD_CASES, CASES[7], CASES[8], CASES[9])) and not failures
    return {"complete": False, "variant": variant, "scope": variant + "-runtime-driver", "runtimeExecuted": runtime_executed,
            "assurance": "controlled" if controlled_run(plan) else "production",
            "productionAcceptance": bool(all_passed and not controlled_run(plan)),
            "workflowPassed": bool(all_passed), "plainJavaPassed": bool(all_passed and variant == "plain"), "buildPluginPassed": bool(build_passed)}


def preflight(plan: dict, capabilities: dict) -> dict:
    variant, requires, build_requires, blocked = "invalid", dict(REQUIRES), {}, []
    try:
        variant = workflow_variant(plan)
        manifest, blocked = validate_plan(plan)
        requires = manifest["requires"]
        if variant != "plain":
            # validate_plan bound these requirements to the actual archive.
            build_requires = plan.get("buildPackage", {}).get("requires", {"buildSystems": 1})
    except (ValueError, OSError, KeyError, TypeError, AttributeError, zipfile.BadZipFile) as error:
        blocked.append("invalid fixed input: " + str(error))
    blocked.extend("closed capability " + item for item in missing_capabilities(requires, capabilities))
    if variant in ("maven", "gradle"):
        build_requires = build_requires or {"buildSystems": 1}
        blocked.extend("closed build capability " + item for item in missing_capabilities(build_requires, capabilities))
    reason = "Not executed. " + ("; ".join(blocked) if blocked else "Explicit isolated final-source product invocation required.")
    return {"complete": False, "variant": variant, "workflowPassed": False, "buildPluginPassed": False,
            "productionAcceptance": False, "assurance": plan.get("assurance", "production"),
            "plainJavaPassed": False, "runtimeExecuted": False, "scope": variant + "-runtime-driver",
            "blocked": blocked, "requires": requires, "buildRequires": build_requires, "tests": pending_rows(reason, variant) +
            [{"name": name, "suite": "plugin-host-acceptance / pending-platforms", "status": "skipped",
              "durationMs": 0, "maxMs": 1, "details": details} for name, details in PENDING.items()]}


def run(args, driver, reporter, plan):
    if controlled_run(plan) != bool(getattr(args, "controlled", False)):
        raise ValueError("controlled plans require an explicit --controlled invocation")
    work_deadline = time.monotonic() + WORK_SECONDS
    prerequisites = preflight(plan, source_capabilities())
    if prerequisites["blocked"]:
        raise ValueError("Java workflow prerequisites blocked: " + "; ".join(prerequisites["blocked"]))
    manifest, _ = validate_plan(plan)
    variant = workflow_variant(plan)
    main_class = plan["project"]["mainClass"]
    identity = verify_host(args.host_identity, args.executable, plan)
    if (identity.get("sourceInventory") != plan["sourceInventory"] or source_inventory() != plan["sourceInventory"]
            or identity.get("configSha256") != sha256(args.host_identity.with_name("tauri.host-acceptance.conf.json"))
            or platform.machine().lower() not in ("amd64", "x86_64")):
        raise ValueError("final Java workflow source/config/x64 identity mismatch")
    # Reuse the existing image/profile overlap guard without changing B's driver.
    runtime_paths(SimpleNamespace(**vars(args), fixture_root=args.plan.parent))
    require_x64_executable(args.executable)
    require_x64_executable(Path(plan["jdk"]["home"]) / "bin/java.exe")
    archive = read_reference(plan["package"]["archive"])
    evidence = args.artifact_root
    evidence.mkdir(parents=True, exist_ok=False)
    image_before = snapshot_resources(args.run_image)
    package_root = args.app_local_data / "plugins" / PLUGIN_ID / manifest["version"]
    projects = args.app_local_data / "generator-projects"
    target = projects / plan["project"]["name"]
    session = page = None
    packages = []
    failure = None
    cleanup_attempted = False
    observer_started = False

    def write(name, value):
        driver.write_json(evidence / (name + ".json"), value)

    def raw_snapshot():
        return page.evaluate("() => window.__litheJavaWorkflow.snapshot()")

    def snapshot():
        return assert_observer(raw_snapshot())

    def wait(predicate, description, seconds=30):
        remaining = work_deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Java workflow work deadline: " + description)
        return wait_for(predicate, description, pump=lambda: page.locator("body").count(), seconds=min(seconds, remaining))

    @contextmanager
    def step(name, max_ms=120_000):
        started = time.monotonic()
        with reporter.step(variant + "-java / " + name, max_ms=max_ms):
            if name not in (CASES[7], CASES[8]) and started >= work_deadline:
                raise TimeoutError("Java workflow exhausted its work deadline before cleanup")
            yield
            if (time.monotonic() - started) * 1000 >= max_ms:
                raise TimeoutError("Java workflow case exceeded its local budget: " + name)

    def catalog(plugin_id=PLUGIN_ID):
        return next((row for row in driver.invoke(page, "declarative_plugins_state")
                     if row["pluginId"] == plugin_id and row["source"] == "installed"), None)

    def install(package, package_manifest):
        plugin_id = package_manifest["id"]
        original = read_reference(package["archive"])
        review = driver.import_review(page, session.process.pid, original)
        review_text = review.inner_text(timeout=10_000)
        if "Unverified publisher" in review_text:
            raise AssertionError("production package was presented as unverified: " + plugin_id)
        write("install-review-" + plugin_id, {"text": review_text, "requires": package_manifest["requires"], "archive": package["archive"]})
        driver.confirm_review(page, review)
        installed = wait(lambda: row if (row := catalog(plugin_id)) and row["status"] == "accepted" and row["enabled"] else None,
                         "complete production-trusted package accepted: " + plugin_id, 60)
        root = args.app_local_data / "plugins" / plugin_id / package_manifest["version"]
        # Retain the owner before inspection, so a partial install still gets
        # checked in finally. No installation records are manufactured.
        packages.append({"root": root, "before": snapshot_resources(root), "archive": package["archive"],
                         "pluginId": plugin_id, "displayName": package_manifest["displayName"], "uninstalled": False})
        details = driver.invoke(page, "declarative_plugins_details", {"pluginId": plugin_id, "source": "installed"})
        verification = details["versions"]["current"]["verification"]
        if verification["status"] != "publisherSignature":
            raise AssertionError("runtime install did not verify a trusted publisher package")
        if controlled_run(plan) and verification.get("keyId") != plan["controlledHost"]["keyId"]:
            raise AssertionError("native verification did not use the frozen controlled key")
        verify_installed_package(root, original, evidence / ("installed-" + plugin_id + ".json"))
        record = json.loads((root.parent / "installation.json").read_text(encoding="utf-8"))
        if record["disk"]["archiveSha256"] != package["archive"]["sha256"]:
            raise AssertionError("native installation provenance differs from reviewed archive")
        write("installed-identity-" + plugin_id, {"catalog": installed, "record": record, "resources": packages[-1]["before"]})

    def verify_package(package):
        after = snapshot_resources(package["root"])
        write("package-diff-" + package["pluginId"], resource_diff(package["before"], after))
        assert_resources(package["before"], after)

    def clean():
        nonlocal cleanup_attempted
        cleanup_attempted = True
        with step(CASES[7]):
            cleanup = cleanup_session(args, driver, session)
            write("cleanup", cleanup)
            if cleanup["survivors"] or cleanup["errors"] or not cleanup["profilesAbsent"]:
                raise AssertionError("Java workflow cleanup failed: " + str(cleanup))

    def run_row():
        navigation = page.get_by_role("navigation", name="Run configurations", exact=True)
        return navigation.get_by_role("listitem").filter(
            has=page.get_by_role("button", name=plan["project"]["configurationName"], exact=True)).last

    def owned_runs():
        return driver.invoke(page, "run_list_owned_processes", {"windowLabel": None})

    def edit_save(content):
        editor = page.locator(".monaco-editor textarea.inputarea").filter(visible=True)
        if editor.count() != 1:
            raise AssertionError("expected one visible generated Java editor")
        editor.focus(timeout=10_000)
        page.keyboard.press("Control+A")
        # Type this controlled fixture as a single line so Monaco's per-line
        # auto-indent does not change its exact bytes. It is still real Java;
        # no editor model, store, private API or system clipboard is touched.
        content = " ".join(content.splitlines())
        page.keyboard.insert_text(content)
        page.keyboard.press("Control+S")
        wait_saved_source(source, content, wait)
        return wait(lambda: saved_and_synced(snapshot(), source, content, java["sessionId"]),
                    "real saved document and Core synchronization", 60)

    try:
        write("identity", {"host": identity, "inputs": plan})
        write("resources-before", image_before)
        args.app_roaming_data.mkdir(parents=True, exist_ok=False)
        (args.app_roaming_data / "settings.json").write_bytes(json_bytes({"displayLanguage": "en-US", "javaProjectImportOnOpen": "automatic"}))
        startup = args.app_local_data / "java-workflow-start"
        startup.mkdir(parents=True, exist_ok=False)
        projects.mkdir(exist_ok=False)
        with driver.sync_playwright() as playwright:
            try:
                with step(CASES[0]):
                    session = driver.AppSession(playwright, args.executable, startup, args.webview_data, evidence / "app", 1)
                    reporter.capture_failure = lambda: driver.capture_session_failure(session, evidence)
                    page = session.start()
                    page.set_default_timeout(10_000)
                    driver.finish_onboarding(page)
                    page.evaluate(OBSERVER)
                    observer_started = True
                    install(plan["package"], manifest)
                if variant != "plain":
                    with step("trusted-build-package"):
                        build_manifest, _ = archive_manifest(plan["buildPackage"])
                        install(plan["buildPackage"], build_manifest)
                with step(CASES[1]):
                    driver.close_settings(page)
                    menu = page.get_by_role("menuitem", name="File", exact=True)
                    if not menu.is_visible():
                        page.get_by_role("button", name="Menu", exact=True).click(timeout=10_000)
                    if menu.get_attribute("aria-expanded") != "true":
                        menu.click(timeout=10_000)
                    page.get_by_role("menuitem", name="New", exact=True).hover(timeout=10_000)
                    page.get_by_role("menuitem", name="New Project…", exact=True).click(timeout=10_000)
                    page.get_by_text("Plugin project generators", exact=True).click(timeout=10_000)
                    generator = next(item for item in manifest["projectGenerators"] if item["id"] == "java")
                    click_generator_action(page, generator["displayName"] + " · " + manifest["displayName"], wait)
                    page.locator("#generator-name").fill(plan["project"]["name"], timeout=10_000)
                    page.locator("#generator-location").fill(str(projects), timeout=10_000)
                    build = next(field for field in generator["fields"] if field["id"] == "buildSystem")
                    option = next(option for option in build["options"] if option["value"] == ("none" if variant == "plain" else variant))
                    page.get_by_role("group", name=build["title"], exact=True).get_by_role("button", name=option["title"], exact=True).click(timeout=10_000)
                    if variant != "plain":
                        page.locator("#generator-field-groupId").fill(plan["project"]["groupId"], timeout=10_000)
                        page.locator("#generator-field-artifactId").fill(plan["project"]["artifactId"], timeout=10_000)
                    choose_runtime(page, driver, session.process.pid, Path(plan["jdk"]["home"]))
                    review_button = page.get_by_role("button", name="Review creation", exact=True)
                    wait(lambda: review_button.is_enabled(), "native runtime probe and valid Java form")
                    review_button.click(timeout=10_000)
                    create = page.get_by_role("button", name="Create project", exact=True)
                    wait(lambda: create.is_visible() and create.is_enabled(), "reviewed Java creation action", 60)
                    page.screenshot(path=str(evidence / "generation-review.png"), timeout=5000)
                    create.click(timeout=5000)
                    wait(lambda: (target / plan["project"]["sourcePath"]).is_file(), "actual generated Java source", 60)
                    page.get_by_role("heading", name="Plugin project generators", exact=True).wait_for(state="detached", timeout=30_000)
                    target = target.resolve(strict=True)
                    source = target / plan["project"]["sourcePath"]
                    generated = {name: sha256(target / name) for name in (*DESCRIPTORS[variant], plan["project"]["sourcePath"], ".lithe/run/local.json")}
                    page.get_by_role("tab", selected=True).and_(page.get_by_title(target.as_posix(), exact=True)).wait_for(state="visible", timeout=30_000)
                    page.get_by_role("tab", selected=True).filter(has=page.get_by_title(source.as_posix(), exact=True)).wait_for(state="visible", timeout=30_000)
                    config = json.loads((target / ".lithe/run/local.json").read_text(encoding="utf-8"))
                    if not generated_jdk_matches(config, plan["jdk"]["home"]):
                        raise AssertionError("created project did not preserve the selected real JDK")
                    probes = [call for call in snapshot() if call["command"] == "declarative_plugins_generator_runtime" and call.get("settled")]
                    if not any(same_path(call.get("value", {}).get("homePath", ""), plan["jdk"]["home"])
                               and call["value"].get("version") == plan["jdk"]["version"] for call in probes):
                        raise AssertionError("native runtime probe differs from B's selected JDK")
                    generation = generated_operation(snapshot(), plan, target)
                    if not generation:
                        raise AssertionError("no actual completed generation operation")
                    write("generated-opened", {"variant": variant, "root": str(target), "source": str(source), "generatedFiles": generated,
                                              "localRun": config, "runtimeProbes": probes, "generation": generation,
                                              "javaPackageSha256": plan["package"]["archive"]["sha256"]})
                if variant != "plain":
                    with step("approved-build-model", 480_000):
                        build_workflow = JavaBuildWorkflow(page, driver, plan, target, raw_snapshot, wait, write)
                        build_workflow.prepare_model()
                with step(CASES[2], 240_000):
                    java = wait(lambda: ready_document_session(snapshot(), target, package_root, source), "real plugin-owned JDT document ready", 230)
                    write("java-readiness", java)
                with step(CASES[3]):
                    content = java_source("LITHE_JAVA_SAVED_BUILD_OK", package_name=plan["project"].get("groupId"))
                    saved = edit_save(content)
                    write("save-synchronize", saved)
                with step("workspace-switch-restore", 240_000):
                    local = target / ".lithe/run/local.json"
                    local_before = local.read_bytes()
                    visits = []
                    for workspace in (startup, target):
                        switch_workspace_tab(page, workspace, wait)
                        visits.append(str(workspace))
                        if owned_runs():
                            raise AssertionError("workspace switch started an unrequested process")
                    if local.read_bytes() != local_before or (startup / ".lithe/run/local.json").exists():
                        raise AssertionError("switching workspaces changed or leaked Java runtime selection")
                    page.get_by_role("tab", selected=True).filter(has=page.get_by_title(source.as_posix(), exact=True)).wait_for(state="visible", timeout=30_000)
                    if variant != "plain":
                        # Switching workspaces invalidates the build generation.
                        # Restore its reviewed model before waiting for Java import.
                        build_workflow.prepare_model()
                    java = wait(lambda: ready_document_session(snapshot(), target, package_root, source), "restored plugin JDT document", 180)
                    saved = edit_save(content + "\n// explicit workspace restoration\n")
                    write("workspace-switch-restore", {"visits": visits, "java": java, "save": saved, "localSha256": sha256(local)})
                if variant != "plain":
                    with step("approved-build-model-task", 480_000):
                        build_workflow.run_task(build_workflow.open(), build_workflow.instance)
                with step(CASES[4], 180_000):
                    # The default keymap opens the public Run tool window. A
                    # generic Run button could already launch a configuration.
                    if not page.get_by_role("navigation", name="Run configurations", exact=True).is_visible():
                        page.keyboard.press("Shift+F10")
                    row = run_row()
                    before_run = {owner.pid for owner in driver.capture_owned_tree(session.root_owner)}
                    click_java_run_action(row, wait)
                    prepared = wait(lambda: completed_preparation(snapshot(), source, main_class, java["sessionId"], saved["notification"]["sequence"], "ready"),
                                    "actual Core java.prepareLaunch completion", 150)
                    started = wait(lambda: next((call for call in snapshot() if call["command"] == "run_start_process" and call["sequence"] > prepared["request"]["sequence"] and call.get("settled") and not call.get("error")), None),
                                   "actual Java process start")
                    launch = started["args"]["args"]
                    assert_actual_launch(launch, prepared["result"]["target"], target, Path(plan["jdk"]["home"]), main_class)
                    wait(lambda: page.locator("pre").filter(has_text="LITHE_JAVA_SAVED_BUILD_OK").count() > 0, "actual Java stdout in Run pane")
                    owners = wait(lambda: rows if (rows := owned_runs()) and any(item["sessionId"] == launch["sessionId"] for item in rows) else None,
                                  "native run session owner")
                    tree = driver.capture_owned_tree(session.root_owner)
                    session.owned_tree = list(dict.fromkeys(session.owned_tree + tree))
                    java_processes = [owner for owner in tree if owner.pid not in before_run and owner.running()
                                      and same_path(owner.executable, launch["executable"])]
                    if len(java_processes) != 1:
                        raise AssertionError("could not bind stdout/run session to one retained actual Java child")
                    write("prepare-launch-run", {"preparation": prepared, "start": started, "owners": owners,
                                               "javaProcesses": [{"pid": owner.pid, "creationTime": owner.creation_time,
                                                                  "executable": owner.executable} for owner in java_processes],
                                               "output": page.locator("pre").filter(has_text="LITHE_JAVA_SAVED_BUILD_OK").inner_text(timeout=5000)})
                    page.screenshot(path=str(evidence / "java-running.png"), timeout=5000)
                if variant != "plain":
                    with step("declarative-build-run-binding"):
                        current_java = ready_session(snapshot(), target, package_root)
                        if not current_java or current_java["sessionId"] != java["sessionId"]:
                            raise AssertionError("build workflow replaced the original editor JDT session")
                        write("build-run-binding", {**build_workflow.binding(), "javaSessionId": java["sessionId"],
                                                  "prepareOperation": prepared["operationId"], "runSessionId": launch["sessionId"], "start": started})
                with step(CASES[5]):
                    row.get_by_role("button", name="Stop run", exact=True).click(timeout=10_000)
                    wait(lambda: not owned_runs(), "Stop reclaimed all actual native run owners", 20)
                    wait(lambda: not any(owner.running() for owner in java_processes), "Stop ended the retained actual Java process", 20)
                    stops = [call for call in snapshot() if call["command"] == "run_stop_process" and call.get("settled") and not call.get("error")]
                    if not any(call["args"].get("sessionId") == launch["sessionId"] for call in stops):
                        raise AssertionError("Stop did not address the observed run session")
                    write("stopped-run", {"stopCalls": stops, "owners": owned_runs()})
                with step("save-compilation-error"):
                    rejected = edit_save(java_source("unused", invalid=True, package_name=plan["project"].get("groupId")))
                if variant != "plain":
                    with step("build-compile-error-terminal", 240_000):
                        build_workflow.run_compile_error_task()
                    if not page.get_by_role("navigation", name="Run configurations", exact=True).is_visible():
                        page.keyboard.press("Shift+F10")
                with step(CASES[6], 180_000):
                    row.get_by_role("button", name="Run", exact=True).click(timeout=10_000)
                    build_failure = wait(lambda: completed_preparation(snapshot(), source, main_class, java["sessionId"], rejected["notification"]["sequence"], "buildFailed"),
                                         "real compilation error result", 150)
                    if build_failure["result"].get("failure", {}).get("code") != "javaBuildCompilationErrors":
                        raise AssertionError("compile-error case requires upstream compilation errors, not an internal build failure")
                    page.get_by_role("button", name="Run Anyway", exact=True).wait_for(state="visible", timeout=10_000)
                    page.get_by_role("button", name="Cancel", exact=True).click(timeout=10_000)
                    page.get_by_role("button", name="Run Anyway", exact=True).wait_for(state="detached", timeout=10_000)
                    calls = snapshot()
                    if owned_runs() or any(call["command"] == "run_start_process" and call["sequence"] > rejected["save"]["sequence"] for call in calls):
                        raise AssertionError("compile-error refusal started a process")
                    write("compile-error-refused", {"save": rejected, "preparation": build_failure, "owners": owned_runs()})
                with step("compile-error-explicit-recovery", 180_000):
                    restored = edit_save(java_source("LITHE_JAVA_RECOVERED_OK", package_name=plan["project"].get("groupId")))
                    before_recovery = {owner.pid for owner in driver.capture_owned_tree(session.root_owner)}
                    row.get_by_role("button", name="Run", exact=True).click(timeout=10_000)
                    recovery = wait(lambda: completed_preparation(snapshot(), source, main_class, java["sessionId"], restored["notification"]["sequence"], "ready"),
                                    "explicit recovery Core preparation", 150)
                    recovered_start = wait(lambda: next((call for call in snapshot() if call["command"] == "run_start_process"
                        and call["sequence"] > recovery["request"]["sequence"] and call.get("settled") and not call.get("error")), None), "recovered actual Java process")
                    assert_actual_launch(recovered_start["args"]["args"], recovery["result"]["target"], target, Path(plan["jdk"]["home"]), main_class)
                    wait(lambda: page.locator("pre").filter(has_text="LITHE_JAVA_RECOVERED_OK").count() > 0, "newly compiled recovery stdout")
                    retained = driver.capture_owned_tree(session.root_owner)
                    session.owned_tree = list(dict.fromkeys(session.owned_tree + retained))
                    recovery_children = [owner for owner in retained if owner.pid not in before_recovery and owner.running()
                        and same_path(owner.executable, recovered_start["args"]["args"]["executable"])]
                    if len(recovery_children) != 1:
                        raise AssertionError("recovery lacks one retained actual Java child")
                    row.get_by_role("button", name="Stop run", exact=True).click(timeout=10_000)
                    wait(lambda: not owned_runs(), "recovery Stop reclaimed native owners", 20)
                    wait(lambda: not any(owner.running() for owner in recovery_children), "recovery Stop ended actual Java child", 20)
                    write("compile-error-explicit-recovery", {"save": restored, "prepare": recovery, "start": recovered_start, "owners": owned_runs()})
                with step("disable-uninstall-cleanup"):
                    # Keep retained identities: a historical PID never grants
                    # cleanup authority. JDT is the product's own descendant.
                    retained = driver.capture_owned_tree(session.root_owner)
                    session.owned_tree = list(dict.fromkeys(session.owned_tree + retained))
                    resolved_package = package_root.resolve(strict=True)
                    jdt_children = [owner for owner in retained if owner.running()
                                    and Path(owner.executable).resolve(strict=True).is_relative_to(resolved_package)]
                    if not jdt_children:
                        raise AssertionError("no retained package-owned JDT process for disable cleanup proof")
                    for package in reversed(packages):
                        driver.open_plugin_settings(page)
                        item = page.locator("[data-testid='declarative-plugin-list'] "
                            f"[data-plugin-id='{package['pluginId']}'][data-plugin-source='installed']")
                        item.get_by_role("button").click(timeout=10_000)
                        details = page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=package["displayName"], exact=True)
                        details.get_by_role("button", name="Disable", exact=True).click(timeout=10_000)
                        wait(lambda: (row := catalog(package["pluginId"])) and not row["enabled"], "plugin disabled")
                        if package["pluginId"] == PLUGIN_ID:
                            wait(lambda: not any(owner.running() for owner in jdt_children), "disable stopped retained JDT children", 30)
                        verify_package(package)
                        details.get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
                        wait(lambda: catalog(package["pluginId"]) is None and not package["root"].parent.exists(), "actual package uninstall", 30)
                        package["uninstalled"] = True
                    if owned_runs():
                        raise AssertionError("disable/uninstall retained native run owners")
                    write("disabled-uninstalled", {"plugins": [package["pluginId"] for package in packages], "runOwners": owned_runs(),
                                                  "jdtStopped": not any(owner.running() for owner in jdt_children)})
            except Exception as error:
                failure = error
                raise
            finally:
                try:
                    if observer_started and page is not None and not page.is_closed():
                        stopped = page.evaluate("() => window.__litheJavaWorkflow.stop()")
                        observer_started = False
                        write("ipc", stopped)
                        assert_observer(stopped)
                        if not stopped["originalInvokeRestored"] or stopped["callbackWrappersRetained"]:
                            raise AssertionError("Java workflow observer did not restore the transport")
                except Exception as error:
                    failure = failure or error
                    write("observer-failure", {"type": type(error).__name__, "message": str(error)})
                try:
                    for package in packages:
                        if not package["uninstalled"]:
                            verify_package(package)
                except Exception as error:
                    failure = failure or error
                    write("package-resource-failure", {"type": type(error).__name__, "message": str(error)})
                try:
                    # Application quit needs the live Playwright transport.
                    # Finish graceful stop before leaving its context manager.
                    clean()
                except Exception as error:
                    failure = failure or error
    except Exception as error:
        failure = failure or error
        write("first-failure", {"type": type(error).__name__, "message": str(error)})
        driver.capture_session_failure(session, evidence)
    finally:
        reporter.runtime_executed = session is not None and session.process is not None
        try:
            if not cleanup_attempted:
                clean()
        except Exception as error:
            failure = failure or error
        try:
            with step(CASES[8]):
                after = snapshot_resources(args.run_image)
                write("resources-after", after)
                write("resources-diff", resource_diff(image_before, after))
                assert_resources(image_before, after)
                read_reference(plan["package"]["archive"])
                if variant != "plain":
                    read_reference(plan["buildPackage"]["archive"])
                for name in ("java", "javac"):
                    if sha256(Path(plan["jdk"]["home"]) / ("bin/" + name + ".exe")) != plan["jdk"][name + "Sha256"]:
                        raise AssertionError("selected JDK bytes changed during Java workflow")
        except Exception as error:
            failure = failure or error
        finally:
            for owner in driver.owned_processes.values():
                owner.close()
            driver.owned_processes.clear()
    if failure:
        raise failure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--controlled", action="store_true", help="Explicit non-production run with a separately pinned controlled signing key; native trust/approvals remain mandatory")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    for key in ("host-identity", "executable", "run-image", "artifact-root", "app-local-data", "app-roaming-data", "webview-data"):
        parser.add_argument("--" + key, type=Path)
    args = parser.parse_args()
    for key, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, key, value.absolute())
    if args.report.exists():
        parser.error("report must be absent; never adopt or overwrite an earlier run's evidence")
    plan = json.loads(args.plan.read_text(encoding="utf-8-sig"))
    if controlled_run(plan) != args.controlled:
        parser.error("assurance and explicit --controlled must agree")
    if not args.preflight and any(path is not None and path.exists() for path in
                                 (args.artifact_root, args.app_local_data, args.app_roaming_data, args.webview_data)):
        parser.error("run-owned evidence/profiles must be absent before preflight or the suite owner")
    document = preflight(plan, source_capabilities())
    # Refuse closed/missing prerequisites before the suite worker, Playwright,
    # isolated profiles, installation, or any product process can be created.
    if args.preflight or document["blocked"]:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes(json_bytes({"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000, **document}))
        return 2
    if any(getattr(args, key.replace("-", "_")) is None for key in ("host-identity", "executable", "run-image", "artifact-root", "app-local-data", "app-roaming-data", "webview-data")):
        parser.error("runtime requires final host identity/image and fresh isolated profile/evidence paths")
    if not args.worker:
        if any(path.exists() for path in (args.artifact_root, args.app_local_data, args.app_roaming_data, args.webview_data)):
            parser.error("run-owned evidence/profiles must be absent before starting the suite owner")
        if args.artifact_root.resolve() in args.report.resolve().parents:
            parser.error("normalized report must live outside the raw runtime evidence directory")
        from vcs_move_diagnostic import WindowsJob, cleanup_proven, supervised
        args.report.parent.mkdir(parents=True, exist_ok=True)
        result = supervised([sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:], "--worker"],
                            SUITE_SECONDS, args.report.with_suffix(".worker.log"), WindowsJob)
        args.artifact_root.mkdir(parents=True, exist_ok=True)
        (args.artifact_root / "suite-owner.json").write_bytes(json_bytes(result))
        report = json.loads(args.report.read_text(encoding="utf-8")) if args.report.exists() else {
            "runner": "acceptance", **workflow_result(plan, [], False),
            "tests": pending_rows("Worker did not finish; product success is not established.", workflow_variant(plan)) +
            [{"name": name, "suite": "plugin-host-acceptance / pending-platforms", "status": "skipped",
              "durationMs": 0, "maxMs": 1, "details": details} for name, details in PENDING.items()]}
        report["tests"].append({"name": "Java workflow suite owner", "suite": "plugin-host-acceptance / java-workflow",
                                "status": result["status"], "durationMs": result["durationMs"], "maxMs": SUITE_SECONDS * 1000,
                                "details": str(result)})
        if result["status"] != "passed" or not cleanup_proven(result):
            report["plainJavaPassed"] = False
            report["workflowPassed"] = False
            report["buildPluginPassed"] = False
            report["productionAcceptance"] = False
        args.report.write_bytes(json_bytes(report))
        return int(not report["workflowPassed"])
    import acceptance_driver as driver
    if (args.app_local_data.resolve() != (Path(os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER).resolve()
            or args.app_roaming_data.resolve() != (Path(os.environ["APPDATA"]) / driver.ACCEPTANCE_IDENTIFIER).resolve()
            or args.webview_data.name != "webview2"):
        parser.error("unexpected acceptance profile identity")
    if any(path.exists() for path in (args.artifact_root, args.app_local_data, args.app_roaming_data, args.webview_data)):
        parser.error("run-owned evidence/profiles must be absent")
    reporter = driver.Reporter(args.artifact_root / "progress.json")
    code = 0
    try:
        run(args, driver, reporter, plan)
    except Exception as error:
        print(f"{type(error).__name__}: {error}", flush=True)
        code = 1
    finally:
        done = {row["name"] for row in reporter.tests}
        reporter.tests.extend(row for row in pending_rows("Not reached. Helper success does not establish product execution.", workflow_variant(plan)) if row["name"] not in done)
        for name, details in PENDING.items():
            reporter.document_pending(name, details)
        outcome = workflow_result(plan, reporter.tests, getattr(reporter, "runtime_executed", False))
        if code:
            outcome.update(workflowPassed=False, plainJavaPassed=False, buildPluginPassed=False, productionAcceptance=False)
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
                          **outcome, "tests": reporter.tests})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
