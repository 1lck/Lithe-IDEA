import { invoke } from "@/platform/tauri-core";
import { startupFeedbackStore } from "./startup-feedback.store";

let revealRequested = false;

/**
 * Reveals the main window.
 *
 * The window is created hidden so the user never sees the empty WebView
 * surface while the frontend boots. The shell reveals the window on a timer as
 * well, so a frontend failure cannot leave an invisible window behind.
 */
export async function revealMainWindow(): Promise<void> {
  if (revealRequested) return;
  revealRequested = true;

  try {
    await invoke("show_main_window", { focus: true });
  } catch (error) {
    console.warn("Failed to show the main window:", error);
  }
}

/**
 * Reveals the main window as soon as the startup feedback can explain the
 * wait.
 *
 * The window stays hidden while the animation is not on screen yet, so the
 * user never sees a blank surface. A startup that finished before the
 * animation threshold is revealed right away, and a disabled animation never
 * holds the window back.
 */
export function armMainWindowReveal(): () => void {
  const revealIfNeeded = (state: { visible: boolean; enabled: boolean; outcome: string }) => {
    if (!state.visible && state.enabled && state.outcome !== "ready" && state.outcome !== "failed") {
      return;
    }
    void revealMainWindow();
  };

  revealIfNeeded(startupFeedbackStore.getState());
  return startupFeedbackStore.subscribe(revealIfNeeded);
}
