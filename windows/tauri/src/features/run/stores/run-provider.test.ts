import { expect, mock, test } from "bun:test";
import { createRunStore } from "./run.store";
import { mapCoreConfiguration } from "../utils/run-configuration";
import { EMPTY_GLOBAL_TOOLCHAIN } from "../types/run.types";
import type { BuildProviderRunRequest } from "../services/build-provider-run-launch";

function deferred() {
  let resolve!: () => void, reject!: (error: unknown) => void;
  const promise = new Promise<void>((done, failed) => { resolve = done; reject = failed; }); return { promise, resolve, reject };
}
function fixture(provider = "build.provider", admitted = false) {
  const configuration = mapCoreConfiguration({ id: "user:service", name: "Provider service", provider, execution: "service", source: "local",
    extensions: provider === "build.provider" ? { build: { pluginID: "dev.example.build", buildSystemID: "example", root: ".", run: "serve", projectID: "app", targetID: "exact",
      execution: "service", userArguments: ["", "two words"] } } : { maven: { reactorPath: "nested", module: "app" } } });
  const entries: Array<{ request: BuildProviderRunRequest; gate: ReturnType<typeof deferred>; stops: number; finishes: number;
    finishGate?: ReturnType<typeof deferred> }> = [];
  const entered = deferred(), replacementEntered = deferred(), legacy = mock(async () => { throw new Error("legacy planning must not run"); });
  const store = createRunStore("provider-run-store", {
    isBuildProviderRunAdmitted: async () => admitted,
    inspectRunConfiguration: async () => ({ status: "ready" }),
    resolveConfigurations: async () => ({ configurations: [configuration], diagnostics: [], defaultConfigurationId: null,
      discoveredJava: [], discoveredMaven: [], discoveredRuntimes: [], globalToolchain: EMPTY_GLOBAL_TOOLCHAIN, effectiveRuntimeExecutablePaths: {} }),
    createLaunchPlan: legacy, mavenLaunchContextForWorkspace: legacy, prepareJavaRunLaunch: legacy,
    saveWorkspaceBeforeLaunch: async () => {}, stopRunProcess: async () => {},
    startBuildProviderRun: request => {
      const entry = { request, gate: deferred(), stops: 0, finishes: 0, finishGate: undefined as ReturnType<typeof deferred> | undefined }; entries.push(entry); entered.resolve();
      if (entries.length === 2) replacementEntered.resolve();
      return { completion: entry.gate.promise.then(() => request.onReady({ executable: "C:/tool/run.cmd", arguments: ["", "two words"], workingDirectory: "C:/work", environment: {} })),
        stop: async () => { entry.stops++; request.onRevoked(); entry.gate.reject(new DOMException("Aborted", "AbortError")); },
        finished: () => { entry.finishes++; return entry.finishGate?.promise; },
      };
    },
  });
  store.setState({ root: "C:/work", configurations: [configuration], diagnostics: [] });
  return { store, entries, entered: entered.promise, replacementEntered: replacementEntered.promise, legacy, configuration,
    close: async () => { entered.resolve(); replacementEntered.resolve(); entries.forEach(entry => entry.gate.resolve()); await store.getState().actions.stop(configuration.id); } };
}

test("saved Provider runs use the existing service session and retain preparation output through launch and exit", async () => {
  const f = fixture(), running = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
  try {
    await f.entered; expect(f.store.getState().sessions[0]).toMatchObject({ isPreparing: true, isRunning: false });
    const entry = f.entries[0]!; entry.request.onOutput("upstream preparation\n"); entry.gate.resolve();
    const launched = await running;
    expect(launched).toEqual({ sessionId: f.configuration.id, executionId: entry.request.executionId });
    expect(f.store.getState().sessions[0]).toMatchObject({ executionId: entry.request.executionId, isRunning: true, isPreparing: false });
    expect(f.store.getState().sessions[0]!.output).toContain("upstream preparation");
    expect(f.store.getState().sessions[0]!.output).toContain("$ run.cmd  two words");
    expect(f.legacy).not.toHaveBeenCalled();
    f.store.getState().actions.finishProcess(f.configuration.id, 0); await Promise.resolve(); expect(entry.finishes).toBe(1);
    expect(f.store.getState().sessions[0]?.isRunning).toBe(false);
  } finally { await f.close(); await running; }
}, 5000);

