"""Real build-registry UI workflow; no tool execution or project model of its own."""
from __future__ import annotations

import re
from pathlib import Path

from java_workflow_inputs import archive_manifest, assert_observer, same_path

EXECUTION_COMMANDS = ("declarative_plugins_build_load_model", "declarative_plugins_build_execute_run")
IDENTITY = ("operationId", "pluginId", "buildSystemId", "root", "workspaceRoot", "generation")


def matching_call(calls, command, after):
    """Incomplete replies remain pending; an actual native failure fails the case."""
    for call in calls:
        if call["command"] != command or call["sequence"] <= after or not call.get("settled"):
            continue
        if call.get("error"):
            raise AssertionError(command + " failed: " + str(call["error"]))
        return call
    return None


def assert_review(review, plan, target, generation):
    package = plan["buildPackage"]
    if (review.get("pluginId") != package["pluginId"] or review.get("buildSystemId") != package["buildSystemId"]
            or not same_path(review.get("workspaceRoot", ""), target) or review.get("root") != "."
            or review.get("generation") != generation or not review.get("operationId")):
        raise AssertionError("build review has a foreign plugin/workspace/generation/instance/operation")
    provider = review.get("provider")
    if provider is not None:
        context = provider["context"]
        if (context.get("pluginId") != package["pluginId"] or context.get("buildSystem") != package["buildSystemId"]
                or not same_path(context.get("workspaceRoot", ""), target) or context.get("instanceRoot") != "."
                or context.get("generation") != generation or not context.get("packageIdentity")
                or provider.get("program", {}).get("pluginId") != package["pluginId"]):
            raise AssertionError("provider review lost its package/context binding")


def model_instance(view, plan, target, generation=None):
    if (not same_path(view.get("workspaceRoot", ""), target)
            or not isinstance(view.get("generation"), int)
            or (generation is not None and view["generation"] != generation)):
        raise AssertionError("build model belongs to another workspace generation")
    package = plan["buildPackage"]
    rows = [row for row in view.get("instances", []) if row.get("pluginID") == package["pluginId"]
            and row.get("buildSystemID") == package["buildSystemId"] and row.get("root") == "."]
    if len(rows) != 1:
        raise AssertionError("expected one independently installed build instance at the generated root")
    return rows[0]


def approved_result(calls, command, review, after):
    call = matching_call(calls, command, after)
    if call and call["args"].get("operationId") != review["operationId"]:
        raise AssertionError("execution did not consume the reviewed operation")
    return call


def assert_selected_runtime(prepared, plan):
    executable = prepared["args"].get("runtimeExecutables", {}).get("java", "")
    if not same_path(executable, Path(plan["jdk"]["home"]) / "bin/java.exe"):
        raise AssertionError("build preparation did not freeze the project's selected JDK; integrate the build runtime wiring patch")


def terminal_events(snapshot, review, expected="succeeded", exit_code=0):
    assert_observer(snapshot)
    # Events from an older generation or operation can never complete this run.
    events = [event for event in snapshot.get("events", [])
              if event.get("operationId") == review.get("operationId")]
    if any(any(event.get(key) != review.get(key) for key in IDENTITY) for event in events):
        raise AssertionError("build output changed its operation/workspace/plugin/generation identity")
    terminals = [event for event in events if event.get("type") == "terminal"]
    if not terminals:
        return None
    if (len(terminals) != 1 or events[-1] != terminals[0]
            or terminals[0].get("terminal", {}).get("kind") != expected
            or terminals[0].get("terminal", {}).get("exitCode") != exit_code):
        raise AssertionError("build output did not end in the single expected native terminal")
    return events


