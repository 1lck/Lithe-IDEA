import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useTabWheelScroll } from "./use-tab-wheel-scroll";

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

function TabStrip({ enabled }: { enabled: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useTabWheelScroll(ref, enabled);
  return <div data-toolbar><button>Back</button><div ref={ref} data-tabs><button>File</button></div></div>;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  try {
    act(() => root.unmount());
  } finally {
    host.remove();
    if (previousActEnvironment === undefined) delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
    else actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
});

function mount() {
  act(() => root.render(<TabStrip enabled />));
  const strip = host.querySelector<HTMLDivElement>("[data-tabs]")!;
  // DOM emulation has no layout: provide deterministic overflow dimensions.
  Object.defineProperties(strip, {
    scrollWidth: { configurable: true, value: 800 },
    clientWidth: { configurable: true, value: 200 },
  });
  return strip;
}

function wheel(target: Element, init: WheelEventInit) {
  const event = new window.WheelEvent("wheel", { bubbles: true, cancelable: true, ...init });
  // Happy DOM's WheelEvent currently extends UIEvent and omits mouse modifiers.
  Object.defineProperties(event, {
    ctrlKey: { value: init.ctrlKey ?? false },
    metaKey: { value: init.metaKey ?? false },
    shiftKey: { value: init.shiftKey ?? false },
  });
  target.dispatchEvent(event);
  return event;
}

test("wheel over a tab scrolls the inner strip in both directions without moving toolbar controls", () => {
  const strip = mount();
  const tab = strip.querySelector("button")!;
  const toolbar = host.querySelector<HTMLDivElement>("[data-toolbar]")!;
  expect(wheel(tab, { deltaY: 120 }).defaultPrevented).toBe(true);
  expect(strip.scrollLeft).toBe(120);
  expect(wheel(tab, { deltaY: -80 }).defaultPrevented).toBe(true);
  expect(strip.scrollLeft).toBe(40);
  // Cancel native scrolling so a horizontal gesture is not applied twice.
  expect(wheel(tab, { deltaX: 30, deltaY: 10 }).defaultPrevented).toBe(true);
  expect(strip.scrollLeft).toBe(70);
  expect(toolbar.scrollLeft).toBe(0);
  wheel(toolbar.querySelector("button")!, { deltaY: 100 });
  expect(strip.scrollLeft).toBe(70);
});

test("scrolling clamps at both ends and leaves zoom and non-overflowing strips alone", () => {
  const strip = mount();
  expect(wheel(strip, { deltaY: 1000 }).defaultPrevented).toBe(true);
  expect(strip.scrollLeft).toBe(600);
  expect(wheel(strip, { deltaY: 100 }).defaultPrevented).toBe(false);
  wheel(strip, { deltaY: -1000, shiftKey: true });
  expect(strip.scrollLeft).toBe(0);
  expect(wheel(strip, { deltaY: -100 }).defaultPrevented).toBe(false);
  for (const modifier of [{ ctrlKey: true }, { metaKey: true }]) {
    expect(wheel(strip, { deltaY: 100, ...modifier }).defaultPrevented).toBe(false);
    expect(strip.scrollLeft).toBe(0);
  }
  Object.defineProperty(strip, "scrollWidth", { value: 200 });
  expect(wheel(strip, { deltaY: 100 }).defaultPrevented).toBe(false);
  expect(strip.scrollLeft).toBe(0);
});

test("disabling for settings or dragging removes the listener, and unmount cleans it up", () => {
  const strip = mount();
  act(() => root.render(<TabStrip enabled={false} />));
  expect(wheel(strip, { deltaY: 100 }).defaultPrevented).toBe(false);
  expect(strip.scrollLeft).toBe(0);
  act(() => root.render(<TabStrip enabled />));
  wheel(strip, { deltaY: 100 });
  expect(strip.scrollLeft).toBe(100);
  act(() => root.render(null));
  expect(wheel(strip, { deltaY: 100 }).defaultPrevented).toBe(false);
  expect(strip.scrollLeft).toBe(100);
});
