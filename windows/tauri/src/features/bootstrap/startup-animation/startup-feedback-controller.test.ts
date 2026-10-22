import { expect, test } from "bun:test";
import {
  StartupFeedbackController,
  type StartupFeedbackClock,
  type StartupFeedbackSnapshot,
} from "./startup-feedback-controller";
import {
  STARTUP_FADE_OUT_DURATION_MS,
  STARTUP_MINIMUM_VISIBLE_DURATION_MS,
} from "./startup-stages";

/**
 * Deterministic clock for the startup feedback. The controller owns the skip
 * threshold and the fade-out, so the test drives time explicitly instead of
 * waiting for real timers.
 */
class FakeStartupClock implements StartupFeedbackClock {
  private current = 0;
  private nextHandle = 1;
  private readonly timers = new Map<number, { callback: () => void; dueAt: number }>();

  now(): number {
    return this.current;
  }

  setTimer(callback: () => void, delayMs: number): number {
    const handle = this.nextHandle++;
    this.timers.set(handle, { callback, dueAt: this.current + delayMs });
    return handle;
  }

  clearTimer(handle: number): void {
    this.timers.delete(handle);
  }

  get pendingTimers(): number {
    return this.timers.size;
  }

  advance(deltaMs: number): void {
    const target = this.current + deltaMs;
    for (;;) {
      const due = [...this.timers.entries()]
        .filter(([, timer]) => timer.dueAt <= target)
        .sort((left, right) => left[1].dueAt - right[1].dueAt)[0];
      if (!due) break;
      this.timers.delete(due[0]);
      this.current = due[1].dueAt;
      due[1].callback();
    }
    this.current = target;
  }
}

function createController() {
  const clock = new FakeStartupClock();
  const snapshots: StartupFeedbackSnapshot[] = [];
  const controller = new StartupFeedbackController(clock, (snapshot) => {
    snapshots.push(snapshot);
  });
  return { clock, controller, snapshots };
}

test("a startup that finishes inside the minimum duration shows no animation", () => {
  const { clock, controller } = createController();

  controller.start();
  clock.advance(STARTUP_MINIMUM_VISIBLE_DURATION_MS - 1);
  controller.markReady();

  expect(controller.getState().outcome).toBe("ready");
  expect(controller.getState().visible).toBe(false);
  expect(clock.pendingTimers).toBe(0);
});

test("a slow startup reveals the current phase and fades out after the workbench is ready", () => {
  const { clock, controller } = createController();

  controller.start();
  controller.setStage("loadingPlugins");
  clock.advance(STARTUP_MINIMUM_VISIBLE_DURATION_MS);

  expect(controller.getState().visible).toBe(true);
  expect(controller.getState().stage).toBe("loadingPlugins");
  expect(controller.getState().outcome).toBe("loading");

  controller.markReady();
  expect(controller.getState().visible).toBe(true);
  expect(controller.getState().fading).toBe(true);

  clock.advance(STARTUP_FADE_OUT_DURATION_MS);

  expect(controller.getState().visible).toBe(false);
  expect(controller.getState().fading).toBe(false);
  expect(controller.getState().outcome).toBe("ready");
});

test("a failed startup keeps the failure visible until the user continues", () => {
  const { clock, controller } = createController();

  controller.start();
  clock.advance(STARTUP_MINIMUM_VISIBLE_DURATION_MS);
  controller.markFailed("workspaceOpenFailed", "cannot open the workspace");

  expect(controller.getState().outcome).toBe("failed");
  expect(controller.getState().visible).toBe(true);
  expect(controller.getState().failureCode).toBe("workspaceOpenFailed");
  expect(controller.getState().failureMessage).toBe("cannot open the workspace");

  controller.dismiss();

  expect(controller.getState().visible).toBe(false);
});

test("a disabled animation never shows and never delays the startup", () => {
  const { clock, controller } = createController();

  controller.setEnabled(false);
  controller.start();
  clock.advance(STARTUP_MINIMUM_VISIBLE_DURATION_MS * 10);

  expect(controller.getState().visible).toBe(false);
  expect(clock.pendingTimers).toBe(0);

  controller.markReady();
  expect(controller.getState().outcome).toBe("ready");
  expect(controller.getState().visible).toBe(false);
  expect(clock.pendingTimers).toBe(0);
});

test("the phase only advances while the startup is still loading", () => {
  const { controller } = createController();

  controller.start();
  controller.setStage("initializingLanguageServices");
  expect(controller.getState().stage).toBe("initializingLanguageServices");

  controller.markReady();
  controller.setStage("openingWorkspace");
  expect(controller.getState().stage).toBe("initializingLanguageServices");
});

test("a readiness report that arrives before the animation starts skips the animation", () => {
  const { clock, controller } = createController();

  controller.markReady();
  controller.start();

  expect(controller.getState().outcome).toBe("ready");
  expect(controller.getState().visible).toBe(false);
  expect(clock.pendingTimers).toBe(0);
});

test("a failure report that arrives before the animation starts is shown", () => {
  const { controller } = createController();

  controller.markFailed("pluginLoadFailed", "cannot load the plugin");
  controller.start();

  expect(controller.getState().outcome).toBe("failed");
  expect(controller.getState().visible).toBe(true);
  expect(controller.getState().failureCode).toBe("pluginLoadFailed");
  expect(controller.getState().failureMessage).toBe("cannot load the plugin");
});

test("a failure that arrives after the workbench is ready stays readable", () => {
  const { clock, controller } = createController();

  controller.start();
  clock.advance(STARTUP_MINIMUM_VISIBLE_DURATION_MS);
  controller.markReady();
  controller.markFailed("sessionRestoreFailed", "cannot restore the session");

  expect(controller.getState().outcome).toBe("failed");
  expect(controller.getState().visible).toBe(true);
  expect(controller.getState().fading).toBe(false);
  expect(controller.getState().failureCode).toBe("sessionRestoreFailed");
});
