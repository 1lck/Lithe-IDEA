import { expect, mock, test } from "bun:test";
import { EMPTY_GLOBAL_TOOLCHAIN } from "../types/run.types";
import type { ResolvedRunProject } from "../services/resolve-run-project";
import { createRunStore } from "./run.store";

function project(message: string): ResolvedRunProject {
  return {
    configurations: [],
    diagnostics: message ? [{ code: "missingToolchain", message }] : [],
    defaultConfigurationId: null,
    discoveredJava: [],
    discoveredMaven: [],
    discoveredRuntimes: [],
    globalToolchain: EMPTY_GLOBAL_TOOLCHAIN,
    effectiveRuntimeExecutablePaths: {},
  };
}

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
