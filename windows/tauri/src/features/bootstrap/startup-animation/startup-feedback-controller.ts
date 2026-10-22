import {
  STARTUP_FADE_OUT_DURATION_MS,
  STARTUP_MINIMUM_VISIBLE_DURATION_MS,
  type StartupFailureCode,
  type StartupStageId,
} from "./startup-stages";

export type StartupFeedbackOutcome = "idle" | "loading" | "ready" | "failed";

export interface StartupFeedbackSnapshot {
  outcome: StartupFeedbackOutcome;
  stage: StartupStageId;
  visible: boolean;
  fading: boolean;
  enabled: boolean;
  failureCode: StartupFailureCode | null;
  failureMessage: string | null;
}

/**
 * Time and timer source of the startup feedback.
 *
 * The controller never reads the wall clock on its own so a test can drive the
 * skip threshold, the fade-out, and the failure state with a deterministic
 * clock instead of real waiting.
 */
export interface StartupFeedbackClock {
  now: () => number;
  setTimer: (callback: () => void, delayMs: number) => number;
  clearTimer: (handle: number) => void;
}

export const systemStartupFeedbackClock: StartupFeedbackClock = {
  now: () => (typeof performance === "undefined" ? Date.now() : performance.now()),
  setTimer: (callback, delayMs) =>
    typeof window === "undefined" ? 0 : window.setTimeout(callback, delayMs),
  clearTimer: (handle) => {
    if (typeof window === "undefined") return;
    window.clearTimeout(handle);
  },
};

const INITIAL_SNAPSHOT: StartupFeedbackSnapshot = {
  outcome: "idle",
  stage: "preparing",
  visible: false,
  fading: false,
  enabled: true,
  failureCode: null,
  failureMessage: null,
};

/**
 * Drives the startup feedback state machine.
 *
 * The animation is a feedback layer only: it never delays the moment the
 * workbench becomes usable. A startup that finishes inside the minimum
 * visible duration is skipped entirely, a slow startup shows the current phase
 * until the workbench is ready, and a failed startup keeps the failure state on
 * screen until the user dismisses it.
 */
export class StartupFeedbackController {
  private readonly clock: StartupFeedbackClock;
  private readonly onChange: (snapshot: StartupFeedbackSnapshot) => void;
  private snapshot: StartupFeedbackSnapshot = INITIAL_SNAPSHOT;
  private startedAt: number | null = null;
  private revealTimer: number | null = null;
  private fadeOutTimer: number | null = null;
  private enabled = true;
  /**
   * A readiness report that arrived before the animation started.
   *
   * The workspace can finish loading before the window paints its first
   * frame, so the result must not be dropped just because it came early.
   */
  private readyReported = false;
  /** A failure report that arrived before the animation started. */
  private failureReported: { code: StartupFailureCode; message: string | null } | null = null;

  constructor(clock: StartupFeedbackClock, onChange: (snapshot: StartupFeedbackSnapshot) => void) {
    this.clock = clock;
    this.onChange = onChange;
  }

  getState(): StartupFeedbackSnapshot {
    return this.snapshot;
  }

  /**
   * Applies the user's startup animation switch. A disabled animation shows
   * nothing and never adds waiting time.
   */
  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    if (!enabled) {
      this.clearTimers();
      this.patch({ visible: false, fading: false, enabled });
      return;
    }
    this.patch({ enabled });
  }

  /** Starts the feedback and arms the reveal timer. */
  start(): void {
    if (!this.enabled) return;
    this.clearTimers();
    if (this.readyReported) {
      // The startup already finished, so the animation is skipped entirely.
      this.patch({ outcome: "ready", visible: false, fading: false });
      return;
    }
    if (this.failureReported) {
      this.patch({
        outcome: "loading",
        stage: "preparing",
        visible: false,
        fading: false,
        failureCode: null,
        failureMessage: null,
      });
      this.applyFailure(this.failureReported.code, this.failureReported.message);
      return;
    }
    this.startedAt = this.clock.now();
    this.patch({
      outcome: "loading",
      stage: "preparing",
      visible: false,
      fading: false,
      failureCode: null,
      failureMessage: null,
    });
    this.revealTimer = this.clock.setTimer(() => {
      this.revealTimer = null;
      if (this.snapshot.outcome === "loading") {
        this.patch({ visible: true });
      }
    }, STARTUP_MINIMUM_VISIBLE_DURATION_MS);
  }

  /** Reports the phase the product is currently working on. */
  setStage(stage: StartupStageId): void {
    if (!this.enabled || this.snapshot.outcome !== "loading") return;
    this.patch({ stage });
  }

  /**
   * Marks the startup as finished. A startup that was quick enough is skipped
   * without showing anything; a slow startup fades the animation out.
   */
  markReady(): void {
    this.readyReported = true;
    if (this.snapshot.outcome === "failed") {
      // A failure that happened during the startup stays readable.
      return;
    }
    this.clearRevealTimer();
    if (!this.enabled || this.elapsedMs() < STARTUP_MINIMUM_VISIBLE_DURATION_MS) {
      this.patch({ outcome: "ready", visible: false, fading: false });
      return;
    }
    this.patch({ outcome: "ready", visible: true, fading: true });
    this.fadeOutTimer = this.clock.setTimer(() => {
      this.fadeOutTimer = null;
      this.patch({ visible: false, fading: false });
    }, STARTUP_FADE_OUT_DURATION_MS);
  }

  /**
   * Keeps the failure state on screen so the user can read the reason.
   *
   * A failure that happens while the product is still starting is a startup
   * failure, so it stays visible even when the workbench painted its first
   * frame in the meantime.
   */
  markFailed(failureCode: StartupFailureCode, failureMessage: string | null): void {
    this.failureReported = { code: failureCode, message: failureMessage };
    this.applyFailure(failureCode, failureMessage);
  }

  /** Dismisses the failure state on user request. */
  dismiss(): void {
    this.clearTimers();
    this.patch({ visible: false, fading: false });
  }

  private applyFailure(failureCode: StartupFailureCode, failureMessage: string | null): void {
    this.clearTimers();
    this.patch({
      outcome: "failed",
      visible: true,
      fading: false,
      failureCode,
      failureMessage,
    });
  }

  private elapsedMs(): number {
    if (this.startedAt === null) return 0;
    return this.clock.now() - this.startedAt;
  }

  private clearRevealTimer(): void {
    if (this.revealTimer === null) return;
    this.clock.clearTimer(this.revealTimer);
    this.revealTimer = null;
  }

  private clearTimers(): void {
    this.clearRevealTimer();
    if (this.fadeOutTimer === null) return;
    this.clock.clearTimer(this.fadeOutTimer);
    this.fadeOutTimer = null;
  }

  private patch(partial: Partial<StartupFeedbackSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...partial };
    this.onChange(this.snapshot);
  }
}
