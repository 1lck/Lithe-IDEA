import { cubicBezier } from "motion";

// Note: .agents/notes/implemented/bug-fix/2026-10-08-windows-git-log-wheel-animation.md
// Community UISettingsState (Windows): 200 ms, packed curve 1684366536.
// Same-direction retargeting follows MouseWheelSmoothScroll.InertialAnimator.
const SCROLL_DURATION_MS = 200;
const scrollEasing = cubicBezier(0.5, 0.505, 0.5, 1);

export interface ScrollAnimationScheduler {
  now: () => number;
  request: (callback: () => void) => number;
  cancel: (id: number) => void;
}

/** Owns one scroll axis; frames only write the viewport, never React state. */
export function createWheelScrollAnimation({
  read,
  write,
  maximum,
  scheduler,
}: {
  read: () => number;
  write: (position: number) => void;
  maximum: () => number;
  scheduler: ScrollAnimationScheduler;
}) {
  let frame: number | null = null;
  let initial = 0;
  let current = 0;
  let target = 0;
  let started = 0;
  let lastFrame = 0;
  let duration = SCROLL_DURATION_MS;

  const clamp = (position: number) => Math.max(0, Math.min(maximum(), position));
  const stop = () => {
    if (frame !== null) scheduler.cancel(frame);
    frame = null;
  };

  const tick = () => {
    // Scrollbar dragging, keyboard reveal and replacement content win over inertia.
    if (read() !== Math.round(current)) {
      stop();
      return;
    }
    lastFrame = scheduler.now();
    const progress = Math.min(1, Math.max(0, (lastFrame - started) / duration));
    current = initial + (target - initial) * scrollEasing(progress);
    const position = Math.round(clamp(current));
    write(position);
    if (progress === 1 || position !== Math.round(current)) {
      stop();
    } else {
      frame = scheduler.request(tick);
    }
  };

  return {
    scroll(delta: number) {
      if (delta === 0 || !Number.isFinite(delta)) return false;
      const position = read();
      if (frame !== null && position !== Math.round(current)) stop();
      const sameDirection = frame !== null && (target - initial) * delta > 0;
      const nextTarget = clamp((sameDirection ? target : position) + delta);
      // Keep owning outward events while still travelling to the boundary;
      // otherwise the browser would jump there before the animation finishes.
      if (nextTarget === (sameDirection ? target : position)) return sameDirection && position !== target;

      if (sameDirection) {
        duration = SCROLL_DURATION_MS + Math.max(lastFrame - started, 0);
        initial = current;
        started = lastFrame;
      } else {
        duration = SCROLL_DURATION_MS;
        initial = position;
        started = scheduler.now();
      }
      current = position;
      lastFrame = started;
      target = nextTarget;
      if (frame === null) frame = scheduler.request(tick);
      return true;
    },
    stop,
  };
}
