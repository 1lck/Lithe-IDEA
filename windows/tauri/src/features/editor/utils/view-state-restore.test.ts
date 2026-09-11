import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { scheduleCachedViewStateRestore } from "./view-state-restore";

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
});
