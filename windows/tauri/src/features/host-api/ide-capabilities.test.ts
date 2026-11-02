import { expect, mock, test } from "bun:test";
import { IdeCapabilities } from "./ide-capabilities";
import { createRunStore } from "@/features/run/stores/run.store";
import { createMavenStore } from "@/features/maven/stores/maven.store";
import { EMPTY_GLOBAL_TOOLCHAIN, PRIMARY_SESSION_ID } from "@/features/run/types/run.types";
import type { MavenWorkspaceReloadOutcome } from "@/features/maven/services/reload-maven-workspace";
import { mapCoreConfiguration } from "@/features/run/utils/run-configuration";
import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { WindowsBuildProviderWorkspace, type BuildModel } from "@/features/build/services/build-provider-workspace";
import type { WindowsBuildCatalog } from "@/platform/build-provider-platform";
import { buildCore } from "@/platform/build-core-api";
import { createTranslator } from "@/i18n/locale";

function fixture() {
  const root = "C:/fixture/project";
  const run = createRunStore("api-fixture", { stopRunProcess: async () => {} });
  const maven = createMavenStore("api-fixture");
  run.setState({ root, status: "ready" });
  maven.setState({ root });
  const dependencies = {
    outputPage: async (snapshot: unknown) => snapshot,
    validate: mock(async (name: string) => ({
      ok: true,
      mutation: name.endsWith("_configure") || name.endsWith("_reload"),
    })),
    hasWorkspace: () => true,
    workspaceName: () => "fixture",
    workspaceRoot: () => root,
    mavenStore: () => maven,
    runStore: () => run,
    buildWorkspace: (_id: string, _root: string): BuildWorkspaceController | undefined => undefined,
    buildCore,
    loadProjectEnvironment: mock(async () => ({
      toolchain: { ...EMPTY_GLOBAL_TOOLCHAIN, javaHomePath: "C:/fixture/jdk-21" },
      discovered: { java: [], maven: [], runtimes: [] },
      discoveryError: null,
    })),
    saveProjectEnvironmentSettings: mock(
      async (
        ..._args: Parameters<
          typeof import("@/features/settings/services/project-environment").saveProjectEnvironmentSettings
        >
      ) => ({ runRefresh: Promise.resolve(null) }),
    ),
    resolveRunToolchains: mock(async () => ({
      java: { status: "notFound" as const, message: null },
      maven: { status: "notFound" as const, message: null },
      mavenJava: { status: "notFound" as const, message: null },
    })),
    mavenLaunchContextForWorkspace: mock(async () => null),
    reloadMavenWorkspaceProjects: mock(
      async (): Promise<MavenWorkspaceReloadOutcome> => "completed",
    ),
  };
  const api = new IdeCapabilities(
    "api-fixture",
    root,
    { configure: true, execute: true },
    dependencies,
  );
  return { api, run, maven, dependencies };
}

for (const execution of ["application", "service", "task"] as const) {
  test(`${execution} respects its own output slot when primary is busy`, async () => {
    const { api, run } = fixture();
    const configuration = mapCoreConfiguration({ id: "selected", name: "Selected", provider: "shell", execution });
    const start = mock(async () => ({ sessionId: "selected", executionId: "new" }));
    run.setState({
      configurations: [configuration],
      primaryExecutionId: "existing", primaryConfigurationId: "other-task", primaryRunning: true,
      actions: { ...run.getState().actions, runConfigurationInstance: start },
    });
    const result = await api.call("lithe_run_start", { configurationID: configuration.id });
    if (execution === "task") {
      expect(result).toMatchObject({ error: { code: "BUSY" } });
      expect(start).not.toHaveBeenCalled();
    } else {
      expect(result).toMatchObject({ operationID: "run:new" });
      expect(start).toHaveBeenCalledTimes(1);
      run.setState({ sessions: [{ id: "selected", configurationId: "selected", executionId: "pending",
        title: "Selected", output: "", isRunning: false, isPreparing: true, exitCode: null }] });
      expect(await api.call("lithe_run_start", { configurationID: configuration.id }))
        .toMatchObject({ error: { code: "BUSY" } });
      expect(start).toHaveBeenCalledTimes(1);
    }
    expect(run.getState().primaryExecutionId).toBe("existing");
    expect(run.getState().primaryRunning).toBe(true);
  });
}

