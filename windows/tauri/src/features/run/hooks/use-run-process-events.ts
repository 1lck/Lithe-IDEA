import { extensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { declarativePluginProcessOwner } from "@/features/plugins/declarative-plugin-process-owner";
import type { UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { releaseRunSessionWorkspace, runStoreForSession } from "../stores/run.store";
type RunState = ReturnType<ReturnType<typeof runStoreForSession>["getState"]>;

interface RunOutputEvent {
  sessionId: string;
  executionId?: string | null;
  chunk: string;
}

interface RunExitEvent {
  sessionId: string;
  executionId?: string | null;
  exitCode: number;
}

let outputUnlisten: UnlistenFn | undefined;
let exitUnlisten: UnlistenFn | undefined;

let installing: Promise<void> | undefined;

function executionFor(state: RunState, sessionId: string): string | undefined {
  return (sessionId === "primary" ? state.primaryExecutionId : state.sessions?.find(session => session.id === sessionId)?.executionId) ?? undefined;
}
function ownsEvent(state: RunState, event: { sessionId: string; executionId?: string | null }): boolean {
  const expected = executionFor(state, event.sessionId);
  return expected ? expected === event.executionId : !event.executionId || event.executionId === event.sessionId;
}

/** Toolbar and Run pane can mount together; both share the same in-flight setup. */
export function ensureRunProcessListeners(): Promise<void> {
  if (!installing)
    installing = installRunProcessListeners().finally(() => {
      installing = undefined;
    });
  return installing;
}

async function installRunProcessListeners(): Promise<void> {
  const currentWindow = getCurrentWebviewWindow();
  if (!outputUnlisten) {
    outputUnlisten = await currentWindow.listen<RunOutputEvent>("run-output", (event) => {
      const state = runStoreForSession(event.payload.sessionId).getState();
      if (ownsEvent(state, event.payload)) state.actions.appendOutput(event.payload.sessionId, event.payload.chunk);
    });
  }
  if (!exitUnlisten) {
    exitUnlisten = await currentWindow.listen<RunExitEvent>("run-exit", (event) => {
      const sessionId = event.payload.sessionId;
      const store = runStoreForSession(sessionId), state = store.getState();
      if (!ownsEvent(state, event.payload)) return;
      const executionId = executionFor(state, sessionId);
      state.actions.finishProcess(sessionId, event.payload.exitCode);
      if (executionFor(store.getState(), sessionId) === executionId) releaseRunSessionWorkspace(sessionId);
      extensionProcessOwner.finished(sessionId);
      declarativePluginProcessOwner.finished(event.payload.executionId ?? sessionId);
    });
  }
}
