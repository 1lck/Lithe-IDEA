import { describe, expect, test } from "bun:test";
import {
  applyVerticalWheelToScrollContainer,
  canScrollVerticallyInDirection,
  findNestedScrollableInComposedPath,
  getWheelDeltaPixels,
  isMostlyVerticalWheel,
  resolveWheelScrollChainTarget,
} from "./scroll-container-wheel";

describe("scroll container wheel", () => {
  test("treats pixel wheel deltas as pixels", () => {
    expect(
      getWheelDeltaPixels(
        { deltaX: 0, deltaY: 120, deltaMode: 0 },
        { lineHeight: 16, pageWidth: 240, pageHeight: 400 },
      ),
    ).toEqual({ x: 0, y: 120 });
  });

  test("converts line and page wheel deltas to pixels", () => {
    expect(
      getWheelDeltaPixels(
        { deltaX: 0, deltaY: 3, deltaMode: 1 },
        { lineHeight: 20, pageWidth: 240, pageHeight: 400 },
      ),
    ).toEqual({ x: 0, y: 60 });
    expect(
      getWheelDeltaPixels(
        { deltaX: 0, deltaY: 1, deltaMode: 2 },
        { lineHeight: 20, pageWidth: 240, pageHeight: 400 },
      ),
    ).toEqual({ x: 0, y: 400 });
  });

  test("keeps horizontal project-switch gestures from capturing vertical scroll", () => {
    expect(isMostlyVerticalWheel(40, 8)).toBe(false);
    expect(isMostlyVerticalWheel(8, 40)).toBe(true);
  });

  test("moves a nested overflow container that Chromium would otherwise latch onto a row", () => {
    const element = {
      scrollTop: 0,
      scrollHeight: 800,
      clientHeight: 200,
    };

    expect(applyVerticalWheelToScrollContainer(element, 80)).toBe(true);
    expect(element.scrollTop).toBe(80);
  });

  test("does not consume wheel events at the scroll boundary", () => {
    const element = {
      scrollTop: 0,
      scrollHeight: 800,
      clientHeight: 200,
    };

    expect(applyVerticalWheelToScrollContainer(element, -40)).toBe(false);
    expect(element.scrollTop).toBe(0);

    element.scrollTop = 600;
    expect(applyVerticalWheelToScrollContainer(element, 40)).toBe(false);
    expect(element.scrollTop).toBe(600);
  });

  test("defers to a nested textarea/overflow scroller that can still move", () => {
    const nested = {
      scrollTop: 10,
      scrollHeight: 400,
      clientHeight: 100,
    };
    const outer = {
      scrollTop: 0,
      scrollHeight: 1200,
      clientHeight: 400,
    };

    expect(canScrollVerticallyInDirection(nested, 40)).toBe(true);
    expect(
      resolveWheelScrollChainTarget({
        nestedCanScrollInDirection: canScrollVerticallyInDirection(nested, 40),
        outerCanScrollInDirection: canScrollVerticallyInDirection(outer, 40),
      }),
    ).toBe("nested");
  });

  test("scrolls the outer container when the nested scroller is at its boundary", () => {
    const nested = {
      scrollTop: 300,
      scrollHeight: 400,
      clientHeight: 100,
    };
    const outer = {
      scrollTop: 0,
      scrollHeight: 1200,
      clientHeight: 400,
    };

    expect(canScrollVerticallyInDirection(nested, 40)).toBe(false);
    expect(canScrollVerticallyInDirection(outer, 40)).toBe(true);
    expect(
      resolveWheelScrollChainTarget({
        nestedCanScrollInDirection: canScrollVerticallyInDirection(nested, 40),
        outerCanScrollInDirection: canScrollVerticallyInDirection(outer, 40),
      }),
    ).toBe("outer");
  });

  test("does not capture the wheel when neither nested nor outer can scroll", () => {
    expect(
      resolveWheelScrollChainTarget({
        nestedCanScrollInDirection: false,
        outerCanScrollInDirection: false,
      }),
    ).toBe("none");
  });

  test("composedPath prefers the nearest nested textarea that can still scroll", () => {
    expect(
      findNestedScrollableInComposedPath({
        outerId: "settings-panel",
        path: [
          { id: "textarea", scrollable: true, canScrollInDirection: true },
          { id: "form-row", scrollable: false, canScrollInDirection: false },
          { id: "settings-panel", scrollable: true, canScrollInDirection: true },
        ],
      }),
    ).toBe("textarea");
  });

  test("composedPath skips a nested scroller that is already at its boundary", () => {
    expect(
      findNestedScrollableInComposedPath({
        outerId: "settings-panel",
        path: [
          { id: "textarea", scrollable: true, canScrollInDirection: false },
          { id: "settings-panel", scrollable: true, canScrollInDirection: true },
        ],
      }),
    ).toBeNull();
  });
});