test("API output follows an execution identity, and an old stop cannot target its replacement", async () => {
  const { api, run } = fixture();
  const stop = mock(async () => {});
  run.setState({
    sessions: [
      {
        id: "slot",
        configurationId: "service",
        executionId: "first",
        title: "service",
        output: "first output",
        isRunning: true,
        exitCode: null,
      },
    ],
    actions: { ...run.getState().actions, stop },
  });
  expect(await api.call("lithe_operation_output", { operationID: "run:first" })).toMatchObject({
    output: "first output",
  });
  run.setState({
    sessions: [{ ...run.getState().sessions[0], executionId: "second", output: "second output" }],
  });
  expect(await api.call("lithe_operation_stop", { operationID: "run:first" })).toMatchObject({
    error: { code: "OPERATION_EXPIRED" },
  });
  expect(stop).not.toHaveBeenCalled();
  await api.call("lithe_operation_stop", { operationID: "run:second" });
  expect(stop).toHaveBeenCalledWith("slot", "second");
});

test("revoking access while environment discovery resolves prevents configuration writes", async () => {
  const { api, dependencies } = fixture();
  const original = dependencies.loadProjectEnvironment;
  dependencies.loadProjectEnvironment = mock(async () => {
    const result = await original();
    api.revoke();
    return result;
  });
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "OPERATION_FAILED" },
  });
  expect(dependencies.saveProjectEnvironmentSettings).not.toHaveBeenCalled();
});

test("application output in the primary panel uses the same execution identity protection", async () => {
  const { api, run } = fixture();
  const stop = mock(async () => {});
  run.setState({
    primaryExecutionId: "app-first",
    primaryConfigurationId: "application",
    primaryOutput: "application output",
    primaryExitCode: 1,
    actions: { ...run.getState().actions, stop },
  });
  expect(await api.call("lithe_operation_output", { operationID: "run:app-first" })).toMatchObject({
    output: "application output",
    state: "failed",
    exitCode: 1,
  });
  run.setState({ primaryExecutionId: "app-second" });
  expect(await api.call("lithe_operation_stop", { operationID: "run:app-first" })).toMatchObject({
    error: { code: "OPERATION_EXPIRED" },
  });
  expect(stop).not.toHaveBeenCalled();
  await api.call("lithe_operation_stop", { operationID: "run:app-second" });
  expect(stop).toHaveBeenCalledWith(PRIMARY_SESSION_ID, "app-second");
});

test("environment patch preserves omitted defaults and rejects Maven-only paths without Maven", async () => {
  const { api, dependencies } = fixture();
  await api.call("lithe_environment_configure", { mavenJavaHomePath: "C:/fixture/build-jdk" });
  expect(dependencies.saveProjectEnvironmentSettings.mock.calls[0]?.[1]).toMatchObject({
    javaHomePath: "C:/fixture/jdk-21",
    mavenJavaHomePath: "C:/fixture/build-jdk",
  });
  expect(
    await api.call("lithe_environment_configure", { settingsPath: "C:/fixture/settings.xml" }),
  ).toMatchObject({ error: { code: "NOT_READY" } });
  expect(dependencies.saveProjectEnvironmentSettings).toHaveBeenCalledTimes(1);
});

test("shared authorization failures stop before application actions", async () => {
  const { api, dependencies } = fixture();
  dependencies.validate = mock(async () => ({
    ok: false,
    mutation: false,
    error: { code: "PERMISSION_DENIED" },
  }));
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "PERMISSION_DENIED" },
  });
  expect(dependencies.loadProjectEnvironment).not.toHaveBeenCalled();
});

