import { describe, expect, test } from "bun:test";
import {
  MARKDOWN_SCROLL_SYNC_DEAD_ZONE,
  MARKDOWN_SCROLL_SYNC_ECHO_TOLERANCE_PX,
  MarkdownScrollSyncController,
  markdownScrollOffset,
  markdownScrollRatio,
  type MarkdownScrollMetrics,
} from "./scroll-sync";

function metrics(scrollTop: number, scrollHeight: number, clientHeight: number): MarkdownScrollMetrics {
  return { scrollTop, scrollHeight, clientHeight };
}

describe("markdown scroll ratio", () => {
  test("maps offset into the 0..1 range", () => {
    expect(markdownScrollRatio(metrics(0, 4000, 1000))).toBe(0);
    expect(markdownScrollRatio(metrics(500, 4000, 1000))).toBeCloseTo(1 / 6, 6);
    expect(markdownScrollRatio(metrics(3000, 4000, 1000))).toBe(1);
  });

  test("clamps out-of-range and non-finite offsets", () => {
    expect(markdownScrollRatio(metrics(-50, 4000, 1000))).toBe(0);
    expect(markdownScrollRatio(metrics(99999, 4000, 1000))).toBe(1);
    expect(markdownScrollRatio(metrics(Number.NaN, 4000, 1000))).toBe(0);
  });

  test("returns 0 when the content does not scroll", () => {
    expect(markdownScrollRatio(metrics(0, 1000, 1000))).toBe(0);
    expect(markdownScrollRatio(metrics(0, 500, 1000))).toBe(0);
  });
});

describe("markdown scroll offset", () => {
  test("inverts the ratio mapping", () => {
    expect(markdownScrollOffset(0, 4000, 1000)).toBe(0);
    expect(markdownScrollOffset(0.5, 4000, 1000)).toBe(1500);
    expect(markdownScrollOffset(1, 4000, 1000)).toBe(3000);
  });

  test("clamps ratios beyond 0..1 and non-finite input", () => {
    expect(markdownScrollOffset(-1, 4000, 1000)).toBe(0);
    expect(markdownScrollOffset(2, 4000, 1000)).toBe(3000);
    expect(markdownScrollOffset(Number.NaN, 4000, 1000)).toBe(0);
  });

  test("collapses to 0 for an unscrollable target", () => {
    expect(markdownScrollOffset(0.75, 1000, 1000)).toBe(0);
  });
});

describe("MarkdownScrollSyncController", () => {
  test("drives the other pane from the first report", () => {
    const controller = new MarkdownScrollSyncController();
    expect(controller.getSource()).toBeNull();
    expect(controller.report("editor", metrics(1500, 4000, 1000))).toBe(0.5);
    expect(controller.getSource()).toBe("editor");
  });

  test("ignores same-source movement inside the dead zone", () => {
    const controller = new MarkdownScrollSyncController();
    expect(controller.report("editor", metrics(1500, 4000, 1000))).toBe(0.5);
    // 3000px extent: the dead zone ratio equals a ~1.5px scroll.
    const tinyDelta = MARKDOWN_SCROLL_SYNC_DEAD_ZONE / 2;
    expect(controller.report("editor", metrics(1500 + tinyDelta * 3000, 4000, 1000))).toBeNull();
    expect(controller.report("editor", metrics(2999, 4000, 1000))).not.toBeNull();
  });

  test("ignores source flips whose ratio barely moved, so applies cannot loop", () => {
    const controller = new MarkdownScrollSyncController();
    expect(controller.report("editor", metrics(1500, 4000, 1000))).toBe(0.5);
    // Simulates the async echo arriving from the preview after an apply: same
    // ratio, flipped source. It must not re-drive the editor.
    const echo = metrics(1500.4, 4000, 1000);
    const echoRatio = markdownScrollRatio(echo);
    expect(Math.abs(echoRatio - 0.5)).toBeLessThanOrEqual(MARKDOWN_SCROLL_SYNC_DEAD_ZONE);
    expect(controller.report("preview", echo)).toBeNull();
    expect(controller.getSource()).toBe("editor");
  });

  test("suppresses the echo of an applied offset exactly once", () => {
    const controller = new MarkdownScrollSyncController();
    expect(controller.report("editor", metrics(1500, 4000, 1000))).toBe(0.5);
    controller.markApplied("preview", 1500);
    // First preview event is the echo of the apply.
    expect(controller.report("preview", metrics(1500, 4000, 1000))).toBeNull();
    // A real user scroll afterwards is reported normally.
    expect(controller.report("preview", metrics(2250, 4000, 1000))).toBe(0.75);
  });

  test("echo suppression only swallows offsets within the tolerance", () => {
    const controller = new MarkdownScrollSyncController();
    controller.markApplied("preview", 1500);
    expect(
      controller.report("preview", metrics(1500 + MARKDOWN_SCROLL_SYNC_ECHO_TOLERANCE_PX + 1, 4000, 1000)),
    ).not.toBeNull();
  });

  test("tracks the sync source across panes", () => {
    const controller = new MarkdownScrollSyncController();
    expect(controller.report("editor", metrics(0, 4000, 1000))).toBe(0);
    expect(controller.getSource()).toBe("editor");
    expect(controller.report("preview", metrics(3000, 4000, 1000))).toBe(1);
    expect(controller.getSource()).toBe("preview");
  });
});
