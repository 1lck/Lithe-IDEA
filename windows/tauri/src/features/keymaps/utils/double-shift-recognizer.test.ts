import { describe, expect, test } from "bun:test";
import { DoubleShiftGestureRecognizer } from "./double-shift-recognizer";

describe("double Shift search everywhere", () => {
  test("requires two standalone taps within the threshold", () => {
    const recognizer = new DoubleShiftGestureRecognizer(0.35);

    expect(recognizer.handleFlagsChanged(true, false, 1.0)).toBe(false);
    expect(recognizer.handleFlagsChanged(false, false, 1.05)).toBe(false);
    expect(recognizer.handleFlagsChanged(true, false, 1.2)).toBe(false);
    expect(recognizer.handleFlagsChanged(false, false, 1.25)).toBe(true);
  });

  test("rejects Shift used for uppercase typing and keys between taps", () => {
    const recognizer = new DoubleShiftGestureRecognizer(0.35);

    recognizer.handleFlagsChanged(true, false, 1.0);
    recognizer.handleKeyDown();
    expect(recognizer.handleFlagsChanged(false, false, 1.05)).toBe(false);

    recognizer.handleFlagsChanged(true, false, 1.2);
    recognizer.handleKeyDown();
    expect(recognizer.handleFlagsChanged(false, false, 1.25)).toBe(false);

    recognizer.handleFlagsChanged(true, false, 2.0);
    recognizer.handleFlagsChanged(false, false, 2.05);
    recognizer.handleKeyDown();
    recognizer.handleFlagsChanged(true, false, 2.2);
    expect(recognizer.handleFlagsChanged(false, false, 2.25)).toBe(false);
  });

  test("ignores a second tap after the threshold", () => {
    const recognizer = new DoubleShiftGestureRecognizer(0.35);

    recognizer.handleFlagsChanged(true, false, 1.0);
    recognizer.handleFlagsChanged(false, false, 1.05);
    recognizer.handleFlagsChanged(true, false, 1.5);
    expect(recognizer.handleFlagsChanged(false, false, 1.55)).toBe(false);
  });
});
