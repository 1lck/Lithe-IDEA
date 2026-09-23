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
function harness(options: { provider?: string; discoveries: JavaEntrypointDiscovery[] }) {
  const discoverCalls: string[][] = [];
  const entrypointChecks: Array<JavaEntrypoints | undefined> = [];
  const preparedListeners: Array<() => void> = [];
  let stoppedWaiting = 0;
  const discoveries = [...options.discoveries];
  let checked!: () => void;
  const entrypointsChecked = new Promise<void>((resolve) => {
    checked = resolve;
  });
  const store = createRunStore("workspace-1", {
    discoverJavaEntrypoints: async (_scope, sources) => {
      discoverCalls.push(sources);
      return discoveries.shift() ?? { kind: "pending" };
    },
    whenJavaProjectPrepared: (_root, listener) => {
      preparedListeners.push(listener);
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
    const { store, entrypointChecks, entrypointsChecked, preparedListeners } = harness({
      discoveries: [{ kind: "pending" }, { kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.loadProject(ROOT);
    // The load finishes without holding its task open for JDT.
    expect(store.getState().isLoading).toBe(false);
    expect(entrypointChecks).toEqual([]);
    expect(preparedListeners).toHaveLength(1);

    preparedListeners[0]();
    await entrypointsChecked;
    expect(entrypointChecks).toEqual([ENTRYPOINTS]);
    expect(store.getState().diagnostics).toEqual([STALE]);
  });

  test("loading another project stops waiting for the previous one", async () => {
    const { store, entrypointChecks, preparedListeners, stoppedWaiting } = harness({
      discoveries: [{ kind: "pending" }],
    });
    await store.getState().actions.loadProject(ROOT);
    await store.getState().actions.loadProject("C:/other");
    expect(stoppedWaiting()).toBeGreaterThanOrEqual(1);
    // A late notification for the first project must not compare its entries.
    preparedListeners[0]();
    await Promise.resolve();
    expect(entrypointChecks).toEqual([]);
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
