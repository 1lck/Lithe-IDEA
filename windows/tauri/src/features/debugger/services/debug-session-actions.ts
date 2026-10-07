import { useDebuggerStore } from "../stores/debugger.store";
import type { DebugSession } from "../types/debugger.types";
import { sendDebugAdapterRequest, stopDebugAdapterSession } from "./debug-adapter-service";
import { releaseDebugSessionResources } from "./debug-session-resources";

const stopping = new Map<string, Promise<void>>();

/** One adapter + its registered Run execution; never whichever terminal happens to be focused. */
export function stopOwnedDebugSession(session: DebugSession): Promise<void> {
  const pending = stopping.get(session.id);
  if (pending) return pending;
  const operation = (async () => {
    try {
      if (session.adapterSession) await stopDebugAdapterSession(session.id);
    } finally {
      await releaseDebugSessionResources(session.id);
      if (useDebuggerStore.getState().activeSession?.id === session.id) {
        useDebuggerStore.getState().actions.stopSession();
      }
    }
  })().finally(() => stopping.delete(session.id));
  stopping.set(session.id, operation);
  return operation;
}

export async function sendActiveDebugThreadRequest(
  command: "continue" | "pause" | "next" | "stepIn" | "stepOut",
): Promise<void> {
  const state = useDebuggerStore.getState();
  const session = state.activeSession;
  const threadId = state.stoppedState?.threadId ?? state.threads[0]?.id;
  if (!session?.adapterSession || session.status === "idle" || threadId === undefined) return;
  if (command !== "pause" && session.status !== "paused") return;
  // Reserve the running state before sending: a fast adapter can report the
  // next stop before the native transport acknowledgement resolves.
  if (command !== "pause") state.actions.setSessionStatus("running");
  try {
    await sendDebugAdapterRequest(session.id, command, { threadId });
  } catch (error) {
    const current = useDebuggerStore.getState();
    if (
      current.activeSession?.id === session.id &&
      current.stoppedState === state.stoppedState &&
      current.activeSession.status === "running"
    ) {
      current.actions.setSessionStatus(session.status);
    }
    throw error;
  }
}
