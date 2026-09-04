import { describe, expect, test } from "bun:test";
import { RUN_CONFIGURATION_LIST_DEFAULT_WIDTH } from "./run-configuration-list-layout";
import {
  RUN_CONFIGURATION_LIST_RESIZE_STEP,
  nextRunConfigurationListWidthForKey,
  startDocumentResizeSession,
} from "./run-configuration-list-resize-session";

type Listener = (event: Event) => void;

function createFakeTarget() {
  const listeners = new Map<string, Set<Listener>>();

  return {
    listeners,
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const set = listeners.get(type) ?? new Set();
      set.add(listener as Listener);
      listeners.set(type, set);
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      listeners.get(type)?.delete(listener as Listener);
    },
    dispatch(type: string, event: Event) {
      for (const listener of [...(listeners.get(type) ?? [])]) {
        listener(event);
      }
    },
  };
}

describe("run configuration list resize session", () => {
  test("ArrowLeft and ArrowRight move by a fixed step and ignore other keys", () => {
    expect(nextRunConfigurationListWidthForKey(230, "ArrowRight", 900)).toBe(
      230 + RUN_CONFIGURATION_LIST_RESIZE_STEP,
    );
    expect(nextRunConfigurationListWidthForKey(230, "ArrowLeft", 900)).toBe(
      230 - RUN_CONFIGURATION_LIST_RESIZE_STEP,
    );
    expect(nextRunConfigurationListWidthForKey(230, "Home", 900)).toBeNull();
  });

  test("commits the final width when pointerup completes a drag", () => {
    const target = createFakeTarget();
    const view = createFakeTarget();
    const bodyStyle = { cursor: "", userSelect: "" };
    const applied: number[] = [];
    const committed: number[] = [];
    const active: boolean[] = [];
    let frameId = 0;
    const frames = new Map<number, FrameRequestCallback>();

    const session = startDocumentResizeSession({
      startX: 100,
      startWidth: RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
      clampWidth: (value) => value,
      applyWidth: (width) => applied.push(width),
      commitWidth: (width) => committed.push(width),
      onActiveChange: (isActive) => active.push(isActive),
      target,
      view,
      bodyStyle,
      scheduleFrame: (callback) => {
        frameId += 1;
        frames.set(frameId, callback);
        return frameId;
      },
      cancelFrame: (handle) => {
        frames.delete(handle);
      },
    });

    expect(active).toEqual([true]);
    expect(bodyStyle.cursor).toBe("col-resize");
    expect(bodyStyle.userSelect).toBe("none");

    target.dispatch("pointermove", { clientX: 140 } as PointerEvent);
    expect(frames.size).toBe(1);
    for (const callback of frames.values()) {
      callback(0);
    }
    expect(applied).toEqual([270]);

    target.dispatch("pointerup", new Event("pointerup"));
    expect(committed).toEqual([270]);
    expect(active.at(-1)).toBe(false);
    expect(bodyStyle.cursor).toBe("");
    expect(bodyStyle.userSelect).toBe("");
    expect(target.listeners.get("pointermove")?.size ?? 0).toBe(0);
    expect(view.listeners.get("blur")?.size ?? 0).toBe(0);

    // Idempotent after completion.
    session.dispose({ commit: true });
    expect(committed).toEqual([270]);
  });

  test("cleans listeners and body styles on blur without leaving a pending frame", () => {
    const target = createFakeTarget();
    const view = createFakeTarget();
    const bodyStyle = { cursor: "auto", userSelect: "auto" };
    const committed: number[] = [];
    let frameId = 0;
    const frames = new Map<number, FrameRequestCallback>();

    startDocumentResizeSession({
      startX: 50,
      startWidth: 200,
      clampWidth: (value) => value,
      applyWidth: () => undefined,
      commitWidth: (width) => committed.push(width),
      target,
      view,
      bodyStyle,
      scheduleFrame: (callback) => {
        frameId += 1;
        frames.set(frameId, callback);
        return frameId;
      },
      cancelFrame: (handle) => {
        frames.delete(handle);
      },
    });

    target.dispatch("pointermove", { clientX: 80 } as PointerEvent);
    expect(frames.size).toBe(1);

    view.dispatch("blur", new Event("blur"));
    expect(committed).toEqual([230]);
    expect(frames.size).toBe(0);
    expect(bodyStyle.cursor).toBe("");
    expect(bodyStyle.userSelect).toBe("");
    expect(target.listeners.get("pointerup")?.size ?? 0).toBe(0);
  });

  test("dispose on unmount cancels the pending frame and can skip commit", () => {
    const target = createFakeTarget();
    const view = createFakeTarget();
    const bodyStyle = { cursor: "", userSelect: "" };
    const committed: number[] = [];
    let frameId = 0;
    const frames = new Map<number, FrameRequestCallback>();

    const session = startDocumentResizeSession({
      startX: 10,
      startWidth: 210,
      clampWidth: (value) => value,
      applyWidth: () => undefined,
      commitWidth: (width) => committed.push(width),
      target,
      view,
      bodyStyle,
      scheduleFrame: (callback) => {
        frameId += 1;
        frames.set(frameId, callback);
        return frameId;
      },
      cancelFrame: (handle) => {
        frames.delete(handle);
      },
    });

    target.dispatch("pointermove", { clientX: 40 } as PointerEvent);
    session.dispose({ commit: false });

    expect(committed).toEqual([]);
    expect(frames.size).toBe(0);
    expect(bodyStyle.cursor).toBe("");
    expect(target.listeners.get("pointermove")?.size ?? 0).toBe(0);
  });
});
