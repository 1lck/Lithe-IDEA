#!/usr/bin/env python3
"""Opt-in generated plain Java UI/JDT/build/run acceptance, never simulated IPC.

Preflight starts nothing. Runtime needs final source/config/EXE identity, A's
production-trusted complete independent Java archive and B's real JDK/workspace
evidence. An unsigned candidate is blocked. Existing AppSession and the gated
Windows Job own every product, JDT, Java and observer process.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

from build_acceptance import missing_capabilities, source_capabilities
from generator_acceptance import cleanup_session, runtime_paths
from java_workflow_inputs import (CASES, PENDING, PLUGIN_ID, assert_actual_launch, assert_observer, completed_preparation,
                                  java_source, json_bytes, pending_rows, read_reference,
                                  ready_session, same_path, saved_and_synced, sha256, validate_plan)
from settings_functions_acceptance import (assert_resources, resource_diff, snapshot_resources,
                                          verify_host, verify_installed_archive, wait_for)
from text_window_fixture import source_inventory
from web_bridge_fallback_acceptance import require_x64_executable

OBSERVER = Path(__file__).with_name("java_workflow_observer.js").read_text(encoding="utf-8")
SUITE_SECONDS = 900
WORK_SECONDS = 720


def preflight(plan: dict, capabilities: dict) -> dict:
    manifest, blocked = validate_plan(plan)
    missing = missing_capabilities(manifest["requires"], capabilities)
    blocked.extend("closed capability " + item for item in missing)
    reason = "Not executed. " + ("; ".join(blocked) if blocked else "Explicit isolated final-source product invocation required.")
    return {"complete": False, "plainJavaPassed": False, "runtimeExecuted": False,
            "blocked": blocked, "requires": manifest["requires"], "tests": pending_rows(reason) +
            [{"name": name, "suite": "plugin-host-acceptance / pending-platforms", "status": "skipped",
              "durationMs": 0, "maxMs": 1, "details": details} for name, details in PENDING.items()]}


def run(args, driver, reporter, plan):
    work_deadline = time.monotonic() + WORK_SECONDS
    manifest, blocked = validate_plan(plan)
    blocked.extend("closed capability " + value for value in missing_capabilities(manifest["requires"], source_capabilities()))
    if blocked:
        raise ValueError("Java workflow prerequisites blocked: " + "; ".join(blocked))
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
    package_before = None
    failure = None
    cleanup_complete = False
    observer_started = False

    def write(name, value):
        driver.write_json(evidence / (name + ".json"), value)

    def snapshot():
        return assert_observer(page.evaluate("() => window.__litheJavaWorkflow.snapshot()"))

    def wait(predicate, description, seconds=30):
        remaining = work_deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Java workflow work deadline: " + description)
        return wait_for(predicate, description, pump=lambda: page.locator("body").count(), seconds=min(seconds, remaining))

    @contextmanager
    def step(name, max_ms=120_000):
        started = time.monotonic()
        with reporter.step("plain-java / " + name, max_ms=max_ms):
            if name not in CASES[7:] and started >= work_deadline:
                raise TimeoutError("Java workflow exhausted its work deadline before cleanup")
            yield
            if (time.monotonic() - started) * 1000 >= max_ms:
                raise TimeoutError("Java workflow case exceeded its local budget: " + name)

    def catalog():
        return next((row for row in driver.invoke(page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)

    def clean():
        nonlocal cleanup_complete
        with step(CASES[7]):
            cleanup = cleanup_session(args, driver, session)
            write("cleanup", cleanup)
            if cleanup["survivors"] or cleanup["errors"] or not cleanup["profilesAbsent"]:
                raise AssertionError("Java workflow cleanup failed: " + str(cleanup))
            cleanup_complete = True

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
        # Native keyboard insertion reaches the real Monaco model; no store or
        # test-only editor API is called. Ctrl+S owns the actual product save.
        page.keyboard.insert_text(content)
        page.keyboard.press("Control+S")
        wait(lambda: source.read_text(encoding="utf-8") == content, "saved Java bytes")
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
                    review = driver.import_review(page, session.process.pid, archive)
                    review_text = review.inner_text(timeout=10_000)
                    if "Unverified publisher" in review_text:
                        raise AssertionError("production Java package was presented as unverified")
                    write("install-review", {"text": review_text, "requires": manifest["requires"]})
                    driver.confirm_review(page, review)
                    installed = wait(lambda: row if (row := catalog()) and row["status"] == "accepted" and row["enabled"] else None,
                                     "complete production-trusted Java package accepted", 60)
                    write("catalog", installed)
                    verify_installed_archive(package_root, archive, evidence / "installed-package.json")
                    package_before = snapshot_resources(package_root)
                    write("package-resources-before", package_before)
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
                    page.get_by_role("button", name=generator["displayName"] + " · " + manifest["displayName"], exact=True).click(timeout=10_000)
                    page.locator("#generator-name").fill(plan["project"]["name"], timeout=10_000)
                    page.locator("#generator-location").fill(str(projects), timeout=10_000)
                    build = next(field for field in generator["fields"] if field["id"] == "buildSystem")
                    plain = next(option for option in build["options"] if option["value"] == "none")
                    page.get_by_role("group", name=build["title"], exact=True).get_by_role("button", name=plain["title"], exact=True).click(timeout=10_000)
                    page.locator("#generator-field-jdk").click(timeout=10_000)
                    driver.select_native_file(session.process.pid, Path(plan["jdk"]["home"]))
                    review_button = page.get_by_role("button", name="Review creation", exact=True)
                    wait(lambda: review_button.is_enabled(), "native runtime probe and valid Java form")
                    review_button.click(timeout=10_000)
                    page.screenshot(path=str(evidence / "generation-review.png"), timeout=5000)
                    page.get_by_role("button", name="Create project", exact=True).click(timeout=10_000)
                    wait(lambda: (target / plan["project"]["sourcePath"]).is_file(), "actual generated Java source", 60)
                    page.get_by_role("heading", name="Plugin project generators", exact=True).wait_for(state="detached", timeout=30_000)
                    target = target.resolve(strict=True)
                    source = target / plan["project"]["sourcePath"]
                    page.get_by_role("tab", selected=True).and_(page.get_by_title(target.as_posix(), exact=True)).wait_for(state="visible", timeout=30_000)
                    page.get_by_role("tab", selected=True).filter(has=page.get_by_title(source.as_posix(), exact=True)).wait_for(state="visible", timeout=30_000)
                    config = json.loads((target / ".lithe/run/local.json").read_text(encoding="utf-8"))
                    if not same_path(config["toolchain"]["javaHomePath"], plan["jdk"]["home"]):
                        raise AssertionError("created project did not preserve the selected real JDK")
                    probes = [call for call in snapshot() if call["command"] == "declarative_plugins_generator_runtime" and call.get("settled")]
                    if not any(same_path(call.get("value", {}).get("homePath", ""), plan["jdk"]["home"])
                               and call["value"].get("version") == plan["jdk"]["version"] for call in probes):
                        raise AssertionError("native runtime probe differs from B's selected JDK")
                    write("generated-opened", {"root": str(target), "source": str(source), "sourceSha256": sha256(source), "localRun": config, "runtimeProbes": probes})
                with step(CASES[2], 240_000):
                    java = wait(lambda: ready_session(snapshot(), target, package_root), "real plugin-owned JDT service ready", 230)
                    write("java-readiness", java)
                with step(CASES[3]):
                    content = java_source("LITHE_JAVA_SAVED_BUILD_OK")
                    saved = edit_save(content)
                    write("save-synchronize", saved)
                with step(CASES[4], 180_000):
                    # The default keymap opens the public Run tool window. A
                    # generic Run button could already launch a configuration.
                    if not page.get_by_role("navigation", name="Run configurations", exact=True).is_visible():
                        page.keyboard.press("Shift+F10")
                    row = run_row()
                    before_run = {owner.pid for owner in driver.capture_owned_tree(session.root_owner)}
                    row.get_by_role("button", name="Run", exact=True).click(timeout=10_000)
                    prepared = wait(lambda: completed_preparation(snapshot(), source, "Main", java["sessionId"], saved["notification"]["sequence"], "ready"),
                                    "actual Core java.prepareLaunch completion", 150)
                    started = wait(lambda: next((call for call in snapshot() if call["command"] == "run_start_process" and call["sequence"] > prepared["request"]["sequence"] and call.get("settled") and not call.get("error")), None),
                                   "actual Java process start")
                    launch = started["args"]["args"]
                    assert_actual_launch(launch, prepared["result"]["target"], target, Path(plan["jdk"]["home"]))
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
                with step(CASES[5]):
                    row.get_by_role("button", name="Stop", exact=True).click(timeout=10_000)
                    wait(lambda: not owned_runs(), "Stop reclaimed all actual native run owners", 20)
                    wait(lambda: not any(owner.running() for owner in java_processes), "Stop ended the retained actual Java process", 20)
                    stops = [call for call in snapshot() if call["command"] == "run_stop_process" and call.get("settled") and not call.get("error")]
                    if not any(call["args"].get("sessionId") == launch["sessionId"] for call in stops):
                        raise AssertionError("Stop did not address the observed run session")
                    write("stopped-run", {"stopCalls": stops, "owners": owned_runs()})
                with step(CASES[6], 180_000):
                    rejected = edit_save(java_source("unused", invalid=True))
                    row.get_by_role("button", name="Run", exact=True).click(timeout=10_000)
                    build_failure = wait(lambda: completed_preparation(snapshot(), source, "Main", java["sessionId"], rejected["notification"]["sequence"], "buildFailed"),
                                         "real compilation error result", 150)
                    page.get_by_role("button", name="Run Anyway", exact=True).wait_for(state="visible", timeout=10_000)
                    page.get_by_role("button", name="Cancel", exact=True).click(timeout=10_000)
                    page.get_by_role("button", name="Run Anyway", exact=True).wait_for(state="detached", timeout=10_000)
                    calls = snapshot()
                    if owned_runs() or any(call["command"] == "run_start_process" and call["sequence"] > rejected["save"]["sequence"] for call in calls):
                        raise AssertionError("compile-error refusal started a process")
                    write("compile-error-refused", {"save": rejected, "preparation": build_failure, "owners": owned_runs()})
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
                    if package_before is not None:
                        package_after = snapshot_resources(package_root)
                        write("package-resources-after", package_after)
                        write("package-resources-diff", resource_diff(package_before, package_after))
                        assert_resources(package_before, package_after)
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
            if not cleanup_complete:
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
    if args.preflight:
        document = preflight(plan, source_capabilities())
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
            "runner": "acceptance", "complete": False, "plainJavaPassed": False,
            "runtimeExecuted": False, "tests": pending_rows("Worker did not finish; product success is not established.") +
            [{"name": name, "suite": "plugin-host-acceptance / pending-platforms", "status": "skipped",
              "durationMs": 0, "maxMs": 1, "details": details} for name, details in PENDING.items()]}
        report["tests"].append({"name": "Java workflow suite owner", "suite": "plugin-host-acceptance / java-workflow",
                                "status": result["status"], "durationMs": result["durationMs"], "maxMs": SUITE_SECONDS * 1000,
                                "details": str(result)})
        if result["status"] != "passed" or not cleanup_proven(result):
            report["plainJavaPassed"] = False
        args.report.write_bytes(json_bytes(report))
        return int(not report["plainJavaPassed"])
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
        reporter.tests.extend(row for row in pending_rows("Not reached. Helper success does not establish product execution.") if row["name"] not in done)
        for name, details in PENDING.items():
            reporter.document_pending(name, details)
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
                          "complete": False, "plainJavaPassed": code == 0,
                          "runtimeExecuted": getattr(reporter, "runtime_executed", False), "tests": reporter.tests})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
