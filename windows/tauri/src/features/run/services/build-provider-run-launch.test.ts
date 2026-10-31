import { expect, test } from "bun:test";
import { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { WindowsBuildProviderWorkspace, type WorkspacePorts } from "@/features/build/services/build-provider-workspace";
import { startBuildProviderRun, type BuildProviderRunPorts, type BuildProviderRunRequest } from "./build-provider-run-launch";
import type { BuildProviderRunReference } from "../types/run.types";

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(complete => { resolve = complete; }); return { promise, resolve }; }
const reference: BuildProviderRunReference = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", run: "serve",
  projectID: "app", targetID: "application", execution: "service", userArguments: ["", "two words"] };
function fixture() {
  const sent: string[] = [], nativeStarts: Parameters<BuildProviderRunPorts["start"]>[0][] = [], nativeStops: Array<[string, string | undefined]> = [];
  const resolved: Parameters<BuildProviderRunPorts["resolve"]>[0][] = [], current = new Map<string, boolean>(), output: string[] = [];
  const nativeEntered = deferred<void>(), modelEntered = deferred<void>();
  let nativeGate: Promise<void> | undefined, modelGate: Promise<void> | undefined, changedReference = false, stopFails = false;
  const domain = new WindowsBuildProviderWorkspace("C:/work", {
    core: (async (command: string, _manifest: unknown, _system: unknown, request: Record<string, unknown>) => {
      if (command.endsWith("Plan")) return { plan: { provider: { method: command, params: request } } };
      if (command === "build.syncFingerprint") return { sync: { fingerprint: "same", watch: ["project.marker"] } };
      if (command === "build.decodeModel") return { model: { projects: [{ id: "app", name: "App", path: "app", properties: {} }],
        targets: [{ id: "application", projectID: "app", name: "Application", path: "app", tags: ["application"], properties: {} }], tasks: [], contentRoots: [], optionValues: {} } };
      if (command === "build.decodeRunPreparation") return { launch: { executable: { kind: "toolchain", value: "project-maven" }, arguments: ["upstream-goal", "", "two words"], workingDirectory: "app", environment: { CHOSEN: "provider" } } };
      if (command === "build.languageImport") return { languageImport: { kind: "maven", mavenContext: { version: 1, reactorPath: ".", profiles: [], mavenExecutablePath: "C:/selected/mvn.cmd" } } };
      throw new Error(command);
    }) as WorkspacePorts["core"],
    guard: () => () => {}, translate: key => key,
    tools: async () => ({ manifest: { id: reference.pluginID }, tool: { executable: "C:/selected/mvn.cmd" }, environment: { JAVA_HOME: "C:/selected/jdk" },
      pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state", executesProjectCode: false }),
    providers: { send: async <T,>(_target: unknown, request: Parameters<WorkspacePorts["providers"]["send"]>[1]) => {
      sent.push(request.method);
      if (request.method === "build.modelPlan") { modelEntered.resolve(); await modelGate; }
      request.onProgress?.({ output: request.method === "build.modelPlan" ? "model progress\n" : "upstream progress\n" }); return {} as T;
    }, stop: async () => {} },
  });
  const workspace = new BuildWorkspaceController("C:/work", { domain, guard: () => () => {}, detect: async () => ({
    plugins: [{ manifest: { id: reference.pluginID } }], document: { version: 1, systems: {} }, detection: { instances: [{ ...reference,
      options: {}, id: "example:root", displayName: "Example", modelSource: "provider", optionFingerprint: "default", droppedOptions: [] }], rejected: [], shadowed: [] },
  }) });
  const processes = new ExtensionProcessOwner();
  const ports: BuildProviderRunPorts = {
    processes, workspace: () => workspace, unavailable: () => new Error("current Provider unavailable"),
    inputs: async () => ({ buildSystemID: reference.buildSystemID, provider: reference.run, projectPath: ".", optionOverrides: {},
      reference: { ...reference, ...(changedReference ? { targetID: "replaced" } : {}) },
      launchOptions: { execution: "service", runtimeArguments: [], arguments: [...reference.userArguments], environment: {} } }),
    resolve: async args => { resolved.push(args); return { executable: "C:/selected/mvn.cmd", workingDirectory: "C:/work/app", environment: args.environment as Record<string, string> }; },
    start: async args => { nativeStarts.push(args); nativeEntered.resolve(); await nativeGate; },
    stop: async (session, execution) => { nativeStops.push([session, execution]); if (stopFails) throw new Error("native stop failed"); },
  };
  const handles: ReturnType<typeof startBuildProviderRun>[] = [];
  const start = (id = "run") => {
    current.set(id, true);
    const request: BuildProviderRunRequest = { workspaceId: "workspace", root: "C:/work", configurationId: "user:serve", name: "Service", reference,
      sessionId: id, executionId: `execution:${id}`, runtimeExecutablePaths: {}, isCurrent: () => current.get(id) === true,
      onRevoked: () => { current.set(id, false); }, onOutput: text => { output.push(text); }, onReady: () => {} };
    const handle = startBuildProviderRun(request, ports); void handle.completion.catch(() => {}); handles.push(handle); return handle;
  };
  return { start, ports, workspace, sent, nativeStarts, nativeStops, resolved, output, nativeEntered: nativeEntered.promise, modelEntered: modelEntered.promise,
    nativeGate: (gate: Promise<void>) => { nativeGate = gate; }, modelGate: (gate: Promise<void>) => { modelGate = gate; },
    changeReference: () => { changedReference = true; }, failStop: (value: boolean) => { stopFails = value; },
    close: async () => { stopFails = false; await processes.stop(); await Promise.allSettled(handles.map(handle => handle.completion)); await workspace.dispose(); } };
}

test("saved Provider execution uses Core selectors and the current native Maven/JDK without losing argv or output", async () => {
  const f = fixture();
  try {
    const run = f.start(); await run.completion;
    expect(f.nativeStarts).toHaveLength(1); expect(f.nativeStarts[0]).toMatchObject({ executionId: "execution:run", arguments: ["upstream-goal", "", "two words"] });
    expect(f.resolved[0]).toMatchObject({ executable: { toolchain: "project-maven" }, mavenExecutablePath: "C:/selected/mvn.cmd", mavenJavaHomePath: "C:/selected/jdk", environment: { CHOSEN: "provider", JAVA_HOME: "C:/selected/jdk" } });
    expect(f.output.join("")).toBe("model progress\nupstream progress\n");
    await run.stop(); expect(f.nativeStops).toEqual([["run", "execution:run"]]);
  } finally { await f.close(); }
}, 5000);

test("parallel services share one model and stopping one waiter does not cancel the other", async () => {
  const f = fixture(), gate = deferred<void>(); f.modelGate(gate.promise);
  const first = f.start("first"), second = f.start("second");
  try {
    await f.modelEntered; await first.stop(); await expect(first.completion).rejects.toThrow();
    gate.resolve(); await second.completion;
    expect(f.sent.filter(method => method === "build.modelPlan")).toHaveLength(1);
    expect(f.nativeStarts.map(start => start.executionId)).toEqual(["execution:second"]);
  } finally { gate.resolve(); await f.close(); }
}, 5000);

test("stop owns a native spawn acknowledgement and reaps its late process", async () => {
  const f = fixture(), gate = deferred<void>(); f.nativeGate(gate.promise);
  const run = f.start(); let stopped = false;
  try {
    await f.nativeEntered; const stopping = run.stop().then(() => { stopped = true; });
    expect(stopped).toBe(false); gate.resolve(); await stopping;
    await expect(run.completion).rejects.toThrow(); expect(f.nativeStops).toEqual([["run", "execution:run"]]);
  } finally { gate.resolve(); await f.close(); }
}, 5000);

test("a changed saved reference cannot start another target under the old user action", async () => {
  const f = fixture(); f.changeReference();
  try { await expect(f.start().completion).rejects.toThrow("unavailable"); expect(f.sent).toEqual([]); expect(f.nativeStarts).toEqual([]); }
  finally { await f.close(); }
}, 5000);

test("a saved reference edited during model preparation is rechecked before native startup", async () => {
  const f = fixture(), gate = deferred<void>(); f.modelGate(gate.promise);
  try {
    const run = f.start(); await f.modelEntered; f.changeReference(); gate.resolve();
    await expect(run.completion).rejects.toThrow("unavailable"); expect(f.nativeStarts).toEqual([]);
  } finally { gate.resolve(); await f.close(); }
}, 5000);

test("failed native cleanup retains the exact process for an explicit retry", async () => {
  const f = fixture();
  try {
    const run = f.start(); await run.completion; f.failStop(true);
    await expect(run.stop()).rejects.toThrow("native stop failed"); expect(f.nativeStops).toHaveLength(1);
    f.failStop(false); await run.stop(); expect(f.nativeStops).toEqual([["run", "execution:run"], ["run", "execution:run"]]);
  } finally { await f.close(); }
}, 5000);

test("saved launch arguments edited during preparation cannot use the old plan with the same target reference", async () => {
  const f = fixture(), gate = deferred<void>(); f.modelGate(gate.promise);
  const inputs = f.ports.inputs; let edited = false;
  f.ports.inputs = async (...args) => {
    const value = await inputs(...args);
    if (edited) value.launchOptions.arguments = ["changed argument"];
    return value;
  };
  try {
    const run = f.start(); await f.modelEntered; edited = true; gate.resolve();
    await expect(run.completion).rejects.toThrow("unavailable"); expect(f.nativeStarts).toEqual([]);
  } finally { gate.resolve(); await f.close(); }
}, 5000);
