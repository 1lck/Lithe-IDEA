import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/keymap/modifier-gesture-v1.json";
import { DoubleShiftGestureRecognizer, DOUBLE_SHIFT_THRESHOLD_SECONDS } from "./double-shift-recognizer";

// The same fixture drives the Swift recognizer, so the two platform state machines cannot drift.
describe("double Shift gesture (shared fixture)", () => {
  test("threshold matches the fixture", () => {
    expect(DOUBLE_SHIFT_THRESHOLD_SECONDS).toBe(fixture.thresholdSeconds);
  });

  for (const sequence of fixture.sequences) {
    test(sequence.name, () => {
      const recognizer = new DoubleShiftGestureRecognizer(fixture.thresholdSeconds);
      for (const [index, step] of sequence.steps.entries()) {
        if (step.event === "keyDown") recognizer.handleKeyDown();
        else if (step.event === "reset") recognizer.reset();
        else {
          const triggered = recognizer.handleFlagsChanged(
            step.shift!,
            step.otherModifiers!,
            step.timestamp!,
          );
          expect({ step: index, triggered }).toEqual({ step: index, triggered: step.expected! });
        }
      }
    });
  }
});
