import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { measureTreeRowWidth } from "../../hooks/use-tree-content-width";

let restoreDom: () => void;
beforeEach(() => {
  restoreDom = installHappyDom();
});
afterEach(() => restoreDom());

// happy-dom has no layout engine, so each element reports fixed box metrics.
const sized = <T extends HTMLElement>(element: T, metrics: Record<string, number>): T => {
  for (const [key, value] of Object.entries(metrics)) {
    Object.defineProperty(element, key, { configurable: true, value });
  }
  return element;
};

const buildRow = (nameWidth: number, countWidth: number) => {
  const row = sized(document.createElement("div"), { offsetWidth: 200 });
  const label = sized(document.createElement("span"), { clientWidth: 120 });
  label.dataset.sidebarTreeLabel = "";
  // The name gets what is left of the 120px label after the count and the 6px gap.
  const nameSpace = Math.min(nameWidth, 120 - 6 - countWidth);
  label.append(
    sized(document.createElement("span"), { scrollWidth: nameWidth, clientWidth: nameSpace }),
    sized(document.createElement("span"), { scrollWidth: countWidth, clientWidth: countWidth }),
  );
  row.append(label);
  return row;
};

test("a clipped name widens the row by the hidden part of its name and count", () => {
  // Fixed chrome is 200 - 120 = 80px; the name and count need 150 + 6 + 40 = 196px,
  // plus one pixel of slack against fractional text widths.
  expect(measureTreeRowWidth(buildRow(150, 40))).toEqual({ width: 277, truncated: true });
});

test("a row whose label fits needs no more than its current width", () => {
  expect(measureTreeRowWidth(buildRow(60, 54))).toEqual({ width: 201, truncated: false });
});
