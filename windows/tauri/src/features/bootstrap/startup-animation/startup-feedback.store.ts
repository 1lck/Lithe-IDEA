import { createStore } from "zustand/vanilla";
import { useStore } from "zustand";
import { invoke } from "@/platform/tauri-core";
import {
  StartupFeedbackController,
  systemStartupFeedbackClock,
  type StartupFeedbackSnapshot,
} from "./startup-feedback-controller";
import { resolveStartupAnimationEnabled } from "./startup-animation-bootstrap";
import type { StartupFailureCode, StartupStageId } from "./startup-stages";

const INITIAL_SNAPSHOT: StartupFeedbackSnapshot = {
  outcome: "idle",
  stage: "preparing",
  visible: false,
  fading: false,
  enabled: true,
  failureCode: null,
  failureMessage: null,
};

export const startupFeedbackStore = createStore<StartupFeedbackSnapshot>(() => INITIAL_SNAPSHOT);

export const startupFeedbackController = new StartupFeedbackController(
  systemStartupFeedbackClock,
  (snapshot) => {
    startupFeedbackStore.setState(snapshot);
  },
);

/**
 * Starts the startup feedback for the main window. The animation switch is
 * resolved from the first-frame cache so the decision does not wait for the
 * settings store.
 */
export function beginStartupFeedback(): void {
  startupFeedbackController.setEnabled(resolveStartupAnimationEnabled());
  startupFeedbackController.start();
}

/** Reports the phase the product is currently working on. */
export function reportStartupStage(stage: StartupStageId): void {
  startupFeedbackController.setStage(stage);
  void invoke("publish_startup_stage", { stage }).catch(() => {
    // The splash window is optional, so a failed broadcast must not break the
    // startup of the workbench.
  });
}

/** Reports that the workbench is usable. */
export function reportStartupReady(): void {
  startupFeedbackController.markReady();
  void invoke("publish_startup_ready").catch(() => {
    // The splash window closes itself when the workbench reports readiness.
  });
}

/** Reports that the startup failed and keeps the reason visible. */
export function reportStartupFailed(
  failureCode: StartupFailureCode,
  failureMessage: string | null = null,
): void {
  startupFeedbackController.markFailed(failureCode, failureMessage);
  void invoke("publish_startup_failed", { code: failureCode, message: failureMessage }).catch(
    () => {
      // The splash window is optional, so a failed broadcast must not break the
      // startup of the workbench.
    },
  );
}

/** Dismisses the failure state after the user asked to continue. */
export function dismissStartupFeedback(): void {
  startupFeedbackController.dismiss();
}

export function useStartupFeedback(): StartupFeedbackSnapshot {
  return useStore(startupFeedbackStore);
}
