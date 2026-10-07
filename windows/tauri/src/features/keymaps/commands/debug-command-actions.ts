import {
  buildDebugCommand,
  createGeneratedDebugConfig,
} from "@/features/debugger/utils/debugger-command";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { editorAPI } from "@/features/editor/extensions/api";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";

function openDebuggerPane() {
  const state = useUIState.getState();
  state.setBottomPaneActiveTab("debugger");
  state.setIsBottomPaneVisible(true);
}

function getActiveDebugFile() {
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find(
    (buffer) => buffer.id === bufferStore.activeBufferId,
  );
  if (!activeBuffer || activeBuffer.type !== "editor" || activeBuffer.isVirtual) return null;

  return {
    path: activeBuffer.path,
    name: activeBuffer.name,
    language: activeBuffer.language,
  };
}

export function toggleDebuggerPane() {
  const state = useUIState.getState();
  if (state.isBottomPaneVisible && state.bottomPaneActiveTab === "debugger") {
    state.setIsBottomPaneVisible(false);
  } else {
    openDebuggerPane();
  }
}

export function toggleActiveBreakpoint() {
  const activeFile = getActiveDebugFile();
  if (!activeFile) return;

  const line = editorAPI.getCursorPosition().line;
  useDebuggerStore.getState().actions.toggleBreakpoint(activeFile.path, line);
}

export async function startGeneratedDebugSession() {
  const { useRunStore } = await import("@/features/run/stores/run.store");
  const run = useRunStore.getState();
  const selected = run.configurations.find((entry) => entry.id === run.selectedConfigurationId);
  if (
    run.root &&
    selected &&
    (selected.debugAdapter === "jdwp" ||
      selected.provider.startsWith("java.") ||
      selected.provider.startsWith("spring-boot."))
  ) {
    const { startSelectedRunConfiguration } =
      await import("@/features/run/actions/selected-run-actions");
    await startSelectedRunConfiguration("debug");
    return;
  }

  const rootFolderPath = useProjectStore.getState().rootFolderPath;
  const activeFile = getActiveDebugFile();
  const config = createGeneratedDebugConfig(activeFile, rootFolderPath);
  const command = buildDebugCommand(config);
  if (!command.trim()) {
    openDebuggerPane();
    return;
  }

  window.dispatchEvent(
    new CustomEvent("create-terminal-with-command", {
      detail: {
        name: config.name,
        command,
        workingDirectory: config.cwd || rootFolderPath || undefined,
      },
    }),
  );

  useDebuggerStore.getState().actions.startSession({
    id: `debug_${Date.now()}`,
    name: config.name,
    configId: config.id,
    command,
    cwd: config.cwd,
    startedAt: Date.now(),
    status: "running",
  });
}

export async function stopDebugSession() {
  const session = useDebuggerStore.getState().activeSession;
  if (session?.adapterSession) {
    const { stopOwnedDebugSession } =
      await import("@/features/debugger/services/debug-session-actions");
    await stopOwnedDebugSession(session);
    return;
  }
  const { stopSelectedRunConfiguration } =
    await import("@/features/run/actions/selected-run-actions");
  await stopSelectedRunConfiguration();
  if (!session || session.status === "idle") return;
  window.dispatchEvent(new CustomEvent("close-active-terminal"));
  useDebuggerStore.getState().actions.stopSession();
}
