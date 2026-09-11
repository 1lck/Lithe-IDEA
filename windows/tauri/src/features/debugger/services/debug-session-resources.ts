import { frontendTrace } from "@/utils/frontend-trace";

type DebugSessionCleanup = () => void | Promise<void>;

const sessionCleanups = new Map<string, DebugSessionCleanup>();

export function registerDebugSessionCleanup(sessionId: string, cleanup: DebugSessionCleanup): void {
  sessionCleanups.set(sessionId, cleanup);
}

export async function releaseDebugSessionResources(sessionId: string): Promise<void> {
  const cleanup = sessionCleanups.get(sessionId);
  if (!cleanup) return;
  sessionCleanups.delete(sessionId);
  try {
    await cleanup();
  } catch (error) {
    frontendTrace("error", "debug.session", "Failed to release debug session resources", {
      sessionId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
