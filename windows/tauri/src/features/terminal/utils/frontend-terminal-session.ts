import { invoke } from "@/platform/tauri-core";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";

interface FrontendTerminalSession {
  windowLabel: string;
  frontendSessionId: string;
}

let frontendTerminalSession: FrontendTerminalSession | null = null;
let frontendTerminalSessionReady: Promise<void> | null = null;

export function getFrontendTerminalSessionArgs() {
  if (!frontendTerminalSession) {
    frontendTerminalSession = {
      windowLabel: getCurrentWebviewWindow().label,
      frontendSessionId: crypto.randomUUID(),
    };
  }

  return frontendTerminalSession;
}

export function initializeFrontendTerminalSession(): Promise<void> {
  if (!frontendTerminalSessionReady) {
    const { windowLabel, frontendSessionId } = getFrontendTerminalSessionArgs();
    frontendTerminalSessionReady = invoke("begin_frontend_terminal_session", {
      windowLabel,
      sessionId: frontendSessionId,
    });
  }

  return frontendTerminalSessionReady;
}

/**
 * Waits until the backend accepted the frontend session.
 *
 * The backend only registers a terminal under an accepted session, so a
 * terminal created before the session exists is rejected. The first frame does
 * not wait for the session, therefore terminal creation has to.
 */
export async function ensureFrontendTerminalSessionReady(): Promise<void> {
  try {
    await initializeFrontendTerminalSession();
  } catch {
    // The backend reports the real reason when the terminal is created.
  }
}
