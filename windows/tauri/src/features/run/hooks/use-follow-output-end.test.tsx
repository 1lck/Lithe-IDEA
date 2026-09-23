import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useFollowOutputEnd } from "./use-follow-output-end";

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

interface ProbeProps {
  output: string;
  enabled: boolean;
  visible: boolean;
}

function Probe({ output, enabled, visible }: ProbeProps) {
  const ref = useRef<HTMLDivElement>(null);
  useFollowOutputEnd(ref, output, enabled, visible);
  return (
    <div ref={ref} data-testid="output">
      <pre>{output}</pre>
    </div>
  );
}

// happy-dom computes no layout, so the geometry the hook reads is stubbed:
// content grows to 600px in a 150px viewport.
function outputContainer(): HTMLElement {
  const node = host.querySelector<HTMLElement>('[data-testid="output"]');
  if (!node) throw new Error("output container was not rendered");
  return node;
}

function render(props: ProbeProps) {
  act(() => root.render(<Probe {...props} />));
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  render({ output: "first line\n", enabled: false, visible: true });
  Object.defineProperty(outputContainer(), "scrollHeight", { get: () => 600, configurable: true });
  Object.defineProperty(outputContainer(), "clientHeight", { get: () => 150, configurable: true });
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

test("pinned on: growing output keeps the view at the end", () => {
  render({ output: "first line\n", enabled: true, visible: true });
  outputContainer().scrollTop = 0;

  render({ output: "first line\nsecond line\n", enabled: true, visible: true });

  expect(outputContainer().scrollTop).toBe(600);
});

test("pinned off: growing output leaves the user's scroll position alone", () => {
  outputContainer().scrollTop = 42;

  render({ output: "first line\nsecond line\n", enabled: false, visible: true });

  expect(outputContainer().scrollTop).toBe(42);
});

test("turning the pin back on jumps to the newest output", () => {
  outputContainer().scrollTop = 42;

  render({ output: "first line\n", enabled: true, visible: true });

  expect(outputContainer().scrollTop).toBe(600);
});

test("hidden pane: output grows unseen, reopening scrolls back to the end", () => {
  render({ output: "first line\n", enabled: true, visible: false });
  outputContainer().scrollTop = 42;

  render({ output: "first line\nhidden growth\n", enabled: true, visible: false });
  expect(outputContainer().scrollTop).toBe(42);

  render({ output: "first line\nhidden growth\n", enabled: true, visible: true });
  expect(outputContainer().scrollTop).toBe(600);
});
