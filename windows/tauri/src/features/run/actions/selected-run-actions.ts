import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { create } from "zustand";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { stopOwnedDebugSession } from "@/features/debugger/services/debug-session-actions";
import type { DebugSession } from "@/features/debugger/types/debugger.types";
import { startMavenModuleDebug } from "@/features/maven/services/maven-module-debug";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { ensureRunProcessListeners } from "../hooks/use-run-process-events";
import { useRunStore } from "../stores/run.store";
import { PRIMARY_SESSION_ID, type RunConfiguration } from "../types/run.types";
import {
  blockingToolchainDiagnosticForConfiguration,
  workspaceRelativePath,
} from "../utils/run-configuration";

type RunState = ReturnType<typeof useRunStore.getState>;
type Operation = { configurationId: string; mode: "run" | "debug"; controller: AbortController };
// Transient UI orchestration only. Run/JDT/DAP retain process and semantic ownership.
export const useRunControlState = create<{
  operations: Record<string, Operation | undefined>;
  errors: Record<string, string | undefined>;
}>(() => ({ operations: {}, errors: {} }));

export function selectedRunExecution(state: RunState, configurationId: string | null) {
  const session = state.sessions.find((entry) => entry.configurationId === configurationId);
  if (session)
    return {
      sessionId: session.id,
      executionId: session.executionId,
      running: session.isRunning,
      preparing: !!session.isPreparing,
    };
  const ownsPrimary = !!configurationId && state.primaryConfigurationId === configurationId;
  return {
    sessionId: PRIMARY_SESSION_ID,
    executionId: ownsPrimary ? (state.primaryExecutionId ?? undefined) : undefined,
    running: ownsPrimary && state.primaryRunning,
    preparing: ownsPrimary && state.primaryPreparing,
  };
}

export function ownsSelectedDebug(
  session: DebugSession | null,
  workspaceId: string,
  configurationId: string | null,
) {
  return (
    !!session &&
    session.status !== "idle" &&
    session.javaRun?.workspaceId === workspaceId &&
    session.configId === configurationId
  );
}

export function canDebugConfiguration(configuration: RunConfiguration | null): boolean {
  return (
    !!configuration &&
    !configuration.disabled &&
    (configuration.debugAdapter === "jdwp" || configuration.provider === "java.main") &&
    !!configuration.sourcePath &&
    ["application", "service"].includes(configuration.execution)
  );
}

function target() {
  const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const store = useRunStore.getStore(workspaceId);
  const state = store.getState();
  const root = useFileSystemStore.getStore(workspaceId).getState().rootFolderPath;
  const configuration = state.configurations.find(
    (entry) => entry.id === state.selectedConfigurationId,
  );
  if (!root || root !== state.root || !configuration) return null;
  return { workspaceId, root, store, configuration };
}
function reportError(workspaceId: string, error?: unknown) {
  useRunControlState.setState((state) => ({
    errors: {
      ...state.errors,
      [workspaceId]:
        error === undefined ? undefined : error instanceof Error ? error.message : String(error),
    },
  }));
}

/** Toolbar, command palette, menus and preset shortcuts enter the same selected-config workflow. */
export async function startSelectedRunConfiguration(mode: "run" | "debug" = "run"): Promise<void> {
  const owned = target();
  if (!owned) return;
  const { workspaceId, root, store, configuration } = owned;
  if (useRunControlState.getState().operations[workspaceId]) return;
  const state = store.getState();
  if (
    state.isLoading ||
    state.isGenerating ||
    configuration.disabled ||
    configuration.execution === "group"
  )
    return;
  const blocked = blockingToolchainDiagnosticForConfiguration(state.diagnostics, configuration.id);
  if (blocked) {
    reportError(workspaceId, blocked.message);
    return;
  }
  if (mode === "debug" && !canDebugConfiguration(configuration)) {
    reportError(
      workspaceId,
      "Choose a recognized Java or Spring Boot main configuration to debug.",
    );
    return;
  }
  const buffers = useBufferStore.getStore(workspaceId).getState();
  const file = buffers.buffers.find((buffer) => buffer.id === buffers.activeBufferId);
  const currentFile =
    file?.type === "editor" && !file.isVirtual ? workspaceRelativePath(root, file.path) : undefined;
  if (configuration.provider === "java.current-file" && !currentFile) return;
  const controller = new AbortController();
  const operation = { configurationId: configuration.id, mode, controller };
  useRunControlState.setState((current) => ({
    operations: { ...current.operations, [workspaceId]: operation },
  }));
  reportError(workspaceId);
  const isCurrent = () =>
    !controller.signal.aborted &&
    workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId &&
    store.getState().root === root;
  try {
    const debug = useDebuggerStore.getState().activeSession;
    if (ownsSelectedDebug(debug, workspaceId, configuration.id))
      await stopOwnedDebugSession(debug!);
    else if (mode === "debug" && debug && debug.status !== "idle")
      throw new Error("Stop the other active debug session before debugging this configuration.");
    if (!isCurrent()) return;
    await ensureRunProcessListeners();
    if (!isCurrent()) return;
    if (mode === "debug") {
      // An explicit Debug action must reveal its feature panel even on the
      // shipped default profile where the optional debugger UI is disabled.
      const settings = useSettingsStore.getState();
      if (!settings.settings.coreFeatures.debugger) {
        await settings.actions.updateSetting("coreFeatures", {
          ...settings.settings.coreFeatures,
          debugger: true,
        });
      }
      if (!isCurrent()) return;
    }
    const ui = useUIState.getStore(workspaceId).getState();
    ui.setBottomPaneActiveTab(mode === "debug" ? "debugger" : "run");
    ui.setIsBottomPaneVisible(true);
    if (mode === "debug") {
      await startMavenModuleDebug(
        { workspaceId, root },
        configuration,
        `${root}/${configuration.sourcePath}`,
        undefined,
        controller.signal,
      );
    } else {
      // The existing Run owner reserves a new execution and stops the previous slot before launch.
      await store.getState().actions.runConfiguration(configuration.id, currentFile);
    }
  } catch (error) {
    if (isCurrent()) reportError(workspaceId, error);
  } finally {
    if (useRunControlState.getState().operations[workspaceId] === operation) {
      useRunControlState.setState((current) => ({
        operations: { ...current.operations, [workspaceId]: undefined },
      }));
    }
  }
}

export async function stopSelectedRunConfiguration(): Promise<void> {
  const owned = target();
  if (!owned) return;
  const { workspaceId, store, configuration } = owned;
  const operation = useRunControlState.getState().operations[workspaceId];
  if (operation?.configurationId === configuration.id) operation.controller.abort();
  const execution = selectedRunExecution(store.getState(), configuration.id);
  const debug = useDebuggerStore.getState().activeSession;
  try {
    if (ownsSelectedDebug(debug, workspaceId, configuration.id))
      await stopOwnedDebugSession(debug!);
    if (execution.running || execution.preparing) {
      await store.getState().actions.stop(execution.sessionId, execution.executionId);
    }
  } catch (error) {
    reportError(workspaceId, error);
  }
}
