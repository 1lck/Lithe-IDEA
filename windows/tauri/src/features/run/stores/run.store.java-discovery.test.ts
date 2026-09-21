import { describe, expect, test } from "bun:test";
import type { JavaEntrypoints } from "@/platform/lsp-core-adapter";
import type { JavaEntrypointDiscovery } from "../services/java-entrypoint-discovery";
import type { CoreGenerateResult, RunConfiguration } from "../types/run.types";

const { createRunStore } = await import("./run.store");

const ROOT = "C:/work";
const ENTRYPOINTS: JavaEntrypoints = {
  schemaVersion: 1,
  entries: [{ sourcePath: "src/main/java/demo/StaticNoArgs.java", mainClass: "demo.StaticNoArgs" }],
  diagnostics: [],
};

function javaConfiguration(): RunConfiguration {
  return { id: "java-main:demo.StaticNoArgs", provider: "java.main" } as RunConfiguration;
}

/** A store whose host and Core calls are recorded instead of executed. */
function harness(options: {
  javaSources?: string[];
  discoveries: JavaEntrypointDiscovery[];
  discover?: () => Promise<JavaEntrypointDiscovery>;
  resolvedJavaEntries?: boolean;
}) {
  const generateCalls: Array<JavaEntrypoints | undefined> = [];
  const preparedListeners: Array<() => void> = [];
  let stoppedWaiting = 0;
  const discoveries = [...options.discoveries];
  const store = createRunStore("workspace-1", {
    listJavaSources: async () => options.javaSources ?? ["src/main/java/demo/StaticNoArgs.java"],
    discoverJavaEntrypoints:
      options.discover ?? (async () => discoveries.shift() ?? { kind: "pending" }),
    whenJavaProjectPrepared: (_root, listener) => {
      preparedListeners.push(listener);
      return () => {
        stoppedWaiting += 1;
      };
    },
    generateRunConfiguration: async (_root, _paths, _modules, javaEntrypoints) => {
      generateCalls.push(javaEntrypoints);
      return {
        generated: {},
        toolchainRequirements: {},
        entryCount: javaEntrypoints ? javaEntrypoints.entries.length : 0,
      } satisfies CoreGenerateResult;
    },
    writeGeneratedRunDocuments: async () => {},
    resolveConfigurations: async () =>
      ({
        configurations: options.resolvedJavaEntries === false ? [] : [javaConfiguration()],
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
    generateCalls,
    preparedListeners,
    stoppedWaiting: () => stoppedWaiting,
  };
}

describe("Java entry-point discovery in the Run list", () => {
  test("generates from JDT's answer when the project is prepared", async () => {
    const { store, generateCalls, preparedListeners } = harness({
      discoveries: [{ kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.generate(ROOT);
    expect(generateCalls).toEqual([ENTRYPOINTS]);
    expect(store.getState().javaDiscovery).toBe("ready");
    expect(preparedListeners).toHaveLength(0);
  });

  test("keeps the previous entries while the Java service prepares, then refreshes", async () => {
    const { store, generateCalls, preparedListeners } = harness({
      discoveries: [{ kind: "pending" }, { kind: "discovered", entrypoints: ENTRYPOINTS }],
    });
    await store.getState().actions.generate(ROOT);
    // Omitting the answer tells Core to carry the previous Java entries over.
    expect(generateCalls).toEqual([undefined]);
    expect(store.getState().javaDiscovery).toBe("stale");
    expect(preparedListeners).toHaveLength(1);

    // The refresh starts itself once the project is prepared.
    const refreshed = new Promise<void>((resolve) => {
      const unsubscribe = store.subscribe((state) => {
        if (state.javaDiscovery !== "ready" || state.isGenerating) return;
        unsubscribe();
        resolve();
      });
    });
    preparedListeners[0]();
    await refreshed;
    expect(generateCalls).toEqual([undefined, ENTRYPOINTS]);
  });

  test("reports loading when there is no previous answer to show", async () => {
    const { store } = harness({ discoveries: [{ kind: "pending" }], resolvedJavaEntries: false });
    await store.getState().actions.generate(ROOT);
    expect(store.getState().javaDiscovery).toBe("loading");
  });

  test("a failed refresh keeps the list and explains why", async () => {
    const { store, generateCalls } = harness({
      discoveries: [{ kind: "failed", message: "The Java language service failed." }],
    });
    await store.getState().actions.generate(ROOT);
    expect(generateCalls).toEqual([undefined]);
    expect(store.getState().configurations).toHaveLength(1);
    expect(store.getState().javaDiscovery).toBe("failed");
    expect(store.getState().javaDiscoveryMessage).toBe("The Java language service failed.");
  });

  test("a project without Java sources never asks the Java service", async () => {
    const { store, generateCalls, preparedListeners } = harness({
      javaSources: [],
      discoveries: [{ kind: "failed", message: "must not be asked" }],
    });
    await store.getState().actions.generate(ROOT);
    expect(generateCalls).toEqual([undefined]);
    expect(store.getState().javaDiscovery).toBe("idle");
    expect(preparedListeners).toHaveLength(0);
  });

  test("a newer generation replaces the pending refresh", async () => {
    const { store, preparedListeners, stoppedWaiting } = harness({
      discoveries: [{ kind: "pending" }, { kind: "pending" }],
    });
    await store.getState().actions.generate(ROOT);
    await store.getState().actions.generate(ROOT);
    expect(preparedListeners).toHaveLength(2);
    expect(stoppedWaiting()).toBe(1);
  });

  test("a superseded JDT result cannot overwrite a newer generation", async () => {
    let discoveryCall = 0;
    let releaseFirstDiscovery: ((result: JavaEntrypointDiscovery) => void) | undefined;
    let signalFirstDiscovery: (() => void) | undefined;
    const firstDiscoveryStarted = new Promise<void>((resolve) => {
      signalFirstDiscovery = resolve;
    });
    const firstDiscovery = new Promise<JavaEntrypointDiscovery>((resolve) => {
      releaseFirstDiscovery = resolve;
    });
    const { store, generateCalls } = harness({
      discoveries: [],
      discover: async () => {
        discoveryCall += 1;
        if (discoveryCall === 1) {
          signalFirstDiscovery?.();
          return firstDiscovery;
        }
        return { kind: "discovered", entrypoints: ENTRYPOINTS };
      },
    });

    const superseded = store.getState().actions.generate(ROOT);
    await firstDiscoveryStarted;
    await store.getState().actions.generate(ROOT);
    releaseFirstDiscovery?.({ kind: "failed", message: "stale failure" });
    await superseded;

    expect(generateCalls).toEqual([ENTRYPOINTS]);
    expect(store.getState().javaDiscovery).toBe("ready");
    expect(store.getState().javaDiscoveryMessage).toBeNull();
  });
});
