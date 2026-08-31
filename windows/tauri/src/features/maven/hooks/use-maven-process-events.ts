import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { mavenStoreForSession, releaseMavenSessionWorkspace } from "../stores/maven.store";

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

export async function ensureMavenProcessListeners(): Promise<void> {
  if (!outputUnlisten) {
    outputUnlisten = await listen<RunOutputEvent>("run-output", (event) => {
      if (!event.payload.sessionId.startsWith("maven:")) return;
      mavenStoreForSession(event.payload.sessionId)
        .getState()
        .actions.appendOutput(event.payload.sessionId, event.payload.chunk);
    });
  }
  if (!exitUnlisten) {
    exitUnlisten = await listen<RunExitEvent>("run-exit", (event) => {
      const sessionId = event.payload.sessionId;
      if (!sessionId.startsWith("maven:")) return;
      mavenStoreForSession(sessionId)
        .getState()
        .actions.finishProcess(sessionId, event.payload.exitCode);
      releaseMavenSessionWorkspace(sessionId);
    });
  }
}