test("a failed Maven reload is reported as a tool error", async () => {
  const { api, dependencies } = fixture();
  dependencies.reloadMavenWorkspaceProjects = mock(async () => "failed" as const);
  expect(await api.call("lithe_maven_reload", {})).toMatchObject({
    error: { code: "OPERATION_FAILED" },
  });
});

test("overlapping mutations are busy while inspections can continue, and failed saves release the slot", async () => {
  const { api, dependencies } = fixture();
  const original = dependencies.loadProjectEnvironment;
  dependencies.loadProjectEnvironment = mock(async () => {
    expect(await api.call("lithe_maven_reload", {})).toMatchObject({ error: { code: "BUSY" } });
    expect(await api.call("lithe_project_inspect", {})).toMatchObject({ name: "fixture" });
    return original();
  });
  dependencies.saveProjectEnvironmentSettings = mock(async () => {
    throw new Error("Fixture save failed");
  });
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "OPERATION_FAILED", message: "Fixture save failed" },
  });
  expect(dependencies.reloadMavenWorkspaceProjects).not.toHaveBeenCalled();
  expect(await api.call("lithe_maven_reload", {})).toMatchObject({ outcome: "completed" });
});

test("Maven profile configuration adds only undeclared profiles as custom entries", async () => {
  const { api, maven } = fixture();
  const actions = maven.getState().actions;
  const addCustomProfile = mock((_profile: string) => true);
  const setSelectedProfiles = mock((_profiles: string[]) => {});
  const saveLocalConfiguration = mock(async () => {});
  maven.setState({
    project: {
      relativePath: ".",
      artifactId: "fixture",
      packaging: "pom",
      sourceRoots: [],
      modules: [],
      profiles: [{ id: "dev", isActiveByDefault: false }],
      hasWrapper: false,
    },
    actions: { ...actions, addCustomProfile, setSelectedProfiles, saveLocalConfiguration },
  });
  expect(await api.call("lithe_maven_configure", { profiles: ["dev", "ci"] })).toMatchObject({
    saved: true,
  });
  expect(addCustomProfile.mock.calls).toEqual([["ci"]]);
  expect(setSelectedProfiles).toHaveBeenCalledWith(["dev", "ci"]);
  expect(saveLocalConfiguration).toHaveBeenCalledTimes(1);
});

test("Build entry points stay unavailable when the workspace has no product owner", async () => {
  const { api, dependencies } = fixture();
  for (const [name, arguments_] of [
    ["lithe_build_inspect", {}],
    ["lithe_build_reload", { instanceID: "fixture" }],
    ["lithe_build_configure", { instanceID: "fixture", optionID: "release", value: true }],
    ["lithe_build_execute", { instanceID: "fixture", taskID: "build" }],
  ] as const) {
    expect(await api.call(name, arguments_)).toMatchObject({ error: { code: "NOT_AVAILABLE" } });
  }
  expect(dependencies.mavenLaunchContextForWorkspace).not.toHaveBeenCalled();
  expect(dependencies.reloadMavenWorkspaceProjects).not.toHaveBeenCalled();
});


test("MCP deadline is rechecked after native validation before accepting a workflow", async () => {
  const { api, dependencies } = fixture();
  let allowed = true;
  dependencies.validate.mockImplementationOnce(async () => {
    allowed = false;
    return { ok: true, mutation: true };
  });
  const result = await api.call("lithe_environment_configure", { javaHomePath: "fixture" }, () => allowed);
  expect((result as { error: { code: string } }).error.code).toBe("TIMEOUT");
  expect(dependencies.loadProjectEnvironment).not.toHaveBeenCalled();
  expect(dependencies.saveProjectEnvironmentSettings).not.toHaveBeenCalled();
}, 1000);

