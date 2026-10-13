import { describe, expect, test } from "bun:test";
import type { JavaEntrypoints } from "@/platform/lsp-core-adapter";
import type { JavaEntrypointDiscovery } from "../services/java-entrypoint-discovery";
import type { CoreInspectResult, RunConfiguration } from "../types/run.types";

const { createRunStore } = await import("./run.store");

const ROOT = "C:/work";
const ENTRYPOINTS: JavaEntrypoints = {
  schemaVersion: 1,
  entries: [{ sourcePath: "src/main/java/demo/App.java", mainClass: "demo.App" }],
  diagnostics: [],
};
const STALE = { code: "staleFingerprint", message: "Java entry points changed: 1 added, 0 removed" };

/**
 * A store whose Core and JDT calls are recorded. Issue #507: the fingerprint no
 * longer hashes every Java source, so after a load the store compares JDT's
 * answer with the generated entries instead.
 */
function harness(options: {
  provider?: string;
  discoveries: Array<JavaEntrypointDiscovery | Promise<JavaEntrypointDiscovery>>;
}) {
  const discoverCalls: string[][] = [];
  const entrypointChecks: Array<JavaEntrypoints | undefined> = [];
  const preparedListeners: Array<() => void> = [];
  let stoppedWaiting = 0;
  const discoveries = [...options.discoveries];
  // Tests await observable events instead of counting microtasks: the check
  // runs after `loadProject` resolves, off the load task.
  const waiters: Array<{ ready: () => boolean; resolve: () => void }> = [];
  const notify = () => {
    for (const waiter of waiters.splice(0)) {
      if (waiter.ready()) waiter.resolve();
      else waiters.push(waiter);
    }
  };
  const until = (ready: () => boolean) =>
    new Promise<void>((resolve) => {
      if (ready()) resolve();
      else waiters.push({ ready, resolve });
    });
  let checked!: () => void;
  const entrypointsChecked = new Promise<void>((resolve) => {
    checked = resolve;
  });
  const store = createRunStore("workspace-1", {
    discoverJavaEntrypoints: async (_scope, sources) => {
      discoverCalls.push(sources);
      notify();
      return await (discoveries.shift() ?? { kind: "pending" });
    },
    whenJavaProjectPrepared: (_root, listener) => {
      preparedListeners.push(listener);
      notify();
      return () => {
        stoppedWaiting += 1;
      };
    },
    inspectRunConfiguration: async (_root, _checkFingerprint = true, javaEntrypoints) => {
      if (!javaEntrypoints) return { status: "ready" } satisfies CoreInspectResult;
      entrypointChecks.push(javaEntrypoints);
      queueMicrotask(checked);
      return { status: "ready", diagnostics: [STALE] } satisfies CoreInspectResult;
    },
    resolveConfigurations: async () =>
      ({
        configurations: [
          { id: "app", provider: options.provider ?? "java.main" } as RunConfiguration,
        ],
        diagnostics: [],
        defaultConfigurationId: null,
        discoveredJava: [],
        discoveredMaven: [],
        discoveredRuntimes: [],
        globalToolchain: {},
        effectiveRuntimeExecutablePaths: {},
      }) as never,
  });
  return {
    store,
    discoverCalls,
    entrypointChecks,
    entrypointsChecked,
    preparedListeners,
    stoppedWaiting: () => stoppedWaiting,
    until,
  };
}

describe("Java entry-point freshness after loading the Run list", () => {
  test("reports entries JDT added since generation without starting JDT", async () => {
    const { store, discoverCalls, entrypointChecks, entrypointsChecked } = harness({
      discoveries: [{ kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.loadProject(ROOT);
    await entrypointsChecked;

    // No sources are passed, so discovery never prewarms JDT for this check.
    expect(discoverCalls).toEqual([[]]);
    expect(entrypointChecks).toEqual([ENTRYPOINTS]);
    expect(store.getState().diagnostics).toEqual([STALE]);
  });

  test("waits for JDT to finish preparing, then compares", async () => {
    const { store, entrypointChecks, entrypointsChecked, preparedListeners, until } = harness({
      discoveries: [{ kind: "pending" }, { kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.loadProject(ROOT);
    // The load finishes without holding its task open for JDT.
    expect(store.getState().isLoading).toBe(false);
    await until(() => preparedListeners.length === 1);
    expect(entrypointChecks).toEqual([]);

    preparedListeners[0]();
    await entrypointsChecked;
    expect(entrypointChecks).toEqual([ENTRYPOINTS]);
    expect(store.getState().diagnostics).toEqual([STALE]);
  });

  test("loading another project stops waiting for the previous one", async () => {
    const { store, entrypointChecks, preparedListeners, stoppedWaiting, until } = harness({
      discoveries: [{ kind: "pending" }],
    });
    await store.getState().actions.loadProject(ROOT);
    await until(() => preparedListeners.length === 1);
    await store.getState().actions.loadProject("C:/other");
    expect(stoppedWaiting()).toBeGreaterThanOrEqual(1);
    // A late notification for the first project must not compare its entries.
    preparedListeners[0]();
    await Promise.resolve();
    expect(entrypointChecks).toEqual([]);
  });

  test("a reload cancels a check whose JDT answer is still in flight", async () => {
    // Event order: the first load asks JDT, a same-project reload cancels that
    // check and registers its own wait, then JDT answers the first request.
    let answerFirst!: (discovery: JavaEntrypointDiscovery) => void;
    const firstAnswer = new Promise<JavaEntrypointDiscovery>((resolve) => {
      answerFirst = resolve;
    });
    const { store, discoverCalls, preparedListeners, stoppedWaiting, until } = harness({
      discoveries: [firstAnswer, { kind: "pending" }],
    });
    await store.getState().actions.loadProject(ROOT);
    await until(() => discoverCalls.length === 1);
    await store.getState().actions.loadProject(ROOT);
    await until(() => preparedListeners.length === 1);
    expect(discoverCalls).toHaveLength(2);

    answerFirst({ kind: "pending" });
    await firstAnswer;
    // Let the first check's continuation run; it must stop at the cancellation.
    for (let turn = 0; turn < 5; turn += 1) await Promise.resolve();
    // The cancelled check must not register a second wait nor replace the
    // current one, which would leave a subscription nobody can cancel.
    expect(preparedListeners).toHaveLength(1);
    expect(stoppedWaiting()).toBe(0);
  });

  test("skips projects without Java configurations", async () => {
    const { store, discoverCalls } = harness({
      provider: "npm.script",
      discoveries: [{ kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.loadProject(ROOT);
    await Promise.resolve();
    expect(discoverCalls).toEqual([]);
  });
});
