import { describe, expect, test } from "bun:test";
import { WindowsBuildProviderWorkspace, type BuildInstance, type BuildModel, type BuildToolContext, type BuildNativeConfiguration } from "./build-provider-workspace";
import type { buildCore } from "@/platform/build-core-api";
import { createTranslator } from "@/i18n/locale";

const instance: BuildInstance = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", options: { profiles: ["dev"] } };
const model: BuildModel = { projects: [{ id: "service", name: "Service", path: "service", properties: { upstream: "owned" } }],
  targets: [], tasks: [{ id: "compiler", projectID: "service", name: "upstream:compile", path: "service", template: "plugin-goal",
    execution: "task", properties: { goal: "upstream:compile" } }], contentRoots: [], optionValues: {} };
const context: BuildToolContext = { manifest: { id: instance.pluginID }, pluginDirectory: "C:/plugin",
  workspaceStateDirectory: "C:/state", tool: { executable: "C:/maven/mvn.cmd" },
  environment: { JAVA_HOME: "C:/selected-jdk", PATH: "C:/selected-jdk/bin" }, executesProjectCode: false };
const configuration: BuildNativeConfiguration = { format: "litheBuildConfiguration", version: 1, sources: [{ id: "user", scope: "user",
  uri: "file:///C:/fixture/settings.xml", revision: "sha256:" + "a".repeat(64), writable: true, rootElement: { name: "settings", namespace: "" },
  fields: [{ id: "localRepository", kind: "directory", value: null, effectiveValue: "inherited repository", effectiveSource: "default", path: ["localRepository"] }] }] };
const edits = { sourceID: "user", revision: configuration.sources[0]!.revision, values: { localRepository: "saved repository" } };

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}

function fixture() {
  type Ports = NonNullable<ConstructorParameters<typeof WindowsBuildProviderWorkspace>[1]>;
  type Request = Parameters<Ports["providers"]["send"]>[1];
  const coreCalls: Array<{ command: string; request: Record<string, unknown> }> = [];
  const sent: Request[] = [], stopped: string[] = [], fileCalls: string[] = [];
  let tools = structuredClone(context), revision = 0;
  let toolGate: Promise<BuildToolContext> | undefined, coreGate: { command: string; promise: Promise<unknown> } | undefined;
  let providerGate: Promise<unknown> | undefined, stopFailure = false;
  let prepareGate: Promise<boolean> | undefined, commitGate: Promise<void> | undefined, commitFailure = false;
  let nativeConfiguration = structuredClone(configuration);
  const entered = { tool: deferred<void>(), provider: deferred<void>(), decode: deferred<void>(), prepare: deferred<void>(), commit: deferred<void>() };
  const core = (async (command: string, _manifest: unknown, _system: string, request: Record<string, unknown>) => {
    coreCalls.push({ command, request: structuredClone(request) });
    if (coreGate?.command === command) { entered.decode.resolve(); return await coreGate.promise; }
    if (command.endsWith("Plan")) return { plan: { provider: { method: command,
      params: { ...request, environment: { OPTION: "selected", PATH: "C:/option-path" } } } } };
    if (command === "build.decodeModel") return { model: structuredClone(model) };
    if (command === "build.decodeDependencies") return { dependencies: { project: "service", dependencies: [{ name: "library" }], truncated: false } };
    if (command === "build.decodeDiagnostics") return { diagnostics: [{ message: "compile error", line: 3 }] };
    if (command === "build.decodeTestResults") return { results: { failed: 1, suites: [{ name: "FailedTest" }] } };
    if (command === "build.decodeTestDiscovery") return { discovery: { tests: [{ id: "opaque-selector", suite: "A", case: "method" }] } };
    if (command === "build.decodeConfiguration") return { configuration: structuredClone(nativeConfiguration) };
    throw new Error(`Unexpected Core command ${command}`);
  }) as typeof buildCore;
  const workspace = new WindowsBuildProviderWorkspace("C:/work", {
    core, translate: createTranslator("en-US"),
    tools: async () => { entered.tool.resolve(); return await toolGate ?? tools; },
    guard: () => { const generation = revision; return () => { if (revision !== generation) throw new Error("plugin replaced"); }; },
    providers: {
      send: async <T>(_target: unknown, request: Request) => {
        sent.push(request); entered.provider.resolve();
        if (providerGate) return await providerGate as T;
        request.onProgress?.({ output: "progress\n" });
        return { exitCode: 1, output: "final output\n", testResults: { version: 1 } } as T;
      },
      stop: async target => { stopped.push(target.pluginId); if (stopFailure) throw new Error("process retained"); },
    },
    configurationFiles: {
      prepare: async () => { fileCalls.push("prepare"); entered.prepare.resolve(); return await prepareGate ?? true; },
      commit: async () => {
        fileCalls.push("commit");
        entered.commit.resolve(); if (commitGate) await commitGate;
        if (commitFailure) throw Object.assign(new Error("build.configuration.conflict"), { code: "build.configuration.conflict" });
        nativeConfiguration.sources[0]!.fields[0]!.value = "upstream readback";
        nativeConfiguration.sources[0]!.revision = "sha256:" + "b".repeat(64);
      },
      cancel: async () => { fileCalls.push("cancel"); },
    },
  });
  return { workspace, coreCalls, sent, stopped, entered, fileCalls,
    tools: (value: BuildToolContext) => { tools = value; }, holdTools: (value: Promise<BuildToolContext> | undefined) => { toolGate = value; },
    holdProvider: (value: Promise<unknown> | undefined) => { providerGate = value; },
    holdCore: (command: string, promise: Promise<unknown>) => { coreGate = { command, promise }; },
    revoke: () => { revision++; }, failStop: () => { stopFailure = true; },
    holdPrepare: (gate: Promise<boolean>) => { prepareGate = gate; }, holdCommit: (gate: Promise<void>) => { commitGate = gate; },
    failCommit: () => { commitFailure = true; } };
}

