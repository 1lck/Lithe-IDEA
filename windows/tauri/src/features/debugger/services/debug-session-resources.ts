import { frontendTrace } from "@/utils/frontend-trace";

type DebugSessionCleanup = () => void | Promise<void>;

const sessionCleanups = new Map<string, DebugSessionCleanup>();
const releases = new Map<string, Promise<void>>();

export function registerDebugSessionCleanup(sessionId: string, cleanup: DebugSessionCleanup): void {
  sessionCleanups.set(sessionId, cleanup);
}

export function releaseDebugSessionResources(sessionId: string): Promise<void> {
  const pending = releases.get(sessionId);
  if (pending) return pending;
  const cleanup = sessionCleanups.get(sessionId);
  if (!cleanup) return Promise.resolve();
  sessionCleanups.delete(sessionId);
  // Session-ended events and explicit Stop/Restart must await the same cleanup,
  // not merely observe that another caller removed the registration.
  let complete!: () => void;
  const operation = new Promise<void>((resolve) => {
    complete = resolve;
  });
  releases.set(sessionId, operation);
  const release = async () => {
    try {
      await cleanup();
    } catch (error) {
      frontendTrace("error", "debug.session", "Failed to release debug session resources", {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      releases.delete(sessionId);
      complete();
    }
  };
  // Preserve the existing synchronous reservation/stop boundary before yielding.
  void release();
  return operation;
}