class JavaBuildWorkflow:
    def __init__(self, page, driver, plan, target: Path, snapshot, wait, write):
        self.page, self.driver, self.plan, self.target = page, driver, plan, target
        self.snapshot, self.wait, self.write = snapshot, wait, write
        self.system = plan["buildPackage"]["buildSystemId"]
        self.plugin = plan["buildPackage"]["pluginId"]
        self.generation = None

    def calls(self):
        return assert_observer(self.snapshot())

    def offset(self):
        return max((call["sequence"] for call in self.calls()), default=-1)

    def call(self, command, after, seconds=60):
        return self.wait(lambda: matching_call(self.calls(), command, after), command, seconds)

    def open(self):
        self.driver.close_settings(self.page)
        catalogs = self.driver.invoke(self.page, "declarative_plugins_build_catalog")
        entries = [row for row in catalogs if row["pluginId"] == self.plugin and row["buildSystemId"] == self.system]
        if len(entries) != 1:
            raise AssertionError("independent build plugin has no admitted native catalog entry")
        title = entries[0]["buildSystemDisplayName"]
        region = self.page.get_by_role("region", name=title, exact=True)
        if not region.count() or not region.is_visible():
            self.page.get_by_role("button", name=title, exact=True).click(timeout=10_000)
        region.wait_for(state="visible", timeout=15_000)
        return region

    def approve(self, command, title, label, trigger, *, decline=False):
        after = self.offset()
        trigger()
        dialog = self.page.get_by_role("dialog", name=title, exact=True)
        dialog.wait_for(state="visible", timeout=15_000)
        prepared = self.call(command, after)
        review = prepared["value"]
        assert_review(review, self.plan, self.target, self.generation)
        assert_selected_runtime(prepared, self.plan)
        if any(call["command"] in EXECUTION_COMMANDS for call in self.calls() if call["sequence"] > after):
            raise AssertionError("build executed before explicit approval")
        for key in ("pluginId", "buildSystemId", "workspaceRoot", "root", "generation", "operationId"):
            if str(review[key]) not in dialog.inner_text(timeout=5000):
                raise AssertionError("build approval did not display " + key)
        dialog.get_by_role("button", name="Decline" if decline else label, exact=True).click(timeout=10_000)
        dialog.wait_for(state="hidden", timeout=15_000)
        if decline:
            cancelled = self.call("declarative_plugins_build_cancel_operation", after, 30)
            if cancelled["args"].get("operationId") != review["operationId"]:
                raise AssertionError("decline cancelled another model operation")
            if any(call["command"] in EXECUTION_COMMANDS for call in self.calls() if call["sequence"] > after):
                raise AssertionError("declined model executed")
        return review, after

    def choose(self, region, label, value):
        region.get_by_role("combobox", name=label, exact=True).click(timeout=10_000)
        self.page.get_by_role("option", name=value, exact=True).click(timeout=10_000)

    def model_and_task(self):
        region = self.open()
        after = self.offset()
        region.get_by_role("button", name="Reload", exact=True).click(timeout=10_000)
        view = self.call("declarative_plugins_build_refresh", after)["value"]
        instance = model_instance(view, self.plan, self.target)
        self.generation = view["generation"]
        if instance.get("modelSource") in ("command", "provider"):
            instance = self.load_model(region)
        elif instance.get("modelSource") in ("static", "hostIntegration"):
            # The registry owns passive models. There is no execute/model
            # approval API for these sources; task execution still needs it.
            self.write("build-model", {"source": instance["modelSource"], "view": view, "binding": self.binding()})
        else:
            raise AssertionError("detected build instance has no upstream model source")
        if instance.get("modelError") or instance.get("stale") or not instance.get("model", {}).get("projects"):
            raise AssertionError("upstream build model is missing, stale or failed")
        self.run_task(region, instance)

    def load_model(self, region):
        declined, _ = self.approve("declarative_plugins_build_prepare_model", "Review model loading", "Allow and load",
            lambda: region.get_by_role("button", name=re.compile(r"^(Load|Reload) model…$")).click(timeout=10_000), decline=True)
        self.write("build-model-declined", {"review": declined, "binding": self.binding()})
        self.wait(lambda: region.get_by_role("button", name=re.compile(r"^(Load|Reload) model…$")).is_enabled(), "declined model cleanup completed")
        review, after = self.approve("declarative_plugins_build_prepare_model", "Review model loading", "Allow and load",
            lambda: region.get_by_role("button", name=re.compile(r"^(Load|Reload) model…$")).click(timeout=10_000))
        if review["operationId"] == declined["operationId"]:
            raise AssertionError("approved model reused its cancelled review")
        loaded = self.wait(lambda: approved_result(self.calls(), EXECUTION_COMMANDS[0], review, after), "approved upstream build model", 180)
        result = loaded["value"]
        if result.get("operationId") != review["operationId"]:
            raise AssertionError("model completion changed operation")
        instance = model_instance(result["view"], self.plan, self.target, self.generation)
        self.write("build-model", {"review": review, "completion": loaded, "binding": self.binding()})
        return instance

    def binding(self):
        return {"variant": self.plan["variant"], "pluginId": self.plugin, "buildSystemId": self.system,
                "packageSha256": self.plan["buildPackage"]["archive"]["sha256"],
                "javaPackageSha256": self.plan["package"]["archive"]["sha256"],
                "workspaceRoot": str(self.target), "generation": self.generation, "root": ".", "jdk": self.plan["jdk"]}

    def run_task(self, region, instance):
        selected = self.plan["buildTask"]
        manifest, _ = archive_manifest(self.plan["buildPackage"])
        system = next(row for row in manifest["buildSystems"] if row["id"] == self.system)
        task = next(row for row in system["tasks"] if row["id"] == selected["taskId"])
        controls = region.get_by_role("region", name="Tasks and tests", exact=True)
        label = " / ".join([*task.get("category", [task["group"]] if task.get("group") else []), task["displayName"]])
        self.choose(controls, "Action", label)
        self.choose(controls, "Scope", selected["scope"].title())
        if selected["scope"] != "workspace":
            project = next(row for row in instance["model"]["projects"] if row.get("id") == selected.get("projectId"))
            self.choose(controls, "Project", f"{project.get('displayName', project['name'])} ({project['path']})")
        if selected["scope"] == "target":
            target = next(row for row in instance["model"]["targets"] if row.get("id") == selected.get("targetId") and row.get("projectID") == selected["projectId"])
            self.choose(controls, "Target", target["name"] + " [" + ", ".join(target.get("tags", [])) + "]")
        if task.get("fromModel"):
            model_task = next(row for row in instance["model"]["tasks"] if row["id"] == selected["modelTaskId"] and row.get("template") == task["id"])
            self.choose(controls, "Model task", " / ".join([*model_task.get("category", []), model_task.get("displayName", model_task["name"])]))
        review, after = self.approve("declarative_plugins_build_prepare_run", "Review task / test execution", "Allow and execute",
            lambda: controls.get_by_role("button", name="Prepare task / test…", exact=True).click(timeout=10_000))
        prepared = matching_call(self.calls(), "declarative_plugins_build_prepare_run", after)
        selection = prepared["args"]["selection"]
        for key in ("taskId", "projectId", "targetId", "modelTaskId"):
            if selection.get(key) != selected.get(key):
                raise AssertionError("UI selected another upstream build task: " + key)
        executed = self.wait(lambda: approved_result(self.calls(), EXECUTION_COMMANDS[1], review, after), "approved upstream build task", 180)
        if (executed["value"].get("kind") != "succeeded"
                or executed["value"].get("exitCode") != 0):
            raise AssertionError("upstream build task failed/cancelled")
        events = self.wait(lambda: terminal_events(self.snapshot(), review), "ordered native build output", 30)
        if events[-1]["terminal"] != executed["value"]:
            raise AssertionError("build IPC and output stream reported different terminals")
        if not any(event.get("type") == "chunk" and event.get("stream") == "stdout"
                   and event.get("text") for event in events):
            raise AssertionError("actual build task emitted no stdout")
        self.write("build-task", {"review": review, "prepare": prepared, "execute": executed, "events": events, "binding": self.binding()})