function buildFixture() {
  const f = fixture(), root = "C:/fixture/project";
  const entry = { id: "example:.", pluginID: "dev.example.build", buildSystemID: "example", root: ".",
    displayName: "Example", modelSource: "provider", optionFingerprint: "current", droppedOptions: [], options: { offline: true } };
  const manifest = { id: entry.pluginID, buildSystems: [{ id: entry.buildSystemID, tasks: [
    { id: "compile", displayName: "Compile", source: "provider", scopes: ["workspace", "project", "target"] },
    { id: "model-goal", displayName: "Model task", source: "provider", fromModel: true, scopes: ["project"] },
  ] }] };
  const model: BuildModel = { projects: [{ id: "first", name: "First", path: "first", properties: { secret: "not API data" } },
    { id: "second", name: "Second", path: "second", properties: {} }],
    targets: [{ id: "application", projectID: "first", name: "Same name", path: "first", tags: [], properties: {} }],
    tasks: [{ id: "model-task", projectID: "second", name: "upstream:compile", path: "second", template: "model-goal", execution: "task", properties: {} }],
    contentRoots: [], optionValues: {} };
  const deferred = <T,>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; };
  const taskEntered = deferred<void>(), taskResult = deferred<unknown>(), detection = deferred<void>(), detectionEntered = deferred<void>(),
    inspecting = deferred<void>(), inspectResult = deferred<void>();
  const calls: Array<{ command: string; request: Record<string, unknown> }> = [];
  let holdDetection = false, holdInspection = false;
  const core = (async (command: string, _manifest: unknown, _system: string, request: Record<string, unknown>) => {
    calls.push({ command, request: structuredClone(request) });
    if (command === "build.resolveOptions") {
      if (holdInspection) { inspecting.resolve(); await inspectResult.promise; }
      return { options: { options: [{ id: "offline", kind: "boolean", value: true, source: "user" }] } };
    }
    if (command === "build.syncFingerprint") return { sync: { fingerprint: "current", watch: ["build.marker"] } };
    if (command === "build.decodeModel") return { model };
    if (command.endsWith("Plan")) return { plan: { provider: { method: command, params: request } } };
    if (command === "build.decodeDiagnostics") return { diagnostics: [] };
    throw new Error(`Unexpected Core call: ${command}`);
  }) as typeof buildCore;
  const sent: string[] = [];
  const providers = { send: async <T,>(_target: unknown, request: { method: string; onProgress?: (value: unknown) => void }) => {
    sent.push(request.method);
    if (request.method === "build.taskPlan") {
      request.onProgress?.({ output: "current build output\n" }); taskEntered.resolve(); return await taskResult.promise as T;
    }
    return {} as T;
  }, stop: mock(async () => {}) };
  const domain = new WindowsBuildProviderWorkspace(root, { core, providers, guard: () => () => {}, translate: createTranslator("en-US"),
    tools: async () => ({ manifest, identity: "current", pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state",
      tool: { executable: "C:/builder/build.cmd" }, environment: {}, executesProjectCode: false }) });
  const catalog = (): WindowsBuildCatalog => ({ detection: { instances: [entry], rejected: [], shadowed: [] },
    plugins: [{ manifest }], document: { version: 1, systems: {} } });
  const controller = new BuildWorkspaceController(root, { domain, guard: () => () => {},
    detect: mock(async () => { detectionEntered.resolve(); if (holdDetection) await detection.promise; return catalog(); }) });
  f.dependencies.buildWorkspace = (_id: string, _root: string) => controller;
  f.dependencies.buildCore = core;
  const api = new IdeCapabilities("api-fixture", root, { configure: true, execute: true }, f.dependencies);
  const unsubscriptions: Array<() => void> = [];
  const until = (ready: () => boolean) => {
    if (ready()) return Promise.resolve();
    const done = deferred<void>();
    const unsubscribe = domain.subscribe(() => { if (ready()) done.resolve(); });
    unsubscriptions.push(() => { unsubscribe(); done.resolve(); });
    return done.promise;
  };
  return { ...f, api, controller, domain, entry, model, calls, sent, taskEntered, taskResult, detectionEntered, inspecting, inspectResult,
    until, holdInspection: () => { holdInspection = true; }, holdDetection: () => { holdDetection = true; },
    async dispose() { detection.resolve(); inspectResult.resolve(); taskResult.resolve({ exitCode: 0, output: "finished" });
      for (const unsubscribe of unsubscriptions) unsubscribe(); await controller.dispose(); } };
}

