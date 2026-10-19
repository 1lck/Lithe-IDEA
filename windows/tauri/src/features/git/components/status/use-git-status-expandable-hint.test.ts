import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  isLabelCutOff,
  isLabelTruncated,
  measureLabelNaturalWidth,
} from "./use-git-status-expandable-hint";

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

test("a hidden parent path does not grow the tree when its empty flex slot stretches", () => {
  const label = document.createElement("span");
  const name = document.createElement("span");
  Object.defineProperties(name, {
    scrollWidth: { value: 150 },
    clientWidth: { value: 150 },
  });
  const description = document.createElement("span");
  const path = document.createElement("span");
  path.textContent = "src/components";
  path.style.display = "none";
  description.append(path);
  label.append(name, description);
  for (const width of [120, 300]) {
    const rect = { width, height: 24, x: 0, y: 0 };
    Object.defineProperties(description, {
      scrollWidth: { configurable: true, value: width },
      clientWidth: { configurable: true, value: width },
      getClientRects: { configurable: true, value: () => [rect] },
      getBoundingClientRect: { configurable: true, value: () => rect },
    });
    expect(measureLabelNaturalWidth(label)).toBe(156);
    expect(isLabelTruncated(label)).toBe(false);
  }
});
