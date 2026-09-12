import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import {
  clearNativeEditorViewState,
  createViewStateRestoreGate,
  persistEditorViewportState,
  resolveScrollToPersist,
  restoreNativeEditorViewState,
  scheduleCachedViewStateRestore,
} from "./view-state-restore";

const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
const originalCancelAnimationFrame = globalThis.cancelAnimationFrame;
let nextAnimationFrameId = 1;
const animationFrames = new Map<number, FrameRequestCallback>();

function runNextAnimationFrame(): void {
  const next = animationFrames.entries().next().value as
    | [number, FrameRequestCallback]
    | undefined;
  if (!next) throw new Error("Expected a queued animation frame");

  const [id, callback] = next;
  animationFrames.delete(id);
  callback(performance.now());
}

beforeAll(() => {
  globalThis.requestAnimationFrame = (callback) => {
    const id = nextAnimationFrameId;
    nextAnimationFrameId += 1;
    animationFrames.set(id, callback);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => {
    animationFrames.delete(id);
  };
});

afterEach(() => {
  animationFrames.clear();
  clearNativeEditorViewState();
});

afterAll(() => {
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
  globalThis.cancelAnimationFrame = originalCancelAnimationFrame;
});

describe("scheduleCachedViewStateRestore", () => {
  test("does not restore stale cached scroll after owner history navigation", () => {
    let ownerNavigationRevision = 0;
    let cursor = { line: 2, column: 1 };
    let cachedViewState = {
      cursor,
      scrollTop: 40,
      scrollLeft: 4,
    };
    let actualScroll = { scrollTop: 40, scrollLeft: 4 };
    let restoreCompleted = false;

    const cancelRestore = scheduleCachedViewStateRestore({
      editor: {
        layout: () => undefined,
        setScrollPosition: (position) => {
          actualScroll = position;
        },
      },
      cachedScroll: cachedViewState,
      isEditorCurrent: () => true,
      isNavigationRevisionCurrent: () => ownerNavigationRevision === 0,
      focus: () => undefined,
      onRestoreComplete: () => {
        restoreCompleted = true;
      },
    });

    // History navigation runs after activation has queued its view-state RAFs.
    ownerNavigationRevision += 1;
    cursor = { line: 80, column: 6 };
    actualScroll = { scrollTop: 960, scrollLeft: 24 };
    cachedViewState = {
      cursor,
      scrollTop: actualScroll.scrollTop,
      scrollLeft: actualScroll.scrollLeft,
    };

    runNextAnimationFrame();
    expect(cursor).toEqual({ line: 80, column: 6 });
    expect(actualScroll).toEqual({ scrollTop: 960, scrollLeft: 24 });
    expect(cachedViewState).toEqual({
      cursor: { line: 80, column: 6 },
      scrollTop: 960,
      scrollLeft: 24,
    });

    runNextAnimationFrame();
    expect(restoreCompleted).toBe(true);
    expect(cursor).toEqual({ line: 80, column: 6 });
    expect(actualScroll).toEqual({ scrollTop: 960, scrollLeft: 24 });
    expect(cachedViewState).toEqual({
      cursor: { line: 80, column: 6 },
      scrollTop: 960,
      scrollLeft: 24,
    });

    cancelRestore();
  });

  test("replays restoreEditor after layout when the surface stays current", () => {
    const layouts: number[] = [];
    const restores: number[] = [];
    let restoreCompleted = false;

    scheduleCachedViewStateRestore({
      editor: {
        layout: () => {
          layouts.push(layouts.length);
        },
        setScrollPosition: () => {
          throw new Error("cached scroll should not be applied when restoreEditor is provided");
        },
      },
      cachedScroll: { scrollTop: 40, scrollLeft: 4 },
      restoreEditor: () => {
        restores.push(restores.length);
      },
      isEditorCurrent: () => true,
      isNavigationRevisionCurrent: () => true,
      focus: () => undefined,
      onRestoreComplete: () => {
        restoreCompleted = true;
      },
    });

    runNextAnimationFrame();
    expect(layouts).toEqual([0]);
    expect(restores).toEqual([0]);

    runNextAnimationFrame();
    expect(restoreCompleted).toBe(true);
    expect(restores).toEqual([0, 1]);
  });
});

describe("resolveScrollToPersist", () => {
  test("keeps the cached viewport when a hidden layout reports the origin", () => {
    expect(
      resolveScrollToPersist({ scrollTop: 0, scrollLeft: 0 }, { scrollTop: 640, scrollLeft: 24 }),
    ).toEqual({ scrollTop: 640, scrollLeft: 24 });
  });

  test("keeps a genuine origin when the cache is already at the origin", () => {
    expect(
      resolveScrollToPersist({ scrollTop: 0, scrollLeft: 0 }, { scrollTop: 0, scrollLeft: 0 }),
    ).toEqual({ scrollTop: 0, scrollLeft: 0 });
  });

  test("prefers the live viewport after the user scrolls", () => {
    expect(
      resolveScrollToPersist({ scrollTop: 120, scrollLeft: 8 }, { scrollTop: 640, scrollLeft: 24 }),
    ).toEqual({ scrollTop: 120, scrollLeft: 8 });
  });
});

describe("native editor view state", () => {
  test("restores the snapshot captured while switching away from a file tab", () => {
    let nativeState: { firstVisibleLine: number } | null = { firstVisibleLine: 80 };
    const captured: { state: { firstVisibleLine: number } | null } = { state: null };
    const handle = {
      save: () => nativeState,
      restore: (state: unknown) => {
        captured.state = state as { firstVisibleLine: number };
      },
    };

    persistEditorViewportState({
      viewKey: "pane-a:buffer-a",
      liveScroll: { scrollTop: 960, scrollLeft: 16 },
      cached: { scrollTop: 960, scrollLeft: 16 },
      native: handle,
    });

    nativeState = { firstVisibleLine: 1 };
    const scroll = persistEditorViewportState({
      viewKey: "pane-a:buffer-a",
      liveScroll: { scrollTop: 0, scrollLeft: 0 },
      cached: { scrollTop: 960, scrollLeft: 16 },
      native: handle,
    });

    expect(scroll).toEqual({ scrollTop: 960, scrollLeft: 16 });
    expect(restoreNativeEditorViewState("pane-a:buffer-a", handle)).toBe(true);
    expect(captured.state).toEqual({ firstVisibleLine: 80 });
  });
});

describe("createViewStateRestoreGate", () => {
  test("older restore complete does not end a newer restore", () => {
    const gate = createViewStateRestoreGate();
    const finishCreatedRestore = gate.begin();
    expect(gate.isRestoring()).toBe(true);

    const finishActivationRestore = gate.begin();
    finishCreatedRestore();
    expect(gate.isRestoring()).toBe(true);

    finishActivationRestore();
    expect(gate.isRestoring()).toBe(false);
  });
});