describe("Windows Build Provider workspace operations", () => {
  test("native configuration reads before a model exists and sends an exact decode request", async () => {
    const f = fixture();
    try {
      const result = await f.workspace.readConfiguration(instance).completion;
      expect(result).toMatchObject({ format: "litheBuildConfiguration", sources: [{ id: "user" }] });
      expect(f.workspace.model(instance)).toBeUndefined();
      expect(f.coreCalls.map(call => call.command)).toEqual(["build.configurationPlan", "build.decodeConfiguration"]);
      expect(Object.keys(f.coreCalls[1]!.request)).toEqual(["result"]);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("configuration save commits only the current read receipt and returns upstream readback", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      const result = await f.workspace.saveConfiguration(instance, snapshot, edits).completion;
      expect(f.fileCalls).toEqual(["prepare", "commit", "cancel"]);
      expect(result.sources[0]!.fields[0]!.value).toBe("upstream readback");
      expect(f.workspace.model(instance)).toBeUndefined();
      expect(f.coreCalls.filter(call => call.command === "build.configurationPlan")).toHaveLength(2);
      await expect(f.workspace.saveConfiguration(instance, snapshot, edits).completion).rejects.toMatchObject({ code: "cancelled" });
      expect(f.fileCalls).toHaveLength(3);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("a changed tool rejects configuration save before native file preparation", async () => {
    const f = fixture();
    try {
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      f.tools({ ...context, tool: { executable: "C:/new-maven/mvn.cmd" } });
      await expect(f.workspace.saveConfiguration(instance, snapshot, edits).completion).rejects.toMatchObject({ code: "cancelled" });
      expect(f.fileCalls).toHaveLength(0);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("a write already committing invalidates sibling models after its caller cancels", async () => {
    const f = fixture(), gate = deferred<void>(), sibling = { ...instance, root: "other" };
    let settled: Promise<unknown> | undefined;
    try {
      await f.workspace.loadModel(instance).completion;
      await f.workspace.loadModel(sibling).completion;
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      f.holdCommit(gate.promise);
      const operation = f.workspace.saveConfiguration(instance, snapshot, edits);
      settled = operation.completion.catch(error => error.code);
      await f.entered.commit.promise; f.workspace.cancel(operation.operationID);
      expect(await settled).toBe("cancelled");
      const previousRequests = f.sent.length;
      gate.resolve();
      await expect(f.workspace.executeTask(sibling, "compile").completion).rejects.toThrow();
      expect(f.workspace.model(instance)).toBeUndefined(); expect(f.workspace.model(sibling)).toBeUndefined();
      expect(f.sent).toHaveLength(previousRequests);
      expect(f.fileCalls).toEqual(["prepare", "commit", "cancel"]);
    } finally { gate.resolve(); await settled; await f.workspace.dispose(); }
  }, 5000);

  test("cancelling native preparation retains its late token for cleanup and never commits", async () => {
    const f = fixture(), gate = deferred<boolean>();
    let settled: Promise<unknown> | undefined;
    try {
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      f.holdPrepare(gate.promise);
      const operation = f.workspace.saveConfiguration(instance, snapshot, edits);
      settled = operation.completion.catch(error => error.code);
      await f.entered.prepare.promise;
      f.workspace.cancel(operation.operationID);
      expect(await settled).toBe("cancelled");
      gate.resolve(true); await f.workspace.dispose();
      expect(f.fileCalls).toEqual(["prepare", "cancel"]);
    } finally { gate.resolve(true); await settled; await f.workspace.dispose(); }
  }, 5000);

  test("configuration ABA during native preparation revokes the write and releases its token", async () => {
    const f = fixture(), gate = deferred<boolean>();
    let settled: Promise<unknown> | undefined;
    try {
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      f.holdPrepare(gate.promise);
      settled = f.workspace.saveConfiguration(instance, snapshot, edits).completion.catch(error => error.code);
      await f.entered.prepare.promise;
      f.workspace.invalidate({ ...instance, options: { profiles: ["other"] } });
      expect(await settled).toBe("cancelled");
      gate.resolve(true); await f.workspace.dispose();
      expect(f.fileCalls).toEqual(["prepare", "cancel"]);
    } finally { gate.resolve(true); await settled; await f.workspace.dispose(); }
  }, 5000);

  test("an unchanged draft never commits or rereads while a disk conflict preserves the failed operation", async () => {
    const f = fixture();
    try {
      const snapshot = await f.workspace.readConfiguration(instance).completion;
      f.holdPrepare(Promise.resolve(false));
      expect(await f.workspace.saveConfiguration(instance, snapshot, edits).completion).toEqual(snapshot);
      expect(f.fileCalls).toEqual(["prepare", "cancel"]);
      f.holdPrepare(Promise.resolve(true)); f.failCommit();
      const failed = f.workspace.saveConfiguration(instance, snapshot, edits);
      await expect(failed.completion).rejects.toMatchObject({ code: "build.configuration.conflict", message: expect.stringContaining("draft has been kept") });
      expect(f.fileCalls).toEqual(["prepare", "cancel", "prepare", "commit", "cancel"]);
      expect(f.coreCalls.filter(call => call.command === "build.configurationPlan")).toHaveLength(1);
      expect(f.workspace.operations().find(operation => operation.id === failed.operationID)?.phase).toBe("failed");
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("automatic configuration reads stop before a project tool is sent to the Provider", async () => {
    const f = fixture(); f.tools({ ...context, executesProjectCode: true });
    try {
      await expect(f.workspace.readConfiguration(instance).completion).rejects.toMatchObject({ code: "build.configuration.projectToolRequiresAction" });
      expect(f.coreCalls).toHaveLength(0); expect(f.sent).toHaveLength(0);
      await f.workspace.readConfiguration(instance, true).completion;
      expect(f.sent).toHaveLength(1);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("configuration decoding cancelled by a workspace revision cannot return a stale snapshot", async () => {
    const f = fixture(), gate = deferred<unknown>(); f.holdCore("build.decodeConfiguration", gate.promise);
    const operation = f.workspace.readConfiguration(instance), completed = operation.completion.catch(error => error.code);
    try {
      await f.entered.decode.promise;
      f.workspace.invalidate(instance);
      expect(await completed).toBe("cancelled");
      gate.resolve({ configuration: { format: "litheBuildConfiguration", version: 1, sources: [] } });
      expect(f.workspace.operations()[0]?.phase).toBe("cancelled");
    } finally { gate.resolve({}); await completed; await f.workspace.dispose(); }
  }, 5000);

  test("model, dependencies and a failed task use shared plans and retain diagnostics and test reports", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      const tree = await f.workspace.dependencies(instance, "service").completion;
      const task = f.workspace.executeTask(instance, "test", "service", ["-Dexample=值"]);
      const result = await task.completion;
      expect(tree.dependencies.dependencies).toEqual([{ name: "library" }]);
      expect(result.diagnostics).toEqual([{ message: "compile error", line: 3 }]);
      expect(result.results).toMatchObject({ failed: 1 });
      expect(f.workspace.operations().find(record => record.id === task.operationID)).toMatchObject({ phase: "failed", exitCode: 1, output: "final output\n" });
      expect(f.coreCalls.map(call => call.command)).toEqual(["build.modelPlan", "build.decodeModel", "build.dependencyPlan", "build.decodeDependencies",
        "build.taskPlan", "build.decodeDiagnostics", "build.decodeTestResults"]);
      expect(f.coreCalls[0]!.request).toMatchObject({ refresh: true, tool: { environment: context.environment } });
      expect(f.coreCalls.find(call => call.command === "build.taskPlan")!.request).toMatchObject({ project: model.projects[0], userArguments: ["-Dexample=值"] });
      for (const request of f.sent) expect(request.params).toMatchObject({ tool: context.tool,
        environment: { JAVA_HOME: context.environment.JAVA_HOME, OPTION: "selected", PATH: "C:/option-path" } });
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("a task cannot run without a complete current model or select an unknown project", async () => {
    const f = fixture();
    try {
      await expect(f.workspace.executeTask(instance, "compile").completion).rejects.toThrow("complete current Build model");
      expect(f.sent).toHaveLength(0);
      await f.workspace.loadModel(instance).completion;
      await expect(f.workspace.dependencies(instance, "unowned").completion).rejects.toThrow("does not contain");
      const changed = { ...instance, options: { profiles: ["other"] } };
      expect(f.workspace.model(changed)).toBeUndefined();
      await expect(f.workspace.executeTask(changed, "compile").completion).rejects.toThrow("complete current Build model");
      expect(f.sent).toHaveLength(1);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("model tasks and exact Java test identifiers stay typed and use the current project", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      await f.workspace.executeModelTask(instance, "compiler").completion;
      expect(f.coreCalls.find(call => call.command === "build.taskPlan")!.request).toMatchObject({
        task: "plugin-goal", project: model.projects[0], modelTask: model.tasks[0] });
      const selectors = ["demo.Test#method()"];
      const operation = f.workspace.executeTests(instance, { projectID: "service", selectorKind: "java.test.fullName", selectors });
      selectors[0] = "must not replace the snapshot";
      await operation.completion;
      expect(f.coreCalls.find(call => call.command === "build.testPlan")!.request).toMatchObject({
        project: model.projects[0], projects: ["service"], selectorKind: "java.test.fullName", selectors: ["demo.Test#method()"] });
      expect(await f.workspace.discoverTests(instance).completion).toMatchObject({ discovery: { tests: [{ id: "opaque-selector" }] } });
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("a test operation rejects a missing inline report while retaining its native output", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      f.holdProvider(Promise.resolve({ exitCode: 0, output: "tests finished without a report" }));
      const operation = f.workspace.executeTests(instance);
      await expect(operation.completion).rejects.toThrow("Invalid Build execution result");
      expect(f.workspace.operations().find(record => record.id === operation.operationID)).toMatchObject({
        phase: "failed", exitCode: 0, output: "tests finished without a report" });
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("a changed JDK or accepted package requires a model reload before execution", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      f.tools({ ...context, environment: { ...context.environment, JAVA_HOME: "C:/new-jdk" } });
      const task = f.workspace.executeTask(instance, "compile");
      await expect(task.completion).rejects.toMatchObject({ code: "cancelled" });
      expect(f.sent).toHaveLength(1);
      expect(f.workspace.model(instance)).toBeUndefined();
      expect(f.workspace.operations().find(record => record.id === task.operationID)?.phase).toBe("cancelled");
      await f.workspace.loadModel(instance).completion;
      await f.workspace.executeTask(instance, "compile").completion;
      expect(f.sent).toHaveLength(3);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("cancellation during native tool resolution returns immediately and retains the late reply for disposal", async () => {
    const f = fixture(), gate = deferred<BuildToolContext>(); f.holdTools(gate.promise);
    const operation = f.workspace.loadModel(instance), completed = operation.completion.catch(error => error.code);
    try {
      await f.entered.tool.promise;
      expect(f.workspace.cancel(operation.operationID)).toBe(true);
      expect(await completed).toBe("cancelled");
      const disposed = f.workspace.dispose();
      gate.resolve(context); await disposed;
      expect(f.sent).toHaveLength(0);
      expect(f.stopped).toEqual([instance.pluginID]);
    } finally { gate.resolve(context); await completed; await f.workspace.dispose(); }
  }, 5000);

  test("a cancelled Provider reply and its late progress cannot revive output or a model", async () => {
    const f = fixture(), gate = deferred<unknown>(); f.holdProvider(gate.promise);
    const operation = f.workspace.loadModel(instance), completed = operation.completion.catch(error => error.code);
    try {
      await f.entered.provider.promise;
      f.sent[0]!.onProgress?.({ output: "before cancel" });
      f.workspace.cancel(operation.operationID);
      expect(await completed).toBe("cancelled");
      expect(f.sent[0]!.signal?.aborted).toBe(true);
      f.sent[0]!.onProgress?.({ output: "must disappear" });
      gate.resolve({ projects: [] }); await f.workspace.dispose();
      expect(f.workspace.model(instance)).toBeUndefined();
      expect(f.workspace.operations()[0]).toMatchObject({ phase: "cancelled", output: "before cancel" });
      expect(f.coreCalls.some(call => call.command === "build.decodeModel")).toBe(false);
    } finally { gate.resolve({}); await completed; await f.workspace.dispose(); }
  }, 5000);

  test("an older decode cannot overwrite a replacement model even when options return to their original value", async () => {
    const f = fixture(), gate = deferred<unknown>(); f.holdCore("build.decodeModel", gate.promise);
    const old = f.workspace.loadModel(instance).completion.catch(error => error.code);
    try {
      await f.entered.decode.promise;
      f.workspace.invalidate({ ...instance, options: { profiles: ["changed"] } });
      expect(await old).toBe("cancelled");
      gate.resolve({ model: { ...model, projects: [] } });
      // The replacement sees the same decoded result, but the old ownership
      // must remain cancelled and cannot publish its original operation.
      await f.workspace.loadModel(instance).completion;
      expect(f.workspace.operations().map(record => record.phase)).toEqual(["cancelled", "succeeded"]);
      expect(f.workspace.model(instance)?.projects).toEqual([]);
    } finally { gate.resolve({ model }); await old; await f.workspace.dispose(); }
  }, 5000);

  test("plugin replacement between Provider reply and Core decode revokes the model", async () => {
    const f = fixture(), gate = deferred<unknown>(); f.holdCore("build.decodeModel", gate.promise);
    const operation = f.workspace.loadModel(instance), completed = operation.completion.catch(error => error.code);
    try {
      await f.entered.decode.promise; f.revoke(); gate.resolve({ model });
      expect(await completed).toBe("cancelled");
      expect(f.workspace.model(instance)).toBeUndefined();
      expect(f.workspace.operations()[0]?.phase).toBe("cancelled");
    } finally { gate.resolve({ model }); await completed; await f.workspace.dispose(); }
  }, 5000);

  test("a published model disappears immediately when its plugin generation changes", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      f.revoke();
      expect(f.workspace.model(instance)).toBeUndefined();
      await expect(f.workspace.executeTask(instance, "compile").completion).rejects.toThrow("complete current Build model");
      expect(f.sent).toHaveLength(1);
    } finally { await f.workspace.dispose(); }
  }, 5000);

  test("caller mutations cannot change an in-flight option or argument snapshot", async () => {
    const f = fixture(), selected = structuredClone(instance), gate = deferred<BuildToolContext>();
    try {
      await f.workspace.loadModel(selected).completion;
      const arguments_ = ["original"]; f.holdTools(gate.promise);
      const task = f.workspace.executeTask(selected, "test", "service", arguments_);
      selected.options.profiles = ["changed"]; arguments_[0] = "changed";
      gate.resolve(context); await task.completion;
      expect(f.coreCalls.find(call => call.command === "build.taskPlan")!.request).toMatchObject({ options: instance.options, userArguments: ["original"] });
      const projected = f.workspace.model(instance)!; projected.projects.length = 0;
      expect(f.workspace.model(instance)?.projects).toHaveLength(1);
    } finally { gate.resolve(context); await f.workspace.dispose(); }
  }, 5000);

  test("workspace close drains every target and refuses later operations even when one cleanup fails", async () => {
    const f = fixture();
    await f.workspace.loadModel(instance).completion;
    await f.workspace.loadModel({ ...instance, pluginID: "dev.other.build" }).completion.catch(() => undefined);
    f.failStop();
    await expect(f.workspace.dispose()).rejects.toThrow("cleanup failed");
    expect(f.stopped.sort()).toEqual(["dev.example.build", "dev.other.build"]);
    expect(() => f.workspace.loadModel(instance)).toThrow("inputs changed");
  }, 5000);

  test("completed history is bounded and final output preserves its latest diagnostic tail", async () => {
    const f = fixture();
    try {
      await f.workspace.loadModel(instance).completion;
      for (let index = 0; index < 51; index++) await f.workspace.executeTask(instance, "compile").completion;
      expect(f.workspace.operations()).toHaveLength(50);
      f.holdProvider(Promise.resolve({ exitCode: 2, output: "x".repeat(500_000) + "diagnostic tail" }));
      await f.workspace.executeTask(instance, "compile").completion;
      const operations = f.workspace.operations(), output = operations[operations.length - 1]!.output;
      expect(output.length).toBe(500_000); expect(output.endsWith("diagnostic tail")).toBe(true);
    } finally { await f.workspace.dispose(); }
  }, 5000);
});
