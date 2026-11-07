import { executeCoreRuleSync } from "@/core/core-rules";

/**
 * Thin adapter over Core's `keymap.modifierGestureStep` rule. The gesture state machine itself
 * lives in rust/lithe-core-rules and runs here as wasm, so key events stay synchronous while
 * macOS and Windows share one implementation. This class only holds the opaque state Core
 * returned and turns DOM events into the rule's input.
 */
const MODIFIER_GESTURE_STEP = "keymap.modifierGestureStep";

interface GestureStepResult {
  state: unknown;
  triggered: boolean;
}

type GestureEvent =
  | { kind: "keyDown" }
  | { kind: "reset" }
  | { kind: "flags"; shift: boolean; otherModifiers: boolean };

export class DoubleShiftGestureRecognizer {
  // Core defines the shape; an empty object is its idle state.
  private state: unknown = {};

  private step(event: GestureEvent, timestamp: number): boolean {
    const result = executeCoreRuleSync<GestureStepResult>(MODIFIER_GESTURE_STEP, {
      state: this.state,
      event,
      timestamp,
    });
    this.state = result.state;
    return result.triggered;
  }

  handleKeyDown() {
    this.step({ kind: "keyDown" }, 0);
  }

  reset() {
    this.step({ kind: "reset" }, 0);
  }

  handleFlagsChanged(
    isShiftDown: boolean,
    hasOtherModifiers: boolean,
    timestamp: number,
  ): boolean {
    return this.step(
      { kind: "flags", shift: isShiftDown, otherModifiers: hasOtherModifiers },
      timestamp,
    );
  }
}

export function isShiftOnlyKey(event: KeyboardEvent) {
  return event.key === "Shift" || event.code === "ShiftLeft" || event.code === "ShiftRight";
}

export function keyboardEventHasNonShiftModifiers(event: KeyboardEvent) {
  return event.ctrlKey || event.metaKey || event.altKey;
}