test("Agent Build inspection reads admitted declarations and shared options without starting tooling", async () => {
  const f = buildFixture();
  try {
    expect(await f.api.call("lithe_build_inspect", {})).toMatchObject({ instances: [{
      instanceID: f.entry.id, modelState: "unavailable", tasks: [{ id: "compile" }, { id: "model-goal" }],
      options: [{ id: "offline", value: true }], projects: [],
    }] });
    expect(f.sent).toHaveLength(0);
    expect(f.calls.map(call => call.command)).toEqual(["build.resolveOptions"]);
    expect(f.dependencies.mavenLaunchContextForWorkspace).not.toHaveBeenCalled();
    expect(await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile" }))
      .toMatchObject({ error: { code: "NOT_READY" } });
    f.dependencies.validate.mockImplementationOnce(async () => ({ ok: false, mutation: false }));
    expect(await f.api.call("lithe_build_reload", { instanceID: f.entry.id })).toEqual({ ok: false, mutation: false });
    expect(f.sent).toHaveLength(0);
  } finally { await f.dispose(); }
}, 5000);

test("Agent reload and exact target execution share product state, argv and retained output", async () => {
  const f = buildFixture();
  try {
    expect(await f.api.call("lithe_build_reload", { instanceID: f.entry.id })).toMatchObject({ reloadRequested: true });
    await f.until(() => f.domain.hasCurrentModel(f.entry));
    const inspected = await f.api.call("lithe_build_inspect", {});
    expect(inspected).toMatchObject({ instances: [{ modelState: "ready", projects: [{ id: "first" }, { id: "second" }] }] });
    expect(JSON.stringify(inspected)).not.toContain("not API data");
    const args = ["", "two words", "-D值=已选"];
    const result = await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile",
      projectID: "first", targetID: "application", userArguments: args }) as { operationID: string };
    await f.taskEntered.promise;
    expect(f.controller.snapshot().operationID).toBe(result.operationID.slice(6));
    expect(f.calls.find(call => call.command === "build.taskPlan")?.request)
      .toMatchObject({ project: f.model.projects[0], target: f.model.targets[0], userArguments: args });
    expect(await f.api.call("lithe_operation_output", { operationID: result.operationID }))
      .toMatchObject({ output: "current build output\n", state: "running" });
    expect(JSON.stringify(await f.api.call("lithe_operations_list", {}))).not.toContain("current build output");
    expect(await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile" })).toMatchObject({ error: { code: "BUSY" } });
    f.taskResult.resolve({ exitCode: 0, output: "finished" });
    await f.until(() => f.domain.operationSummary(result.operationID.slice(6))?.phase === "succeeded");
    expect(await f.api.call("lithe_operation_output", { operationID: result.operationID })).toMatchObject({ output: "finished", exitCode: 0, state: "completed" });
    expect(await f.api.call("lithe_run_restart", { operationID: result.operationID })).toMatchObject({ error: { code: "INVALID_ARGUMENTS" } });
    const second = await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile" }) as { operationID: string };
    await f.api.call("lithe_operation_stop", { operationID: result.operationID });
    await f.until(() => f.domain.operationSummary(second.operationID.slice(6))?.phase === "succeeded");
    expect(f.controller.snapshot().operationID).toBe(second.operationID.slice(6));
    expect(await f.api.call("lithe_operation_stop", { operationID: "build:expired" })).toMatchObject({ error: { code: "OPERATION_EXPIRED" } });
  } finally { await f.dispose(); }
}, 5000);

