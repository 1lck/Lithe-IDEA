import { listen, type UnlistenFn } from "@tauri-apps/api/event";
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
  if (!outputUnlisten) {
    outputUnlisten = await listen<RunOutputEvent>("run-output", (event) => {
      runStoreForSession(event.payload.sessionId)
        .getState()
        .actions.appendOutput(event.payload.sessionId, event.payload.chunk);
    });
  }
  if (!exitUnlisten) {
    exitUnlisten = await listen<RunExitEvent>("run-exit", (event) => {
      const sessionId = event.payload.sessionId;
      runStoreForSession(sessionId).getState().actions.finishProcess(sessionId, event.payload.exitCode);
      releaseRunSessionWorkspace(sessionId);
    });
  }
}
