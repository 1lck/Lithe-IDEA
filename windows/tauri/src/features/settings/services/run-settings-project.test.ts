import { expect, test } from "bun:test";
import type { JavaEntrypointDiscovery } from "@/features/run/services/java-entrypoint-discovery";
import type { CoreGenerateResult } from "@/features/run/types/run.types";
import { createRunStore } from "@/features/run/stores/run.store";
import { ensureRunSettingsProject } from "./run-settings-project";

const ROOT = "C:/fixture/project";

/** A Run store whose JDT discovery stays pending until the test releases it. */
function harness() {
  const preparedListeners: Array<() => void> = [];
  const discoveries: JavaEntrypointDiscovery[] = [{ kind: "pending" }];
  let stoppedWaiting = 0;
  let inspections = 0;
  const store = createRunStore("workspace-settings", {
    listJavaSources: async () => ["src/main/java/demo/App.java"],
    discoverJavaEntrypoints: async () => discoveries.shift() ?? { kind: "pending" },
    whenJavaProjectPrepared: (_root, listener) => {
      preparedListeners.push(listener);
      return () => {
        stoppedWaiting += 1;
      };
    },
    generateRunConfiguration: async () =>
      ({ generated: {}, toolchainRequirements: {}, entryCount: 0 }) satisfies CoreGenerateResult,
    writeGeneratedRunDocuments: async () => {},
    inspectRunConfiguration: async () => {
      inspections += 1;
      return { status: "missing" };
    },
    resolveConfigurations: async () =>
      ({
        configurations: [],
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
    preparedListeners,
    stoppedWaiting: () => stoppedWaiting,
    inspections: () => inspections,
  };
}

test("opening Run settings keeps the pending JDT refresh of the same project", async () => {
  const { store, preparedListeners, stoppedWaiting, inspections } = harness();
  await store.getState().actions.generate(ROOT);
  expect(preparedListeners).toHaveLength(1);

  await ensureRunSettingsProject(store, ROOT);

  expect(stoppedWaiting()).toBe(0);
  expect(inspections()).toBe(0);
  expect(store.getState().root).toBe(ROOT);
});

test("opening Run settings loads a store that is not bound to the project", async () => {
  const { store, inspections } = harness();
  await ensureRunSettingsProject(store, ROOT);
  expect(inspections()).toBe(1);
  expect(store.getState().root).toBe(ROOT);
});
