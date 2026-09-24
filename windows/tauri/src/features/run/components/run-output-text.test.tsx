import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { RunOutputText } from "./run-output-text";

// RunOutputText is a pure prop-driven component (no stores), so this file
// replaces no modules: it must stay safe to run beside sibling tests in the
// single-process CI group for src/features/run.

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean;
};
let previousActEnvironment: boolean | undefined;

const outputPre = (): HTMLElement => {
  const node = host.querySelector<HTMLElement>("pre");
  if (!node) throw new Error("run output pre was not rendered");
  return node;
};

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

test("wraps long output lines by default", () => {
  act(() => {
    root.render(
      <RunOutputText title="Process output" source="one very long output line" emptyLabel="empty" />,
    );
  });

  expect(outputPre().className).toContain("whitespace-pre-wrap");
});

test("single-line mode keeps every log entry on one row", () => {
  act(() => {
    root.render(
      <RunOutputText
        title="Process output"
        source="one very long output line"
        emptyLabel="empty"
        wrapLines={false}
      />,
    );
  });

  const className = outputPre().className;
  expect(className).toContain("whitespace-pre");
  expect(className).not.toContain("whitespace-pre-wrap");
  expect(className).toContain("w-max");
});

test("the soft-wrap context menu appears only for toggleable consumers", () => {
  act(() => {
    root.render(
      <RunOutputText title="Process output" source="line" emptyLabel="empty" />,
    );
  });
  // Maven reuses this component without a wrap toggle: no context-menu
  // trigger may be attached for store-less consumers.
  expect(host.querySelector("[data-slot='context-menu-trigger']")).toBeNull();

  act(() => {
    root.render(
      <RunOutputText
        title="Process output"
        source="line"
        emptyLabel="empty"
        wrapLines={false}
        wrapLabel="Use soft wraps"
        onToggleWrapLines={() => undefined}
      />,
    );
  });
  // Base UI's menu only opens on real pointer events, so the interaction
  // itself is verified against the running app; here the toggleable variant
  // must at least attach the trigger around the output.
  expect(host.querySelector("[data-slot='context-menu-trigger']")).not.toBeNull();
});
