import { emitTo } from "@tauri-apps/api/event";
import { getAllWebviewWindows } from "@tauri-apps/api/webviewWindow";

export const REQUEST_WINDOW_CLOSE_EVENT = "lithe:request-window-close";

/** Asks one window's close guard to close it after its own checks. */
export const APPLICATION_QUIT_EVENT = "menu_quit_app";

export function requestWindowClose() {
  window.dispatchEvent(new CustomEvent(REQUEST_WINDOW_CLOSE_EVENT));
}

/**
 * Quits Lithe by asking every window to close through its close guard, so
 * unsaved files and running services are asked about first. Lithe exits once
 * the last window has closed; exiting directly would skip both questions.
 */
export async function requestApplicationQuit() {
  const windows = await getAllWebviewWindows();
  await Promise.all(windows.map((window) => emitTo(window.label, APPLICATION_QUIT_EVENT)));
}
