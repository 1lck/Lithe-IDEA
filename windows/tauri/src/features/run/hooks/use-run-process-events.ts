import type { UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { releaseRunSessionWorkspace, runStoreForSession } from "../stores/run.store";

interface RunOutputEvent {
  sessionId: string;
  chunk: string;
}

interface RunExitEvent {
  sessionId: string;
  exitCode: number;
}

let outputUnlisten: UnlistenFn | undefined;
let exitUnlisten: UnlistenFn | undefined;

export async function ensureRunProcessListeners(): Promise<void> {
  const currentWindow = getCurrentWebviewWindow();
  if (!outputUnlisten) {
    outputUnlisten = await currentWindow.listen<RunOutputEvent>("run-output", (event) => {
      runStoreForSession(event.payload.sessionId)
        .getState()
        .actions.appendOutput(event.payload.sessionId, event.payload.chunk);
    });
  }
  if (!exitUnlisten) {
    exitUnlisten = await currentWindow.listen<RunExitEvent>("run-exit", (event) => {
      const sessionId = event.payload.sessionId;
      runStoreForSession(sessionId).getState().actions.finishProcess(sessionId, event.payload.exitCode);
      releaseRunSessionWorkspace(sessionId);
    });
  }
}
