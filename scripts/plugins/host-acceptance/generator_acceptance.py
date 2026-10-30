#!/usr/bin/env python3
"""Opt-in project-generator production UI/IPC acceptance using the existing owner.

Preflight launches nothing. Runtime consumes a source-bound isolated Release,
installs the complete unsigned fixture through normal review, and keeps real
published packages, language/build providers and ARM64 explicitly pending.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import sys
import time
from contextlib import contextmanager
from pathlib import Path

from build_acceptance import missing_capabilities, source_capabilities
from build_fixture import confined, json_bytes
from generator_fixture import (CANCEL_OBSERVATION_SECONDS, COMMAND_TIMEOUT_SECONDS, DISPLAY_NAME,
                               PLUGIN_ID, REQUIRES, load_plan, sha256, source_inventory,
                               verify_extracted_reference)
from settings_functions_acceptance import assert_resources, resource_diff, snapshot_resources, verify_host, verify_installed_archive, wait_for
from web_bridge_fallback_acceptance import require_x64_executable

CASES = ("complete-package-install-review", "files-ui-create-git-open", "command-ui-collect-open",
         "https-archive-ui-open", "missing-runtime-and-advisory-requirements", "existing-target-preserved",
         "failed-command-cleanup", "cancel-command-cleanup", "closed-wizard-cleanup",
         "disable-and-uninstall", "product-profile-cleanup", "resource-invariance")


def pending_rows(reason: str) -> list[dict]:
    return [{"name": "controlled-generators / " + name, "suite": "plugin-host-acceptance / generators",
             "status": "skipped", "durationMs": 0, "maxMs": 120_000, "details": reason}
            for name in CASES]


def preflight(plan: dict, capabilities: dict) -> dict:
    missing = missing_capabilities(plan["requires"], capabilities)
    return {"complete": False, "missingCapabilities": missing, "requires": plan["requires"],
            "runtimeExecuted": False, "tests": pending_rows(
                "Not executed. " + ("Closed complete-package prerequisites: " + ", ".join(missing)
                                    if missing else "Explicit isolated source-bound product invocation required"))}


def assert_clean_projects(parent: Path, *absent: str) -> None:
    stages = sorted(path.name for path in parent.iterdir() if ".lithe-creating-" in path.name)
    if stages or any((parent / name).exists() for name in absent):
        raise AssertionError(f"generator left partial output/staging: {stages}; targets: {absent}")


def installation_review_text(review) -> str:
    # Program details are collapsed by the product until explicitly disclosed.
    review.get_by_role("button", name=re.compile(r"^Program declaration \(\d+\)$")).click(timeout=10_000)
    review.locator("pre").wait_for(state="visible", timeout=5000)
    return review.inner_text(timeout=5000)


def cancel_generation(page) -> None:
    page.get_by_role("button", name="Cancel generation", exact=True).click(timeout=10_000)


def runtime_paths(args) -> None:
    """Bind the immutability claim to the actual launched image and its inputs."""
    image, executable = args.run_image.resolve(strict=True), args.executable.resolve(strict=True)
    if executable.parent != image:
        raise ValueError("executable must belong to the exact snapshotted run image")
    for value in (args.artifact_root, args.app_local_data, args.app_roaming_data, args.webview_data,
                  args.fixture_root, args.host_identity):
        value = value.resolve()
        if value == image or value in image.parents or image in value.parents:
            raise ValueError("run image overlaps writable evidence/profile or fixture input")
    if args.artifact_root.resolve() == args.fixture_root.resolve() or args.fixture_root.resolve() in args.artifact_root.resolve().parents:
        raise ValueError("runtime evidence must not mutate the fixture input tree")


def observe_cancelled(owner, wait, started_at, closed=None, now=time.monotonic) -> None:
    # Creation, marker observation and UI activation must leave the whole
    # cancellation interval before the native timeout or finite child failsafe.
    if CANCEL_OBSERVATION_SECONDS >= COMMAND_TIMEOUT_SECONDS:
        raise ValueError("cancellation observation cannot include natural command timeout")
    if now() - started_at + CANCEL_OBSERVATION_SECONDS >= COMMAND_TIMEOUT_SECONDS:
        raise TimeoutError("command too old to distinguish cancellation from natural timeout")
    deadline = now() + CANCEL_OBSERVATION_SECONDS
    def observe(predicate, description):
        remaining = deadline - now()
        if remaining <= 0:
            raise TimeoutError("shared cancellation observation deadline")
        wait(predicate, description, remaining)
    if closed is not None:
        observe(closed, "real generator wizard unmounted")
    observe(lambda: not owner.running(), "cancelled generator child exited")


def owned_marker_process(driver, session, pid):
    """A marker PID is evidence only; adopt only a retained current descendant."""
    captured = driver.capture_owned_tree(session.root_owner)
    session.owned_tree = list(dict.fromkeys(session.owned_tree + captured))
    owner = next((owner for owner in session.owned_tree if owner.pid == pid and owner.running()), None)
    if owner is None:
        raise AssertionError("pending generator child is not a retained product descendant")
    return owner


def cleanup_session(args, driver, session) -> dict:
    errors = []
    shutdown = None
    try:
        if session is not None:
            shutdown = session.stop(require_graceful=True)
    except Exception as error:
        errors.append(f"shutdown: {error}")
    # Use the existing retained process identities on every failure path.
    # The outer gated Windows Job remains the final owner if cleanup fails.
    for owner in list(driver.owned_processes.values()):
        try:
            if owner.running():
                driver.terminate_process_tree(owner.pid)
        except Exception as error:
            errors.append(f"process cleanup: {error}")
    survivors = []
    for owner in driver.owned_processes.values():
        try:
            if owner.running():
                survivors.append(owner.pid)
        except Exception as error:
            errors.append(f"process inspection: {error}")
            survivors.append(owner.pid)
    if not survivors:
        for path, name in ((args.app_local_data, driver.ACCEPTANCE_IDENTIFIER),
                           (args.app_roaming_data, driver.ACCEPTANCE_IDENTIFIER), (args.webview_data, "webview2")):
            try:
                driver.safe_remove_owned_directory(path, path.parent, name)
            except Exception as error:
                errors.append(f"profile cleanup: {error}")
    profiles_absent = not any(path.exists() for path in (args.app_local_data, args.app_roaming_data, args.webview_data))
    return {"shutdown": shutdown, "survivors": survivors, "errors": errors, "profilesAbsent": profiles_absent}


def run(args, driver, reporter, plan):
    missing = missing_capabilities(plan["requires"], source_capabilities())
    if missing:
        raise ValueError("closed complete-package prerequisites: " + ", ".join(missing))
    identity = verify_host(args.host_identity, args.executable, plan)
    if (identity.get("sourceInventory") != plan["sourceInventory"] or source_inventory() != plan["sourceInventory"]
            or identity.get("configSha256") != sha256(args.host_identity.with_name("tauri.host-acceptance.conf.json"))
            or platform.machine().lower() not in ("amd64", "x86_64")):
        raise ValueError("full run-source/config/x64 host identity mismatch")
    runtime_paths(args)
    if not plan.get("archiveReference") or not plan.get("archiveInput"):
        raise ValueError("runtime requires the explicit fixed HTTPS archive reference and receipt")
    require_x64_executable(args.executable)
    evidence, projects = args.artifact_root, args.fixture_root / "projects"
    if any(projects.iterdir()):
        raise ValueError("runtime requires fresh empty run-owned generator project output")
    evidence.mkdir(parents=True, exist_ok=False)
    image_before = snapshot_resources(args.run_image)
    archive_before = sha256(confined(args.fixture_root, plan["archive"]["path"]))
    package_root = args.app_local_data / "plugins" / PLUGIN_ID / "1.0.0"
    package_before = None
    session = page = None
    failure = None
    cleanup_complete = False
    work_deadline = time.monotonic() + 480
    def write(name, value):
        driver.write_json(evidence / (name + ".json"), value)
    @contextmanager
    def step(name):
        with reporter.step("controlled-generators / " + name):
            # Reserve two minutes of the external 600s Job limit for native
            # shutdown, resource snapshots and profile cleanup after failures.
            if name not in CASES[10:] and time.monotonic() >= work_deadline:
                raise TimeoutError("generator workflow exhausted its work deadline before cleanup")
            yield
    def wait(predicate, description, seconds=20):
        remaining = work_deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("generator workflow deadline: " + description)
        return wait_for(predicate, description, pump=lambda: page.locator("body").count(), seconds=min(seconds, remaining))
    def catalog():
        return next((row for row in driver.invoke(page, "declarative_plugins_state")
                     if row["pluginId"] == PLUGIN_ID and row["source"] == "installed"), None)
    def details():
        driver.open_plugin_settings(page)
        page.locator(f"[data-plugin-id='{PLUGIN_ID}'][data-plugin-source='installed']").get_by_role("button").click(timeout=10_000)
        return page.locator("[data-settings-content='declarative-plugins']").get_by_role("region", name=DISPLAY_NAME, exact=True)
    def wizard(generator, name, *, disabled=False):
        driver.close_settings(page)
        page.get_by_role("menuitem", name="File", exact=True).click(timeout=10_000)
        page.get_by_role("menuitem", name="New", exact=True).hover(timeout=10_000)
        page.get_by_role("menuitem", name="New Project…", exact=True).click(timeout=10_000)
        page.get_by_text("Plugin project generators", exact=True).click(timeout=10_000)
        label = f"Acceptance {generator} · {DISPLAY_NAME}" + (" · Disabled" if disabled else "")
        page.get_by_role("button", name=label, exact=True).click(timeout=10_000)
        page.locator("#generator-name").fill(name, timeout=10_000)
        page.locator("#generator-location").fill(str(projects), timeout=10_000)
        page.get_by_role("button", name="Review creation", exact=True).wait_for(state="visible", timeout=10_000)
    def review_and_create(name, *, create_git=False):
        if create_git:
            page.get_by_label("Create Git repository", exact=True).check(timeout=10_000)
        page.get_by_role("button", name="Review creation", exact=True).click(timeout=10_000)
        create = page.get_by_role("button", name="Create project", exact=True)
        create.wait_for(state="visible", timeout=10_000)
        page.screenshot(path=str(evidence / (name + "-review.png")), timeout=5000)
        started_at = time.monotonic()
        create.click(timeout=10_000)
        return started_at
    def created(name, open_file):
        target = projects / name
        wait(lambda: target.is_dir() and (target / open_file).is_file(), "published " + name, 90)
        page.locator("#generator-name").wait_for(state="detached", timeout=30_000)
        # This is the actual editor produced by openFiles, not a native IPC open.
        page.get_by_role("tab", name=re.compile(re.escape(Path(open_file).name))).first.wait_for(state="visible", timeout=30_000)
        assert_clean_projects(projects)
        write(name + "-project", snapshot_resources(target))
        page.screenshot(path=str(evidence / (name + "-opened.png")), timeout=5000)
        return target
    try:
        write("identity", {"host": identity, "fixture": plan})
        write("resources-before", image_before)
        args.app_roaming_data.mkdir(parents=True, exist_ok=False)
        (args.app_roaming_data / "settings.json").write_bytes(json_bytes({"displayLanguage": "en-US"}))
        with driver.sync_playwright() as playwright:
            try:
                with step(CASES[0]):
                    session = driver.AppSession(playwright, args.executable, args.fixture_root / "workspace", args.webview_data, evidence / "app", 1)
                    reporter.capture_failure = lambda: driver.capture_session_failure(session, evidence)
                    page = session.start()
                    page.set_default_timeout(10_000)
                    driver.finish_onboarding(page)
                    review = driver.import_review(page, session.process.pid, confined(args.fixture_root, plan["archive"]["path"]))
                    text = installation_review_text(review)
                    if "Unverified publisher" not in text or "project.generate" not in text or "node" not in text:
                        raise AssertionError("complete unsigned generator permissions/program review missing")
                    write("install-review", {"text": text, "requires": plan["requires"]})
                    driver.confirm_review(page, review)
                    wait(lambda: (row if (row := catalog()) and row["status"] == "accepted" and row["enabled"] else None), "accepted complete generator package")
                    record = json.loads((package_root.parent / "installation.json").read_text(encoding="utf-8"))
                    if record["disk"]["archiveSha256"] != plan["archive"]["sha256"]:
                        raise AssertionError("approved generator archive identity mismatch")
                    write("installation", record)
                    verify_installed_archive(package_root, confined(args.fixture_root, plan["archive"]["path"]), evidence / "installed-package.json")
                    package_before = snapshot_resources(package_root)
                with step(CASES[1]):
                    wizard("Files", "Files Project")
                    page.locator("#generator-field-message").fill("Kept user input", timeout=10_000)
                    if not page.get_by_role("button", name="Find lithe-acceptance-missing in plugin marketplace", exact=True).is_visible():
                        raise AssertionError("missing requirement is not an advisory marketplace action")
                    review_and_create("Files Project", create_git=True)
                    target = created("Files Project", "main.mjs")
                    if "Kept user input" not in (target / "README.md").read_text(encoding="utf-8") or not (target / ".git").is_dir():
                        raise AssertionError("template values or Git initialization were lost")
                with step(CASES[2]):
                    wizard("Command", "Command Project")
                    review_and_create("Command Project")
                    target = created("Command Project", "main.mjs")
                    if (target / "result").exists() or "approved command" not in (target / "README.md").read_text(encoding="utf-8"):
                        raise AssertionError("command collect was not applied")
                with step(CASES[3]):
                    wizard("Archive", "Archive Project")
                    review_and_create("Archive Project")
                    target = created("Archive Project", plan["archiveOpenFile"])
                    actual_files = verify_extracted_reference(Path(plan["archiveReference"]), target)
                    write("archive-input", {"reference": plan["archiveInput"], "actualFileSha256": actual_files,
                                            "kind": "explicit HTTPS upstream archive; no archive content was executed"})
                with step(CASES[4]):
                    wizard("Missing Runtime", "No Runtime")
                    if page.get_by_role("button", name="Review creation", exact=True).is_enabled():
                        raise AssertionError("required unavailable runtime did not prevent review")
                    page.get_by_role("button", name="Back", exact=True).click(timeout=10_000)
                    page.keyboard.press("Escape")
                    assert_clean_projects(projects, "No Runtime")
                with step(CASES[5]):
                    existing = projects / "Existing"
                    existing.mkdir()
                    (existing / "sentinel.txt").write_text("preserve bytes", encoding="utf-8")
                    before = snapshot_resources(existing)
                    wizard("Files", "Existing")
                    page.get_by_role("button", name="Review creation", exact=True).click(timeout=10_000)
                    page.get_by_role("alert").first.wait_for(state="visible", timeout=10_000)
                    assert_resources(before, snapshot_resources(existing))
                    page.keyboard.press("Escape")
                    assert_clean_projects(projects)
                for mode, name, case in (("Failure", "Failure Project", CASES[6]), ("Wait", "Cancelled Project", CASES[7]), ("Wait", "Closed Project", CASES[8])):
                    with step(case):
                        wizard("Command", name)
                        page.get_by_role("button", name=mode, exact=True).click(timeout=10_000)
                        started_at = review_and_create(name)
                        if mode == "Wait":
                            marker = wait(lambda: next(iter(projects.glob(f".{name}.lithe-creating-*/.generator-ready")), None), "owned command ready")
                            child = json.loads(marker.read_text(encoding="utf-8"))["pid"]
                            owner = owned_marker_process(driver, session, child)
                            if case == CASES[7]:
                                cancel_generation(page)
                            else:
                                page.keyboard.press("Escape")
                            closed = (lambda: page.get_by_role("heading", name="Plugin project generators", exact=True).count() == 0) if case == CASES[8] else None
                            observe_cancelled(owner, wait, started_at, closed)
                        else:
                            page.get_by_role("alert").first.wait_for(state="visible", timeout=15_000)
                        wait(lambda: not any(projects.glob(f".{name}.lithe-creating-*")), "staging cleanup")
                        assert_clean_projects(projects, name)
                        write(case, {"targetAbsent": True, "stagingAbsent": True})
                        page.keyboard.press("Escape")
                with step(CASES[9]):
                    assert_resources(package_before, snapshot_resources(package_root))
                    region = details()
                    region.get_by_role("button", name="Disable", exact=True).click(timeout=10_000)
                    wait(lambda: (row if (row := catalog()) and not row["enabled"] else None), "generator disabled")
                    native_catalog = driver.invoke(page, "declarative_plugins_generator_catalog")
                    own = [row for row in native_catalog["generators"] if row["pluginID"] == PLUGIN_ID]
                    if len(own) != 4 or any(row["pluginEnabled"] for row in own):
                        raise AssertionError("disabled generators must remain inspectable but disabled")
                    wizard("Files", "Enable Only", disabled=True)
                    if page.get_by_role("button", name="Review creation", exact=True).is_enabled():
                        raise AssertionError("disabled generator was executable")
                    page.get_by_role("button", name=f"Enable {DISPLAY_NAME}", exact=True).click(timeout=10_000)
                    wait(lambda: (row if (row := catalog()) and row["enabled"] else None), "generator explicitly enabled from wizard")
                    page.get_by_role("button", name="Review creation", exact=True).wait_for(state="visible", timeout=10_000)
                    wait(lambda: page.get_by_role("button", name="Review creation", exact=True).is_enabled(), "enabled generator review")
                    page.keyboard.press("Escape")
                    page.get_by_role("heading", name="Plugin project generators", exact=True).wait_for(state="detached", timeout=10_000)
                    assert_clean_projects(projects, "Enable Only")
                    region = details()
                    region.get_by_role("button", name="Uninstall", exact=True).click(timeout=10_000)
                    wait(lambda: catalog() is None, "generator uninstall")
            except Exception as error:
                failure = error
                write("first-failure", {"type": type(error).__name__, "message": str(error)})
                driver.capture_session_failure(session, evidence)
            finally:
                with step(CASES[10]):
                    cleanup = cleanup_session(args, driver, session)
                    write("cleanup", cleanup)
                    if cleanup["survivors"] or cleanup["errors"] or not cleanup["profilesAbsent"]:
                        raise RuntimeError(f"generator acceptance cleanup failed: {cleanup}")
                    cleanup_complete = True
    except Exception as error:
        failure = failure or error
        write("outer-failure", {"type": type(error).__name__, "message": str(error)})
    finally:
        # Context-manager entry/teardown can fail before the ordinary inner
        # finally runs. Retry the same retained owners, never a new PID search.
        if not cleanup_complete:
            try:
                with step(CASES[10]):
                    cleanup = cleanup_session(args, driver, session)
                    write("cleanup-retry", cleanup)
                    if cleanup["survivors"] or cleanup["errors"] or not cleanup["profilesAbsent"]:
                        raise RuntimeError(f"generator acceptance cleanup failed: {cleanup}")
                    cleanup_complete = True
            except Exception as error:
                failure = failure or error
        try:
            with step(CASES[11]):
                after = snapshot_resources(args.run_image)
                write("resources-after", after)
                write("resources-diff", resource_diff(image_before, after))
                assert_resources(image_before, after)
                if sha256(confined(args.fixture_root, plan["archive"]["path"])) != archive_before:
                    raise AssertionError("complete fixture ZIP bytes changed")
                if package_before is not None and package_root.exists():
                    assert_resources(package_before, snapshot_resources(package_root))
                if not cleanup_complete:
                    raise AssertionError("cleanup did not complete before final resource comparison")
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
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    for key in ("host-identity", "executable", "run-image", "artifact-root", "app-local-data", "app-roaming-data", "webview-data"):
        parser.add_argument("--" + key, type=Path)
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.absolute())
    plan = load_plan(args.fixture_root)
    if args.preflight:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes(json_bytes({"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000, **preflight(plan, source_capabilities())}))
        return 2
    if any(getattr(args, key.replace("-", "_")) is None for key in ("host-identity", "executable", "run-image", "artifact-root", "app-local-data", "app-roaming-data", "webview-data")):
        parser.error("runtime requires all isolated host identity, image, evidence and profile paths")
    if not args.worker:
        # Reuse the existing assign-before-release Job owner. The driver and
        # every product, browser and generator child share one 600s hard limit.
        # No product can start before the trusted bootstrap joins the Job.
        from vcs_move_diagnostic import WindowsJob, cleanup_proven, supervised
        args.report.parent.mkdir(parents=True, exist_ok=True)
        result = supervised([sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:], "--worker"],
                            600, args.report.with_suffix(".worker.log"), WindowsJob)
        # Keep raw owner evidence out of the normalized report aggregation.
        # The worker requires its evidence root to be absent when it starts.
        args.artifact_root.mkdir(parents=True, exist_ok=True)
        (args.artifact_root / "suite-owner.json").write_bytes(json_bytes(result))
        report = (json.loads(args.report.read_text(encoding="utf-8")) if args.report.exists()
                  else {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
                        "tests": pending_rows("Not executed to completion.")})
        report["tests"].append({"name": "generator suite owner", "status": result["status"],
                                "durationMs": result["durationMs"], "maxMs": 600_000,
                                "details": str(result)})
        args.report.write_bytes(json_bytes(report))
        if result["status"] != "passed" or not cleanup_proven(result):
            report["controlledSubsetPassed"] = False
            args.report.write_bytes(json_bytes(report))
            return 1
        return 0
    import acceptance_driver as driver
    if (args.app_local_data.resolve() != Path(os.environ["LOCALAPPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
            or args.app_roaming_data.resolve() != Path(os.environ["APPDATA"]) / driver.ACCEPTANCE_IDENTIFIER
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
        reporter.tests.extend(row for row in pending_rows("Not reached; helper tests do not establish product execution.") if row["name"] not in done)
        reporter.document_pending("complete-M10", "Published signed complete Windows packages, creation-to-language/build/run integration, Windows ARM64 and other M10 capabilities remain pending.")
        driver.write_json(args.report, {"runner": "acceptance", "warnMs": 30_000, "maxMs": 120_000,
                          "complete": False, "controlledSubsetPassed": code == 0, "tests": reporter.tests})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
