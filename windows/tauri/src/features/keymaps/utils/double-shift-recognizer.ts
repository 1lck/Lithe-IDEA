export const DOUBLE_SHIFT_THRESHOLD_SECONDS = 0.35;

export class DoubleShiftGestureRecognizer {
  readonly threshold: number;
  private shiftWasDown = false;
  private currentPressIsStandalone = false;
  private lastStandaloneTap: number | null = null;

  constructor(threshold = DOUBLE_SHIFT_THRESHOLD_SECONDS) {
    this.threshold = threshold;
  }

  handleKeyDown() {
    this.currentPressIsStandalone = false;
    this.lastStandaloneTap = null;
  }

  reset() {
    this.shiftWasDown = false;
    this.currentPressIsStandalone = false;
    this.lastStandaloneTap = null;
  }

  handleFlagsChanged(
    isShiftDown: boolean,
    hasOtherModifiers: boolean,
    timestamp: number,
  ): boolean {
    if (isShiftDown && !this.shiftWasDown) {
      this.currentPressIsStandalone = !hasOtherModifiers;
      this.shiftWasDown = true;
      return false;
    }

    if (isShiftDown && this.shiftWasDown) {
      if (hasOtherModifiers) {
        this.currentPressIsStandalone = false;
        this.lastStandaloneTap = null;
      }
      return false;
    }

    if (!isShiftDown && this.shiftWasDown) {
      this.shiftWasDown = false;
      const wasStandalone = this.currentPressIsStandalone;
      this.currentPressIsStandalone = false;
      if (!wasStandalone || hasOtherModifiers) {
        this.lastStandaloneTap = null;
        return false;
      }
      if (
        this.lastStandaloneTap !== null &&
        timestamp - this.lastStandaloneTap >= 0 &&
        timestamp - this.lastStandaloneTap < this.threshold
      ) {
        this.lastStandaloneTap = null;
        return true;
      }
      this.lastStandaloneTap = timestamp;
      return false;
    }

    if (hasOtherModifiers) {
      this.lastStandaloneTap = null;
    }
    return false;
  }
}

export function isShiftOnlyKey(event: KeyboardEvent) {
  return event.key === "Shift" || event.code === "ShiftLeft" || event.code === "ShiftRight";
}

export function keyboardEventHasNonShiftModifiers(event: KeyboardEvent) {
  return event.ctrlKey || event.metaKey || event.altKey;
}
