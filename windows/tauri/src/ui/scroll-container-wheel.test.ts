import { describe, expect, test } from "bun:test";
import {
  applyVerticalWheelToScrollContainer,
  getWheelDeltaPixels,
  isMostlyVerticalWheel,
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
});