test("an admitted framework configuration uses Provider preparation and preserves its existing service ID", async () => {
  const f = fixture("spring-boot.maven", true), running = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
  try {
    await f.entered; const entry = f.entries[0]!;
    expect(entry.request.reference).toBeUndefined(); expect(entry.request.source).toEqual({ buildSystemID: "maven", root: "nested", provider: "spring-boot.maven", execution: "service" });
    entry.gate.resolve(); expect(await running).toEqual({ sessionId: f.configuration.id, executionId: entry.request.executionId });
    expect(f.legacy).not.toHaveBeenCalled();
  } finally { await f.close(); await running; }
}, 5000);

test("a host with closed Build admission preserves the existing framework route", async () => {
  const f = fixture("spring-boot.maven", false);
  try {
    expect(await f.store.getState().actions.runConfigurationInstance(f.configuration.id)).toBeNull();
    expect(f.entries).toEqual([]); expect(f.legacy).toHaveBeenCalled();
  } finally { await f.close(); }
}, 5000);

test("exit cleanup failures remain visible and retained for the next Run to retry", async () => {
  const f = fixture(), running = f.store.getState().actions.runConfigurationInstance(f.configuration.id), reported = deferred(), finish = deferred();
  let replacement: Promise<unknown> | undefined;
  const unsubscribe = f.store.subscribe(state => { if (state.sessions.some(session => session.output.includes("source cleanup failed"))) reported.resolve(); });
  try {
    await f.entered; const old = f.entries[0]!; old.gate.resolve(); await running; old.finishGate = finish;
    expect(f.store.getState().actions.finishProcess(f.configuration.id, 0)).toBe(true); finish.reject(new Error("source cleanup failed"));
    await reported.promise;
    replacement = f.store.getState().actions.runConfigurationInstance(f.configuration.id); await f.replacementEntered;
    expect(old.stops).toBe(1); f.entries[1]!.gate.resolve(); await replacement;
    expect(f.store.getState().sessions[0]?.output).not.toContain("source cleanup failed");
  } finally { unsubscribe(); finish.reject(new Error("closed")); await f.close(); await Promise.allSettled([running, replacement, finish.promise]); }
}, 5000);

test("Stop during Provider preparation retires the operation and ignores late output or readiness", async () => {
  const f = fixture(), running = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
  try {
    await f.entered; const entry = f.entries[0]!;
    await f.store.getState().actions.stop(f.configuration.id, entry.request.executionId); expect(await running).toBeNull();
    entry.request.onOutput("late output"); entry.request.onReady({ executable: "old", arguments: [], workingDirectory: ".", environment: {} });
    expect(entry.stops).toBe(1); expect(f.store.getState().sessions[0]).toMatchObject({ isPreparing: false, isRunning: false });
    expect(f.store.getState().sessions[0]?.output).not.toContain("late output");
  } finally { await f.close(); await running; }
}, 5000);

test("a replacement preserves its execution identity when the old adapter requests Stop", async () => {
  const f = fixture(), first = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
  let second: Promise<unknown> | undefined;
  try {
    await f.entered; const old = f.entries[0]!;
    second = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
    await first;
    await f.replacementEntered;
    const current = f.entries[1]!; expect(current).toBeDefined(); current.gate.resolve(); await second;
    await f.store.getState().actions.stop(f.configuration.id, old.request.executionId);
    expect(current.stops).toBe(0); expect(f.store.getState().sessions[0]).toMatchObject({ executionId: current.request.executionId, isRunning: true });
  } finally { await f.close(); await Promise.allSettled([first, second]); }
}, 5000);

test("project reload cancels pending Provider preparation while a completed native handoff survives a same-project refresh", async () => {
  const f = fixture(), pending = f.store.getState().actions.runConfigurationInstance(f.configuration.id);
  let running: Promise<unknown> | undefined;
  try {
    await f.entered; const first = f.entries[0]!;
    await f.store.getState().actions.loadProject("C:/work"); expect(await pending).toBeNull(); expect(first.stops).toBe(1);
    running = f.store.getState().actions.runConfigurationInstance(f.configuration.id); await f.replacementEntered;
    const second = f.entries[1]!; second.gate.resolve(); await running;
    await f.store.getState().actions.loadProject("C:/work"); expect(second.stops).toBe(0);
    expect(f.store.getState().sessions[0]?.isRunning).toBe(true);
  } finally { await f.close(); await Promise.allSettled([pending, running]); }
}, 5000);
