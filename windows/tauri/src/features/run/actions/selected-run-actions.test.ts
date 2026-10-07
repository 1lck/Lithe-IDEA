import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as maven from "@/features/maven/services/maven-module-debug";
import * as debugActions from "@/features/debugger/services/debug-session-actions";
import * as events from "../hooks/use-run-process-events";
import { useRunStore } from "../stores/run.store";
import { mapCoreConfiguration } from "../utils/run-configuration";
import {
  startSelectedRunConfiguration,
  stopSelectedRunConfiguration,
  useRunControlState,
} from "./selected-run-actions";

const configuration = {
  ...mapCoreConfiguration({
    id: "boot",
    name: "Boot",
    provider: "spring-boot.main",
    execution: "service",
  }),
  debugAdapter: "jdwp",
  sourcePath: "src/Boot.java",
};
const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
let restore: () => void;
let launch: ReturnType<typeof spyOn<typeof maven, "startMavenModuleDebug">>;
let stopDebug: ReturnType<typeof spyOn<typeof debugActions, "stopOwnedDebugSession">>;
let run: ReturnType<
  typeof spyOn<ReturnType<typeof useRunStore.getState>["actions"], "runConfiguration">
>;
let stop: ReturnType<typeof spyOn<ReturnType<typeof useRunStore.getState>["actions"], "stop">>;
let listen: ReturnType<typeof spyOn<typeof events, "ensureRunProcessListeners">>;

beforeEach(() => {
  const previousRun = useRunStore.getState(),
    previousFiles = useFileSystemStore.getState();
  const previousDebug = useDebuggerStore.getState(),
    previousUI = useUIState.getState();
  const previousControl = useRunControlState.getState();
  const previousSettings = useSettingsStore.getState();
  useSettingsStore.setState({
    settings: {
      ...previousSettings.settings,
      coreFeatures: { ...previousSettings.settings.coreFeatures, debugger: true },
    },
  });
  launch = spyOn(maven, "startMavenModuleDebug").mockResolvedValue({
    kind: "started",
    sessionId: "dap",
    runSessionId: "boot",
  });
  stopDebug = spyOn(debugActions, "stopOwnedDebugSession").mockImplementation(async () => {
    useDebuggerStore.getState().actions.stopSession();
  });
  run = spyOn(previousRun.actions, "runConfiguration").mockResolvedValue("boot");
  stop = spyOn(previousRun.actions, "stop").mockResolvedValue(undefined);
  listen = spyOn(events, "ensureRunProcessListeners").mockResolvedValue(undefined);
  useFileSystemStore.setState({ rootFolderPath: "/workspace" });
  useRunStore.setState({
    root: "/workspace",
    status: "ready",
    configurations: [configuration],
    selectedConfigurationId: "boot",
    isLoading: false,
    isGenerating: false,
    diagnostics: [],
    sessions: [],
    primaryRunning: false,
    primaryPreparing: false,
  });
  useDebuggerStore.setState({ activeSession: null });
  useRunControlState.setState({ operations: {}, errors: {} });
  restore = () => {
    launch.mockRestore();
    stopDebug.mockRestore();
    run.mockRestore();
    stop.mockRestore();
    listen.mockRestore();
    useRunStore.setState(previousRun, true);
    useFileSystemStore.setState(previousFiles, true);
    useDebuggerStore.setState(previousDebug, true);
    useUIState.setState(previousUI, true);
    useRunControlState.setState(previousControl, true);
    useSettingsStore.setState(previousSettings, true);
  };
});
afterEach(() => restore());

function activeDebug(configId = "boot") {
  const session = {
    id: "dap",
    name: "Boot",
    configId,
    command: "tcp",
    status: "running" as const,
    startedAt: 1,
    adapterSession: true,
    javaRun: { workspaceId, sessionId: configId, executionId: "owned-execution" },
  };
  useDebuggerStore.setState({ activeSession: session });
  return session;
}

test("selected Run goes through the existing owner, not the focused background output slot", async () => {
  useRunStore.setState({ selectedSessionId: "other" });
  await startSelectedRunConfiguration("run");
  expect(run).toHaveBeenCalledWith("boot", undefined);
  expect(launch).not.toHaveBeenCalled();
});

test("selected Java Debug uses JDT/JDWP/DAP and its selected source, not the active file", async () => {
  await startSelectedRunConfiguration("debug");
  expect(launch).toHaveBeenCalledTimes(1);
  expect(launch.mock.calls[0]?.slice(0, 3)).toEqual([
    { workspaceId, root: "/workspace" },
    configuration,
    "/workspace/src/Boot.java",
  ]);
  expect(useUIState.getState().bottomPaneActiveTab).toBe("debugger");
});

