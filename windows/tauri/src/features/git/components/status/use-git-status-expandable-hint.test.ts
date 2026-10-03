import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { isLabelCutOff, measureLabelNaturalWidth } from "./use-git-status-expandable-hint";

let restoreDom: () => void;
beforeEach(() => {
  restoreDom = installHappyDom();
});
afterEach(() => restoreDom());

test("a label reaching past the visible viewport edge is cut off", () => {
  expect(isLabelCutOff(100, 180, 260)).toBe(true);
  expect(isLabelCutOff(100, 160, 260)).toBe(false);
  // Sub-pixel rounding at the exact edge does not count as cut off.
  expect(isLabelCutOff(100, 160.5, 260)).toBe(false);
});

test("the natural label width adds every part at full text width plus the gaps", () => {
  const label = document.createElement("span");
  for (const width of [150, 40]) {
    const part = document.createElement("span");
    Object.defineProperty(part, "scrollWidth", { configurable: true, value: width });
    label.append(part);
  }
  expect(measureLabelNaturalWidth(label)).toBe(196);
});
