import { expect, mock, test } from "bun:test";
import { EMPTY_GLOBAL_TOOLCHAIN, type CoreInspectResult, type RunConfiguration } from "../types/run.types";
import type { ResolvedRunProject } from "../services/resolve-run-project";
import { createRunStore } from "./run.store";

function project(message: string): ResolvedRunProject {
  return {
    configurations: [{
      id: "app", name: "App", provider: "java", kindTitle: "Java", execution: "application",
      category: "project", cwd: ".", args: [], env: {}, jvmArguments: [], programArguments: [],
      profiles: [], mavenSkipTests: null, javaHomePath: "", mavenExecutablePath: "",
      mavenJavaHomePath: "", toolchains: {}, source: "generated", disabled: false,
    } satisfies RunConfiguration],
    diagnostics: message ? [{ code: "missingToolchain", message }] : [],
    defaultConfigurationId: null,
    discoveredJava: [],
    discoveredMaven: [],
    discoveredRuntimes: [],
    globalToolchain: EMPTY_GLOBAL_TOOLCHAIN,
    effectiveRuntimeExecutablePaths: {},
  };
}

function deferredInspection() {
  let resolve!: (result: CoreInspectResult) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<CoreInspectResult>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

test.each(["changed", "timeout", "missing", "unchanged"])("shows the run panel before fingerprint checking finishes: %s", async (outcome) => {
  const pending = deferredInspection();
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => { markStarted = resolve; });
  const inspectRunConfiguration = mock(async (_root: string, checkFingerprint = true) => {
    if (!checkFingerprint) return { status: "ready" };
    markStarted();
    return pending.promise;
  });
  const snapshot = project("Existing toolchain diagnostic");
  const store = createRunStore("workspace-A", {
    inspectRunConfiguration,
    resolveConfigurations: async () => snapshot,
  });
  const loading = store.getState().actions.loadProject("D:/fixture/project");
  try {
    await started;
    expect(store.getState().status).toBe("ready");
    expect(store.getState().isLoading).toBe(false);
    expect(store.getState().configurations).toBe(snapshot.configurations);
    expect(inspectRunConfiguration.mock.calls).toEqual([
      ["D:/fixture/project", false], ["D:/fixture/project", true],
    ]);
    if (outcome === "timeout") pending.reject(new Error("Operation timed out"));
    else if (outcome === "missing") pending.resolve({ status: "missing" });
    else if (outcome === "unchanged") pending.resolve({
      status: "ready", diagnostics: [{ code: "missingToolchain", message: "Existing toolchain diagnostic" }],
    });
    else pending.resolve({ status: "ready", diagnostics: [{ code: "staleFingerprint", message: "Inputs changed" }] });
    await loading;
    expect(store.getState().status).toBe("ready");
    expect(store.getState().configurations).toBe(snapshot.configurations);
    expect(store.getState().diagnostics.map(({ code }) => code)).toEqual(outcome === "unchanged" ?
      ["missingToolchain"] : ["missingToolchain", outcome === "changed" ? "staleFingerprint" : "fingerprintCheckFailed"]);
  } finally {
    pending.resolve({ status: "ready" });
    await loading;
  }
});

test.each([
  { failure: false, nextRoot: "D:/fixture/project" },
  { failure: true, nextRoot: "D:/fixture/project" },
  { failure: false, nextRoot: "D:/fixture/other" },
  { failure: true, nextRoot: "D:/fixture/other" },
])("ignores an old fingerprint result after another load: %j", async ({ failure, nextRoot }) => {
  const pending = deferredInspection();
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => { markStarted = resolve; });
  let checks = 0;
  const store = createRunStore("workspace-A", {
    inspectRunConfiguration: async (_root, checkFingerprint = true) => {
      if (checkFingerprint && ++checks === 1) {
        markStarted();
        return pending.promise;
      }
      return { status: "ready" };
    },
    resolveConfigurations: async () => project(""),
  });
  const oldLoad = store.getState().actions.loadProject("D:/fixture/project");
  try {
    await started;
    await store.getState().actions.loadProject(nextRoot);
    if (failure) pending.reject(new Error("Old inspection failed"));
    else pending.resolve({ status: "ready", diagnostics: [{ code: "staleFingerprint", message: "Old inputs changed" }] });
    await oldLoad;
    expect(store.getState().diagnostics).toEqual([]);
    expect(store.getState().status).toBe("ready");
  } finally {
    pending.resolve({ status: "ready" });
    await oldLoad;
  }
});

test("missing documents keep regeneration recovery and skip the content scan", async () => {
  const inspectRunConfiguration = mock(async () => ({ status: "missing" }));
  const resolveConfigurations = mock(async () => project(""));
  const store = createRunStore("workspace-A", { inspectRunConfiguration, resolveConfigurations });
  await store.getState().actions.loadProject("D:/fixture/project");
  expect(inspectRunConfiguration).toHaveBeenCalledTimes(1);
  expect(resolveConfigurations).not.toHaveBeenCalled();
  expect(store.getState().status).toBe("missing");
  expect(store.getState().recoveryAction).toBe("regenerate");
});

test("a slow load cannot restore the missing-Maven warning after settings refresh", async () => {
  let finishOld!: (result: ResolvedRunProject) => void;
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    markStarted = resolve;
  });
  const oldResult = new Promise<ResolvedRunProject>((resolve) => {
    finishOld = resolve;
  });
  const resolveConfigurations = mock(async () => {
    if (resolveConfigurations.mock.calls.length === 1) {
      markStarted();
      return oldResult;
    }
    return project("");
  });
  const store = createRunStore("workspace-A", {
    inspectRunConfiguration: mock(async () => ({ status: "ready" as const })),
    resolveConfigurations,
  });
  const oldLoad = store.getState().actions.loadProject("D:/fixture/project");
  try {
    await started;
    await store.getState().actions.loadProject("D:/fixture/project");
    expect(store.getState().diagnostics).toEqual([]);
  } finally {
    finishOld(project("No local maven toolchain is selected"));
    await oldLoad;
  }
  expect(store.getState().status).toBe("ready");
  expect(store.getState().diagnostics).toEqual([]);
  expect(store.getState().isLoading).toBe(false);
});
