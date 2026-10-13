import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useTreeContentWidth } from "./use-tree-content-width";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

// happy-dom has no layout engine, so each element reports fixed box metrics. The row
// mirrors SidebarTreeRow: a row, its label area, and label parts whose scrollWidth may
// exceed the clientWidth they were given (i.e. an ellipsized name).
const sized = <T extends HTMLElement>(element: T, metrics: Record<string, number>): T => {
  for (const [key, value] of Object.entries(metrics)) {
    Object.defineProperty(element, key, { configurable: true, value });
  }
  return element;
};

const buildRow = (rowWidth: number, nameWidth: number, labelWidth: number) => {
  const row = sized(document.createElement("div"), { offsetWidth: rowWidth });
  row.dataset.treeRow = "";
  const label = sized(document.createElement("span"), { clientWidth: labelWidth });
  label.dataset.sidebarTreeLabel = "";
  // The count fits; only the name is clipped by whatever label space is left.
  label.append(
    sized(document.createElement("span"), {
      scrollWidth: nameWidth,
      clientWidth: Math.max(0, labelWidth - 6 - 30),
    }),
    sized(document.createElement("span"), { scrollWidth: 30, clientWidth: 30 }),
  );
  row.append(label);
  return row;
};

let rowMetrics = { rowWidth: 200, nameWidth: 150, labelWidth: 120 };

function Probe({ resetKey }: { resetKey: string }) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const width = useTreeContentWidth({ viewportRef, rowSelector: "[data-tree-row]", resetKey });
  return (
    <div
      ref={(element) => {
        if (!element) return;
        viewportRef.current = element;
        while (element.firstChild) element.removeChild(element.firstChild);
        const marker = document.createElement("span");
        marker.dataset.testid = "tree-width";
        marker.dataset.width = String(width);
        element.append(buildRow(rowMetrics.rowWidth, rowMetrics.nameWidth, rowMetrics.labelWidth));
        element.append(marker);
      }}
    />
  );
}

const treeWidth = () =>
  Number(container.querySelector<HTMLElement>('[data-testid="tree-width"]')?.dataset.width);

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  rowMetrics = { rowWidth: 200, nameWidth: 150, labelWidth: 120 };
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => root.render(<Probe resetKey="a" />));
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  restoreDom();
});

test("a clipped row widens the tree to its untruncated width", () => {
  // Fixed chrome is 200 - 120 = 80px; name and count need 150 + 6 + 30 = 186px,
  // plus one pixel of slack: 80 + 186 + 1 = 267.
  expect(treeWidth()).toBe(267);
});

test("a narrower re-measure within one layout keeps the wider tree", async () => {
  // Status refreshes re-render rows without changing the layout identity; the tree must
  // not briefly re-truncate every name, so the width only grows until the key changes.
  rowMetrics = { rowWidth: 200, nameWidth: 80, labelWidth: 120 };
  await act(async () => root.render(<Probe resetKey="a" />));
  expect(treeWidth()).toBe(267);
});

test("changing the layout identity restarts measurement from the viewport width", async () => {
  rowMetrics = { rowWidth: 200, nameWidth: 80, labelWidth: 120 };
  await act(async () => root.render(<Probe resetKey="b" />));
  expect(treeWidth()).toBe(0);
});
