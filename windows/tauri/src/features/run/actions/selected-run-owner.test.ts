import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as events from "../hooks/use-run-process-events";
import { createRunStore, useRunStore, type RunStoreDependencies } from "../stores/run.store";
import { mapCoreConfiguration } from "../utils/run-configuration";
import {
  startSelectedRunConfiguration,
  stopSelectedRunConfiguration,
  useRunControlState,
} from "./selected-run-actions";

// Keep the actual Run owner; only native/preparation dependencies and event setup
// are controlled. In particular, no test manually fabricates a preparing session.
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
const configuration = {
  ...mapCoreConfiguration({
    id: "boot",
    name: "Boot",
    provider: "spring-boot.main",
    execution: "service",
  }),
  sourcePath: "src/Boot.java",
  toolchains: { java: "project-jdk", maven: "project-maven" },
};
const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
type Stage = "stop" | "save" | "context";
let pauseAt: Stage | undefined;
let blocked: boolean;
let entered: ReturnType<typeof deferred<void>>;
let gate: ReturnType<typeof deferred<void>>;
let store: ReturnType<typeof createRunStore>;
let dependencies: RunStoreDependencies;
let start: ReturnType<typeof mock<RunStoreDependencies["startRunProcess"]>>;
let stop: ReturnType<typeof mock<RunStoreDependencies["stopRunProcess"]>>;
let preparation: ReturnType<typeof mock<RunStoreDependencies["prepareJavaRunLaunch"]>>;
let decisionEntered: ReturnType<typeof deferred<void>>;
let restore: () => void;
let tasks: Promise<unknown>[];
function track<T>(task: Promise<T>): Promise<T> {
  tasks.push(task);
  return task;
}
async function checkpoint(stage: Stage) {
  if (pauseAt !== stage || blocked) return;
  blocked = true;
  entered.resolve();
  await gate.promise;
}
beforeEach(() => {
  pauseAt = undefined;
  blocked = false;
  tasks = [];
  entered = deferred<void>();
  gate = deferred<void>();
  decisionEntered = deferred<void>();
  preparation = mock(async () => null);
  const previousFiles = useFileSystemStore.getState(),
    previousDebug = useDebuggerStore.getState();
  const previousUI = useUIState.getState(),
    previousControl = useRunControlState.getState();
  start = mock(async () => {});
  stop = mock(async (_sessionId: string, executionId?: string) => {
    if (!executionId) await checkpoint("stop");
  });
  dependencies = {
    createLaunchPlan: mock(async () => ({
      executable: { toolchain: "project-jdk" as const },
      arguments: ["Boot"],
      workingDirectory: ".",
    })),
    mavenLaunchContextForWorkspace: mock(async () => {
      await checkpoint("context");
      return null;
    }),
    resolveRunLaunch: mock(async () => ({
      executable: "/jdk/bin/java",
      workingDirectory: "/workspace",
      environment: {},
    })),
    executePreLaunchStep: mock(async () => ({ exitCode: 0, output: "" })),
    saveWorkspaceBeforeLaunch: mock(async () => {
      await checkpoint("save");
    }),
    seedMavenLocalConfiguration: () => {},
    startRunProcess: start,
    stopRunProcess: stop,
    prepareJavaRunLaunch: preparation,
    javaBuildFailurePolicyForWorkspace: () => "ask",
    presentJavaLaunchDecision: () => decisionEntered.resolve(),
  };
  store = createRunStore(workspaceId, dependencies);
  store.setState({
    root: "/workspace",
    status: "ready",
    configurations: [configuration],
    selectedConfigurationId: "boot",
    selectedSessionId: "unrelated",
    sessions: [],
    diagnostics: [],
    primaryConfigurationId: "unrelated",
    primaryExecutionId: "unrelated-execution",
    primaryRunning: true,
  });
  const owner = spyOn(useRunStore, "getStore").mockReturnValue(store);
  const listen = spyOn(events, "ensureRunProcessListeners").mockResolvedValue(undefined);
  useFileSystemStore.setState({ rootFolderPath: "/workspace" });
  useDebuggerStore.setState({ activeSession: null });
  useRunControlState.setState({ operations: {}, errors: {} });
  restore = () => {
    owner.mockRestore();
    listen.mockRestore();
    useFileSystemStore.setState(previousFiles, true);
    useDebuggerStore.setState(previousDebug, true);
    useUIState.setState(previousUI, true);
    useRunControlState.setState(previousControl, true);
  };
});
afterEach(async () => {
  try {
    useRunControlState.getState().operations[workspaceId]?.controller.abort();
    await store.getState().actions.stop("boot");
    gate.resolve();
    await Promise.allSettled(tasks);
  } finally {
    restore();
  }
});
for (const stage of ["stop", "save", "context"] as const) {
  test(`first service Run is cancelled during ${stage}, before a session exists`, async () => {
    pauseAt = stage;
    const task = track(startSelectedRunConfiguration("run"));
    await entered.promise;
    expect(store.getState().sessions).toEqual([]);
    await stopSelectedRunConfiguration();
    gate.resolve();
    await task;
    expect(start).not.toHaveBeenCalled();
    expect(dependencies.prepareJavaRunLaunch).not.toHaveBeenCalled();
    expect(store.getState().sessions).toEqual([]);
    expect(store.getState().primaryRunning).toBe(true);
    expect(stop.mock.calls.every(([sessionId]) => sessionId === "boot")).toBe(true);
    expect(useRunControlState.getState().operations[workspaceId]).toBeUndefined();
  });
}
test("a stopped save-gated launch cannot revoke its replacement reservation", async () => {
  pauseAt = "save";
  const old = track(startSelectedRunConfiguration("run"));
  await entered.promise;
  const replacement = track(store.getState().actions.runConfigurationInstance("boot"));
  await stopSelectedRunConfiguration();
  gate.resolve();
  await old;
  const instance = await replacement;
  expect(instance).not.toBeNull();
  expect(start).toHaveBeenCalledTimes(1);
  expect(stop.mock.calls.some(([, id]) => id === instance?.executionId)).toBe(false);
  expect(store.getState().sessions[0]?.executionId).toBe(instance?.executionId);
  expect(store.getState().sessions[0]?.isRunning).toBe(true);
});
test("aborting an old context-gated operation cannot stop an already running replacement", async () => {
  pauseAt = "context";
  const old = track(startSelectedRunConfiguration("run"));
  await entered.promise;
  const controller = useRunControlState.getState().operations[workspaceId]!.controller;
  const instance = await track(store.getState().actions.runConfigurationInstance("boot"));
  controller.abort();
  gate.resolve();
  await old;
  expect(instance).not.toBeNull();
  expect(start).toHaveBeenCalledTimes(1);
  expect(stop.mock.calls.some(([, id]) => id === instance?.executionId)).toBe(false);
  expect(store.getState().sessions[0]?.executionId).toBe(instance?.executionId);
  expect(store.getState().sessions[0]?.isRunning).toBe(true);
});
test("an already-aborted request never reserves or stops a Run slot", async () => {
  const controller = new AbortController();
  controller.abort();
  const result = await track(
    store
      .getState()
      .actions.runConfigurationInstance("boot", undefined, undefined, controller.signal),
  );
  expect(result).toBeNull();
  expect(stop).not.toHaveBeenCalled();
  expect(start).not.toHaveBeenCalled();
});
test("uncancelled selected Run still launches once through the real owner", async () => {
  await track(startSelectedRunConfiguration("run"));
  expect(start).toHaveBeenCalledTimes(1);
  expect(store.getState().sessions[0]?.isRunning).toBe(true);
  expect(store.getState().primaryRunning).toBe(true);
});

