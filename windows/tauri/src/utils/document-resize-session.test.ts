import { describe, expect, test } from "bun:test";
import { startDocumentResizeSession } from "./document-resize-session";

function createFakeTarget() {
  const listeners = new Map<string, Set<(event: Event) => void>>();
  return {
    listeners,
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const set = listeners.get(type) ?? new Set();
      set.add(listener as (event: Event) => void);
      listeners.set(type, set);
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      listeners.get(type)?.delete(listener as (event: Event) => void);
    },
    dispatch(type: string, event: Event) {
      for (const listener of [...(listeners.get(type) ?? [])]) listener(event);
    },
  };
}

function startSession(options: { direction?: 1 | -1; cursor?: string; axis?: "x" | "y" }) {
  const target = createFakeTarget();
  const bodyStyle = { cursor: "", userSelect: "" };
  const committed: number[] = [];
  const frames: FrameRequestCallback[] = [];
  const applied: number[] = [];

  startDocumentResizeSession({
    startX: 200,
    startWidth: 100,
    clampWidth: (value) => Math.min(Math.max(value, 40), 160),
    applyWidth: (width) => applied.push(width),
    commitWidth: (width) => committed.push(width),
    target,
    view: createFakeTarget(),
    bodyStyle,
    scheduleFrame: (callback) => frames.push(callback),
    cancelFrame: () => undefined,
    ...options,
  });

  // The off-axis coordinate is a large decoy so a session reading the wrong
  // axis produces a visibly different size.
  const move = (position: number) => {
    const event =
      options.axis === "y" ? { clientX: 9999, clientY: position } : { clientX: position, clientY: 9999 };
    target.dispatch("pointermove", event as PointerEvent);
    const pending = frames.splice(0);
    pending[pending.length - 1]?.(0);
  };
  return { target, bodyStyle, committed, applied, move };
}

describe("document resize session options", () => {
  test("grows the width when the pointer moves left in reverse direction", () => {
    const { target, committed, applied, move } = startSession({ direction: -1 });

    move(170);
    expect(applied).toEqual([130]);

    target.dispatch("pointerup", new Event("pointerup"));
    expect(committed).toEqual([130]);
  });

  test("clamps the width for both directions", () => {
    const reverse = startSession({ direction: -1 });
    reverse.move(0);
    expect(reverse.applied).toEqual([160]);
    reverse.move(900);
    expect(reverse.applied).toEqual([160, 40]);

    const forward = startSession({});
    forward.move(900);
    expect(forward.applied).toEqual([160]);
  });

  test("uses the requested body cursor and falls back to col-resize", () => {
    expect(startSession({ cursor: "ew-resize" }).bodyStyle.cursor).toBe("ew-resize");
    expect(startSession({}).bodyStyle.cursor).toBe("col-resize");
  });

  test("follows clientY for a vertical resize", () => {
    const { target, committed, applied, move } = startSession({ axis: "y", direction: -1 });

    move(180);
    expect(applied).toEqual([120]);

    target.dispatch("pointerup", new Event("pointerup"));
    expect(committed).toEqual([120]);
  });
});
