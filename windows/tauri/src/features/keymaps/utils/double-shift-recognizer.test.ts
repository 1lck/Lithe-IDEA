import { beforeAll, describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/keymap/modifier-gesture-v1.json";
import { executeCoreRuleSync } from "@/core/core-rules";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import { DoubleShiftGestureRecognizer } from "./double-shift-recognizer";

// The same fixture drives the Rust tests in lithe-core-rules and lithe-core and the macOS
// adapter test, so every host sees one gesture definition. Here it runs through the real wasm.
beforeAll(loadCoreRulesForTests);

describe("double Shift gesture (shared fixture through wasm)", () => {
  for (const sequence of fixture.sequences) {
    test(sequence.name, () => {
      const recognizer = new DoubleShiftGestureRecognizer();
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

  test("malformed rule requests fail with the Core error code", () => {
    expect(() => executeCoreRuleSync("keymap.modifierGestureStep", { event: { kind: "bogus" } })).toThrow(
      expect.objectContaining({ code: "invalid_request" }),
    );
    expect(() => executeCoreRuleSync("keymap.unknown", {})).toThrow(
      expect.objectContaining({ code: "not_supported" }),
    );
  });
});
