import { invoke } from "@/platform/tauri-core";
import { startupFeedbackStore } from "./startup-feedback.store";

let completed = false;

/**
 * Closes the startup splash and shows the workbench.
 *
 * The splash window and the workbench both request the handover, so the
 * command has to stay idempotent.
 */
export async function completeStartup(): Promise<void> {
  if (completed) return;
  completed = true;

  try {
    await invoke("complete_startup");
  } catch (error) {
    console.warn("Failed to complete the startup sequence:", error);
  }
}

/**
 * Completes the startup once the workbench reports readiness.
 *
 * The splash window fades out on its own when it receives the readiness
 * event. This path exists for the case where the splash window is missing or
 * failed to load: the workbench must not stay invisible in that case.
 */
export function armMainWindowReveal(): () => void {
  const revealIfNeeded = (state: { visible: boolean; enabled: boolean; outcome: string }) => {
    if (state.outcome !== "ready" && state.outcome !== "failed") {
      return;
    }
    window.setTimeout(() => {
      void completeStartup();
    }, 600);
  };

  revealIfNeeded(startupFeedbackStore.getState());
  return startupFeedbackStore.subscribe(revealIfNeeded);
}