test("Agent refuses stale, cross-project and mismatched model task selectors before execution", async () => {
  const f = buildFixture();
  try {
    await f.controller.ensureDetected(); await f.domain.loadModel(f.entry).completion;
    for (const selection of [
      { taskID: "unknown" }, { taskID: "compile", projectID: "second", targetID: "application" },
      { taskID: "compile", projectID: "first", modelTaskID: "model-task" },
      { taskID: "model-goal", projectID: "first", modelTaskID: "model-task" },
      { taskID: "model-goal", projectID: "second", modelTaskID: "model-task", targetID: "application" },
    ]) expect(await f.api.call("lithe_build_execute", { instanceID: f.entry.id, ...selection })).toMatchObject({ error: { code: "NOT_FOUND" } });
    expect(f.calls.filter(call => call.command === "build.taskPlan")).toHaveLength(0);
    const result = await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "model-goal",
      projectID: "second", modelTaskID: "model-task", userArguments: ["opaque"] }) as { operationID: string };
    await f.taskEntered.promise;
    expect(f.calls.find(call => call.command === "build.taskPlan")?.request).toMatchObject({ project: f.model.projects[1], modelTask: f.model.tasks[0], userArguments: ["opaque"] });
    expect(await f.api.call("lithe_operation_stop", { operationID: result.operationID })).toMatchObject({ stopRequested: true });
    await f.until(() => f.domain.operationSummary(result.operationID.slice(6))?.phase === "cancelled");
    f.domain.invalidate(f.entry);
    expect(await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile" })).toMatchObject({ error: { code: "NOT_READY" } });
  } finally { await f.dispose(); }
}, 5000);

test("revocation during passive detection cannot launch a late Agent Build request", async () => {
  const f = buildFixture();
  try {
    f.holdDetection();
    const call = f.api.call("lithe_build_reload", { instanceID: f.entry.id });
    await f.detectionEntered.promise;
    f.api.revoke(); await f.dispose();
    expect(await call).toMatchObject({ error: { code: "OPERATION_FAILED" } });
    expect(f.sent).toHaveLength(0);
  } finally { await f.dispose(); }
}, 5000);

test("Agent inspection cannot publish a model invalidated across its Core option read", async () => {
  const f = buildFixture();
  try {
    await f.controller.ensureDetected(); await f.domain.loadModel(f.entry).completion;
    f.holdInspection(); const reading = f.api.call("lithe_build_inspect", {}); await f.inspecting.promise;
    f.domain.invalidate(f.entry); f.inspectResult.resolve();
    expect(await reading).toMatchObject({ error: { code: "NOT_READY" } });
  } finally { await f.dispose(); }
}, 5000);

test("an accepted Agent build remains product-owned after grant revocation and close waits for cleanup", async () => {
  const f = buildFixture();
  try {
    await f.controller.ensureDetected(); await f.domain.loadModel(f.entry).completion;
    const result = await f.api.call("lithe_build_execute", { instanceID: f.entry.id, taskID: "compile" }) as { operationID: string };
    await f.taskEntered.promise;
    f.api.revoke();
    expect(f.domain.operationSummary(result.operationID.slice(6))?.phase).toBe("running");
    expect(await f.api.call("lithe_operation_stop", { operationID: result.operationID })).toMatchObject({ error: { code: "WORKSPACE_CLOSED" } });
    let closed = false;
    const closing = f.controller.dispose().then(() => { closed = true; });
    await f.until(() => f.domain.operationSummary(result.operationID.slice(6))?.phase === "cancelled");
    expect(closed).toBe(false);
    f.taskResult.resolve({ exitCode: 0, output: "late completed" });
    await closing;
    expect(closed).toBe(true);
    expect(f.domain.operationSummary(result.operationID.slice(6))?.phase).toBe("cancelled");
  } finally { await f.dispose(); }
}, 5000);
