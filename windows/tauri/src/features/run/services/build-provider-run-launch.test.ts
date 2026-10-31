import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { WindowsBuildProviderWorkspace, type WorkspacePorts } from "@/features/build/services/build-provider-workspace";
import { startBuildProviderRun, type BuildProviderRunPorts, type BuildProviderRunRequest } from "./build-provider-run-launch";
import type { BuildProviderRunReference } from "../types/run.types";

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(complete => { resolve = complete; }); return { promise, resolve }; }
const defaultReference: BuildProviderRunReference = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", run: "serve",
  projectID: "app", targetID: "application", execution: "service", userArguments: ["", "two words"] };
function fixture(reference: BuildProviderRunReference = defaultReference) {
  const manifest = { id: reference.pluginID, buildSystems: [{ id: reference.buildSystemID, configuration: reference.execution === "service" ? { source: "provider" } : undefined,
    run: [{ id: reference.run, source: "provider", execution: reference.execution ?? "application", fromTargets: { tags: ["application"] } }] }] };
  const sent: string[] = [], nativeStarts: Parameters<BuildProviderRunPorts["start"]>[0][] = [], nativeStops: Array<[string, string | undefined]> = [];
  const resolved: Parameters<BuildProviderRunPorts["resolve"]>[0][] = [], current = new Map<string, boolean>(), output: string[] = [];
  const nativeEntered = deferred<void>(), modelEntered = deferred<void>();
  const watches: Array<{ attempts: number; closed: boolean; changed: () => void }> = [];
  const configurationIDs: Array<string | undefined> = [], providerInputs: Array<Record<string, unknown>> = [];
  let moduleTools = false;
  let nativeGate: Promise<void> | undefined, modelGate: Promise<void> | undefined, changedReference = false, stopFails = false, scopeReleaseFails = false;
  const domain = new WindowsBuildProviderWorkspace("C:/work", {
    core: (async (command: string, _manifest: unknown, _system: unknown, request: Record<string, unknown>) => {
      if (command === "build.prepareRunPlan" && (reference.execution ?? "application") === "application" && request.launchOptions !== undefined) {
        throw new Error("Protocol 4 rejects typed launch options");
      }
      if (command.endsWith("Plan")) return { plan: { provider: { method: command, params: request } } };
      if (command === "build.syncFingerprint") return { sync: { fingerprint: "same", watch: ["project.marker"] } };
      if (command === "build.resolveOptions") return { options: { dropped: [], options: Object.keys(request.options as object).map(id => ({ id, source: "user" })) } };
      if (command === "build.decodeConfiguration") return { configuration: { format: "litheBuildConfiguration", version: 1, sources: [{ id: "user", scope: "user",
        uri: "file:///C:/fixture/settings.xml", revision: "sha256:" + "a".repeat(64), writable: false, rootElement: { name: "settings", namespace: "" }, fields: [] }] } };
      if (command === "build.decodeModel") return { model: { projects: [{ id: "app", name: "App", path: "app", properties: {} }],
        targets: [{ id: "application", projectID: "app", name: "Application", path: "app", tags: ["application"], properties: {} }], tasks: [], contentRoots: [], optionValues: {} } };
      if (command === "build.decodeRunPreparation") return { launch: { executable: { kind: "toolchain", value: "project-maven" }, arguments: ["upstream-goal", "", "two words"], workingDirectory: "app", environment: { CHOSEN: "provider" } } };
      if (command === "build.languageImport") return { languageImport: { kind: "maven", mavenContext: { version: 1, reactorPath: ".", profiles: [], mavenExecutablePath: request.executablePath } } };
      throw new Error(command);
    }) as WorkspacePorts["core"],
    guard: () => () => {}, translate: key => key,
    tools: async (_target, _root, _check, owner) => {
      configurationIDs.push(owner); if (moduleTools && !owner) throw new Error("Default Maven is unavailable"); const selected = moduleTools && owner === "user:serve" ? "module" : "selected";
      return { manifest, tool: { executable: `C:/${selected}/mvn.cmd` }, environment: { JAVA_HOME: `C:/${selected}/jdk` },
        pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state", executesProjectCode: false };
    },
    configurationCheck: async () => ({ current: true, paths: ["C:/fixture/settings.xml"] }),
    watchConfiguration: (_target, _sources, changed) => {
      const index = watches.length, watch = { attempts: 0, closed: false, changed }; watches.push(watch);
      return { recheck: () => {}, dispose: async () => { watch.attempts++; if (scopeReleaseFails) throw new Error("source release failed"); watch.closed = true; } };
    },
    providers: { send: async <T,>(_target: unknown, request: Parameters<WorkspacePorts["providers"]["send"]>[1]) => {
      sent.push(request.method);
      providerInputs.push(structuredClone(request.params as Record<string, unknown>));
      if (request.method === "build.modelPlan") { modelEntered.resolve(); await modelGate; }
      if (request.method === "build.modelPlan" || request.method === "build.prepareRunPlan") request.onProgress?.({
        output: request.method === "build.modelPlan" ? "model progress\n" : "upstream progress\n" }); return {} as T;
    }, stop: async () => {} },
  });
  const workspace = new BuildWorkspaceController("C:/work", { domain, guard: () => () => {}, detect: async () => ({
    plugins: [{ manifest }], document: { version: 1, systems: {} }, detection: { instances: [{ ...reference,
      options: {}, id: "example:root", displayName: "Example", modelSource: "provider", optionFingerprint: "default", droppedOptions: [] }], rejected: [], shadowed: [] },
  }) });
  const processes = new ExtensionProcessOwner();
  const ports: BuildProviderRunPorts = {
    processes, workspace: () => workspace, unavailable: () => new Error("current Provider unavailable"),
    inputs: async () => ({ buildSystemID: reference.buildSystemID, provider: reference.run, projectPath: ".", optionOverrides: {},
      reference: { ...reference, ...(changedReference ? { targetID: "replaced" } : {}) },
      launchOptions: { execution: reference.execution ?? "application", runtimeArguments: [], arguments: [...reference.userArguments ?? []], environment: {} } }),
    resolve: async args => { resolved.push(args); return { executable: args.mavenExecutablePath ?? "C:/selected/mvn.cmd", workingDirectory: "C:/work/app", environment: args.environment as Record<string, string> }; },
    start: async args => { nativeStarts.push(args); nativeEntered.resolve(); await nativeGate; },
    stop: async (session, execution) => { nativeStops.push([session, execution]); if (stopFails) throw new Error("native stop failed"); },
  };
  const handles: ReturnType<typeof startBuildProviderRun>[] = [];
  const start = (id = "run", overrides: Partial<BuildProviderRunRequest> = {}) => {
    current.set(id, true);
    const request: BuildProviderRunRequest = { workspaceId: "workspace", root: "C:/work", configurationId: "user:serve", name: "Service", reference,
      sessionId: id, executionId: `execution:${id}`, runtimeExecutablePaths: {}, isCurrent: () => current.get(id) === true,
      onRevoked: () => { current.set(id, false); }, onOutput: text => { output.push(text); }, onReady: () => {}, ...overrides };
    const handle = startBuildProviderRun(request, ports); void handle.completion.catch(() => {}); handles.push(handle); return handle;
  };
  return { start, ports, workspace, sent, nativeStarts, nativeStops, resolved, output, nativeEntered: nativeEntered.promise, modelEntered: modelEntered.promise,
    nativeGate: (gate: Promise<void>) => { nativeGate = gate; }, modelGate: (gate: Promise<void>) => { modelGate = gate; },
    changeReference: () => { changedReference = true; }, failStop: (value: boolean) => { stopFails = value; }, watches, processes, providerInputs, configurationIDs,
    selectConfigurationTools: () => { moduleTools = true; },
    failScopeRelease: (value: boolean) => { scopeReleaseFails = value; },
    close: async () => { stopFails = false; scopeReleaseFails = false; await processes.stop(); await Promise.allSettled(handles.map(handle => handle.completion)); await workspace.dispose(); } };
}

test("saved Provider execution uses Core selectors and the current native Maven/JDK without losing argv or output", async () => {
  const f = fixture();
  try {
    const run = f.start(); await run.completion;
    expect(f.nativeStarts).toHaveLength(1); expect(f.nativeStarts[0]).toMatchObject({ executionId: "execution:run", arguments: ["upstream-goal", "", "two words"] });
    expect(f.resolved[0]).toMatchObject({ executable: { toolchain: "project-maven" }, mavenExecutablePath: "C:/selected/mvn.cmd", mavenJavaHomePath: "C:/selected/jdk", environment: { CHOSEN: "provider", JAVA_HOME: "C:/selected/jdk" } });
    expect(f.output.join("")).toBe("model progress\nupstream progress\n");
    expect(f.watches.map(watch => watch.closed)).toEqual([true]);
    await run.stop(); expect(f.nativeStops).toEqual([["run", "execution:run"]]);
  } finally { await f.close(); }
}, 5000);

test("saved application arguments from the shared fixture retain the protocol-4 opaque channel", async () => {
  const shared = JSON.parse(readFileSync(new URL("../../../../../../shared/fixtures/run-configuration/build-provider.json", import.meta.url), "utf8"));
  const f = fixture({ ...defaultReference, execution: undefined, userArguments: shared.reference.userArguments });
  try {
    await f.start().completion;
    const prepared = f.providerInputs.find(input => input.run === defaultReference.run);
    expect(prepared).toBeDefined(); expect(prepared!.userArguments).toEqual(shared.reference.userArguments);
    expect(prepared!.launchOptions !== undefined).toBe(shared.expected.applicationReferenceUsesLaunchOptions);
  } finally { await f.close(); }
}, 5000);

test("a typed application override still requires the newer protocol instead of silently degrading to opaque arguments", async () => {
  const f = fixture({ ...defaultReference, execution: "application" }), read = f.ports.inputs;
  f.ports.inputs = async (...args) => { const inputs = await read(...args); inputs.launchOptions.runtimeArguments = ["-Xmx64m"]; return inputs; };
  try {
    await expect(f.start().completion).rejects.toThrow("Protocol 4 rejects typed launch options"); expect(f.nativeStarts).toEqual([]);
  } finally { await f.close(); }
}, 5000);

test("parallel services prepare independently and stopping one cannot cancel the other", async () => {
  const f = fixture(), gate = deferred<void>(); f.modelGate(gate.promise);
  const first = f.start("first"), second = f.start("second");
  try {
    await f.modelEntered; const stopping = first.stop(); gate.resolve(); await stopping; await expect(first.completion).rejects.toThrow();
    await second.completion;
    expect(f.sent.filter(method => method === "build.modelPlan")).toHaveLength(2); // Each service owns one private model.
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

test("a configuration-owned Run reads its private Profiles and selected module Maven/JDK without replacing defaults", async () => {
  const f = fixture(); f.selectConfigurationTools(); const read = f.ports.inputs;
  f.ports.inputs = async (...args) => ({ ...await read(...args), reference: undefined, provider: "Application", projectPath: "app",
    optionOverrides: { profiles: ["run-only"], skipTests: false } });
  try {
    const run = f.start("legacy", { reference: undefined, source: { buildSystemID: defaultReference.buildSystemID, root: ".", provider: "Application", execution: "service" } });
    await run.completion;
    expect(f.providerInputs.some(input => JSON.stringify(input.options) === JSON.stringify({ profiles: ["run-only"], skipTests: false }))).toBe(true);
    expect(f.resolved[0]).toMatchObject({ mavenExecutablePath: "C:/module/mvn.cmd", mavenJavaHomePath: "C:/module/jdk" });
    const entry = f.workspace.snapshot().entries[0]!; expect(entry.options).toEqual({}); expect(f.workspace.domain.hasCurrentModel(entry)).toBe(false);
    expect(f.configurationIDs).toContain("user:serve");
    await f.processes.stop(undefined, defaultReference.pluginID); expect(f.nativeStops).toEqual([["legacy", "execution:legacy"]]);
  } finally { await f.close(); }
}, 5000);

test("failed private source cleanup stops the native execution once and retains its source lease for an explicit retry", async () => {
  const f = fixture(); f.failScopeRelease(true);
  try {
    const run = f.start(); await expect(run.completion).rejects.toThrow("cleanupFailed");
    expect(f.nativeStops).toEqual([["run", "execution:run"]]); expect(f.watches[0]?.attempts).toBe(1); expect(f.watches[0]?.closed).toBe(false);
    f.failScopeRelease(false); await run.stop(); expect(f.watches[0]?.attempts).toBe(2); expect(f.watches[0]?.closed).toBe(true);
    expect(f.nativeStops).toHaveLength(1);
  } finally { await f.close(); }
}, 5000);

test("a failed late-spawn stop is not silently retried within the same Stop request", async () => {
  const f = fixture(), gate = deferred<void>(); f.nativeGate(gate.promise);
  const run = f.start();
  try {
    await f.nativeEntered; f.failStop(true); const stopping = run.stop(); gate.resolve();
    await expect(stopping).rejects.toThrow("native stop failed"); await expect(run.completion).rejects.toThrow("native stop failed");
    expect(f.nativeStops).toHaveLength(1); f.failStop(false); await run.stop(); expect(f.nativeStops).toHaveLength(2);
  } finally { gate.resolve(); await f.close(); }
}, 5000);

test("native exit before spawn acknowledgement keeps preparation and source cleanup owned until both settle", async () => {
  const f = fixture(), gate = deferred<void>(); f.nativeGate(gate.promise);
  const run = f.start(); let finished = false;
  try {
    await f.nativeEntered; const finishing = Promise.resolve(run.finished()).then(() => { finished = true; });
    expect(finished).toBe(false); expect(f.watches[0]?.closed).toBe(false);
    gate.resolve(); await finishing; expect(f.watches[0]?.closed).toBe(true);
    expect(f.nativeStops).toEqual([["run", "execution:run"]]);
  } finally { gate.resolve(); await f.close(); }
}, 5000);