test("redebug awaits the selected adapter cleanup before launching its replacement", async () => {
  const session = activeDebug();
  launch.mockImplementation(async () => {
    expect(stopDebug).toHaveBeenCalledWith(session);
    expect(useDebuggerStore.getState().activeSession?.status).toBe("idle");
    return { kind: "started", sessionId: "new-dap", runSessionId: "boot" };
  });
  await startSelectedRunConfiguration("debug");
  expect(launch).toHaveBeenCalledTimes(1);
});

test("another configuration's active debugger is never stopped or replaced", async () => {
  activeDebug("other");
  await startSelectedRunConfiguration("debug");
  expect(stopDebug).not.toHaveBeenCalled();
  expect(launch).not.toHaveBeenCalled();
  expect(useRunControlState.getState().errors[workspaceId]).toContain("other active debug session");
});

test("Stop captures the selected service's execution identity, never the focused other slot", async () => {
  useRunStore.setState({
    selectedSessionId: "other",
    sessions: [
      {
        id: "boot",
        configurationId: "boot",
        executionId: "boot-execution",
        title: "Boot",
        isRunning: true,
        output: "",
        exitCode: null,
      },
      {
        id: "other",
        configurationId: "other",
        executionId: "other-execution",
        title: "Other",
        isRunning: true,
        output: "",
        exitCode: null,
      },
    ],
  });
  await stopSelectedRunConfiguration();
  expect(stop).toHaveBeenCalledTimes(1);
  expect(stop).toHaveBeenCalledWith("boot", "boot-execution");
});

test("double Debug is serialized; Stop cancels preparation and releases its owned Run execution", async () => {
  let entered!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let signal: AbortSignal | undefined;
  launch.mockImplementation(async (_scope, _configuration, _file, _dependencies, cancellation) => {
    signal = cancellation;
    entered();
    await gate;
    return { kind: "stale" };
  });
  const pending = startSelectedRunConfiguration("debug");
  try {
    await started;
    await startSelectedRunConfiguration("debug");
    expect(launch).toHaveBeenCalledTimes(1);
    useRunStore.setState({
      sessions: [
        {
          id: "boot",
          configurationId: "boot",
          executionId: "preparing-execution",
          title: "Boot",
          isRunning: false,
          isPreparing: true,
          output: "",
          exitCode: null,
        },
      ],
    });
    await stopSelectedRunConfiguration();
    expect(signal?.aborted).toBe(true);
    expect(stop).toHaveBeenCalledWith("boot", "preparing-execution");
  } finally {
    release();
    await pending;
  }
  expect(useRunControlState.getState().operations[workspaceId]).toBeUndefined();
});

test("a root change while event setup is pending cannot launch into the replacement workspace", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  listen.mockReturnValue(gate);
  const pending = startSelectedRunConfiguration("run");
  try {
    useRunStore.setState({ root: "/replacement" });
  } finally {
    release();
    await pending;
  }
  expect(run).not.toHaveBeenCalled();
});

test("Stop ignores a primary execution belonging to a different configuration", async () => {
  useRunStore.setState({
    primaryConfigurationId: "other",
    primaryExecutionId: "other-execution",
    primaryRunning: true,
  });
  await stopSelectedRunConfiguration();
  expect(stop).not.toHaveBeenCalled();
});

test("recognized Java main configurations use the existing debug launch even without a legacy adapter label", async () => {
  useRunStore.setState({
    configurations: [
      {
        ...configuration,
        provider: "java.main",
        execution: "application",
        debugAdapter: undefined,
      },
    ],
  });
  await startSelectedRunConfiguration("debug");
  expect(launch).toHaveBeenCalledTimes(1);
});

test("an explicit Debug request enables its shipped-disabled feature panel before launch", async () => {
  const settings = useSettingsStore.getState();
  useSettingsStore.setState({
    settings: {
      ...settings.settings,
      coreFeatures: { ...settings.settings.coreFeatures, debugger: false },
    },
  });
  const enable = spyOn(settings.actions, "updateSetting").mockResolvedValue(undefined);
  try {
    await startSelectedRunConfiguration("debug");
    expect(enable).toHaveBeenCalledWith("coreFeatures", {
      ...settings.settings.coreFeatures,
      debugger: true,
    });
    expect(launch).toHaveBeenCalledTimes(1);
  } finally {
    enable.mockRestore();
  }
});