test("an exact stale Stop cannot cancel a replacement's build decision", async () => {
  preparation.mockResolvedValue({
    kind: "buildFailed",
    target: { mainClass: "Boot", projectName: "app", classPaths: [], modulePaths: [] },
    failure: {
      code: "javaBuildCompilationErrors",
      message: "Compilation errors",
      report: {
        markerScope: "launchTarget",
        builderFailedEarlier: true,
        elapsedMilliseconds: 1,
        recovery: "rebuildJavaIndex",
      },
    },
  });
  const task = track(store.getState().actions.runConfigurationInstance("boot"));
  await decisionEntered.promise;
  const decision = store.getState().javaLaunchDecisions.boot;
  expect(decision).toBeDefined();
  await store.getState().actions.stop("boot", "retired-execution");
  expect(store.getState().javaLaunchDecisions.boot).toBe(decision);
  store.getState().actions.continueJavaLaunch("boot", decision.decisionId, false);
  expect(await task).not.toBeNull();
  expect(start).toHaveBeenCalledTimes(1);
});
test("the completed launch detaches its cancellation listener", async () => {
  const task = track(startSelectedRunConfiguration("run"));
  const controller = useRunControlState.getState().operations[workspaceId]!.controller;
  await task;
  const stops = stop.mock.calls.length;
  controller.abort();
  expect(stop.mock.calls).toHaveLength(stops);
  expect(store.getState().sessions[0]?.isRunning).toBe(true);
});

test("a late native start completion only cleans up the cancelled execution, not its replacement", async () => {
  start.mockImplementationOnce(async () => {
    entered.resolve();
    await gate.promise;
  });
  const old = track(startSelectedRunConfiguration("run"));
  await entered.promise;
  await stopSelectedRunConfiguration();
  const instance = await track(store.getState().actions.runConfigurationInstance("boot"));
  gate.resolve();
  await old;
  expect(instance).not.toBeNull();
  expect(start).toHaveBeenCalledTimes(2);
  expect(stop.mock.calls.some(([, id]) => id === instance?.executionId)).toBe(false);
  expect(store.getState().sessions[0]?.executionId).toBe(instance?.executionId);
  expect(store.getState().sessions[0]?.isRunning).toBe(true);
});
