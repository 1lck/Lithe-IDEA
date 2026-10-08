import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { bindScrollContainerWheel } from "./scroll-container-wheel";

let restoreDom: () => void;
let unbind: () => void;
let element: HTMLDivElement;
let time: number;
let nextId: number;
let frames: Map<number, FrameRequestCallback>;

beforeEach(() => {
  restoreDom = installHappyDom();
  time = 0;
  nextId = 0;
  frames = new Map();
  Object.defineProperty(window.performance, "now", { configurable: true, value: () => time });
  window.requestAnimationFrame = (callback) => { frames.set(++nextId, callback); return nextId; };
  window.cancelAnimationFrame = (id) => { frames.delete(id); };
  element = document.createElement("div");
  element.style.lineHeight = "20px";
  element.innerHTML = "<button>branch or commit row</button>";
  document.body.append(element);
  Object.defineProperties(element, {
    scrollHeight: { value: 800 }, clientHeight: { value: 200 },
    scrollWidth: { value: 800 }, clientWidth: { value: 200 },
  });
  unbind = bindScrollContainerWheel(element, { smooth: true });
});

afterEach(() => {
  try { unbind(); element.remove(); frames.clear(); } finally { restoreDom(); }
});

function advance(nextTime: number) {
  time = nextTime;
  const callbacks = [...frames.values()];
  frames.clear();
  for (const callback of callbacks) callback(time);
}

function wheel(init: WheelEventInit = {}) {
  const event = new window.WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: 120, ...init });
  // Happy DOM omits mouse modifiers on its WheelEvent.
  Object.defineProperties(event, {
    ctrlKey: { value: init.ctrlKey ?? false }, metaKey: { value: init.metaKey ?? false },
    shiftKey: { value: init.shiftKey ?? false },
  });
  element.querySelector("button")!.dispatchEvent(event);
  return event;
}

test("wheel over a clipped row animates the real viewport and cancels native duplicate scrolling", () => {
  expect(wheel().defaultPrevented).toBe(true);
  expect(element.scrollTop).toBe(0);
  advance(100);
  expect(element.scrollTop).toBeGreaterThan(0);
  expect(element.scrollTop).toBeLessThan(120);
  advance(200);
  expect(element.scrollTop).toBe(120);
  expect(frames.size).toBe(0);
});

test("horizontal and Shift wheel use the same animation without moving the vertical axis", () => {
  wheel({ deltaX: 80, deltaY: 0 });
  advance(200);
  expect(element.scrollLeft).toBe(80);
  wheel({ deltaY: 3, deltaMode: 1, shiftKey: true });
  advance(400);
  expect(element.scrollLeft).toBe(140);
  expect(element.scrollTop).toBe(0);
});

test("keyboard navigation and scrollbar pointer input stop wheel inertia", () => {
  for (const type of ["keydown", "pointerdown"]) {
    wheel();
    advance(time + 50);
    const position = element.scrollTop;
    element.dispatchEvent(new window.Event(type, { bubbles: true }));
    expect(frames.size).toBe(0);
    advance(time + 200);
    expect(element.scrollTop).toBe(position);
  }
});

test("zoom, non-cancelable and already consumed events do not start animation", () => {
  for (const init of [{ ctrlKey: true }, { metaKey: true }, { cancelable: false }]) {
    expect(wheel(init).defaultPrevented).toBe(false);
  }
  element.parentElement!.addEventListener("wheel", (event) => event.preventDefault(), { capture: true, once: true });
  expect(wheel().defaultPrevented).toBe(true);
  expect(frames.size).toBe(0);
});

test("reduced motion falls back to immediate scrolling", () => {
  unbind();
  const matchMedia = window.matchMedia;
  window.matchMedia = () => ({ matches: true }) as MediaQueryList;
  try {
    unbind = bindScrollContainerWheel(element, { smooth: true });
    wheel();
    expect(element.scrollTop).toBe(120);
    expect(frames.size).toBe(0);
  } finally { window.matchMedia = matchMedia; }
});

test("unbind removes listeners and cancels both axes before their next frame", () => {
  wheel();
  wheel({ deltaX: 80, deltaY: 0 });
  expect(frames.size).toBe(2);
  unbind();
  expect(frames.size).toBe(0);
  advance(200);
  expect(element.scrollTop).toBe(0);
  expect(element.scrollLeft).toBe(0);
  expect(wheel().defaultPrevented).toBe(false);
});

test("file rows and sibling scrollbars share the same viewport animation", () => {
  unbind();
  const root = document.createElement("div");
  const scrollbar = document.createElement("div");
  document.body.append(root);
  root.append(element, scrollbar);
  unbind = bindScrollContainerWheel(element, { smooth: true, eventTarget: root, stopPropagation: true });
  // Model a scrollbar primitive that independently applies its own wheel delta.
  const directWheel = () => { element.scrollTop += 80; };
  scrollbar.addEventListener("wheel", directWheel);
  try {
    wheel();
    scrollbar.dispatchEvent(new window.WheelEvent("wheel", {
      bubbles: true, cancelable: true, deltaY: 80,
    }));
    expect(element.scrollTop).toBe(0);
    expect(frames.size).toBe(1);
    advance(100);
    expect(element.scrollTop).toBeGreaterThan(0);
    expect(element.scrollTop).toBeLessThan(200);
    advance(200);
    expect(element.scrollTop).toBe(200);
    expect(root.scrollTop).toBe(0);
    unbind();
    const event = new window.WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: 80 });
    scrollbar.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(false);
  } finally { unbind(); scrollbar.removeEventListener("wheel", directWheel); root.remove(); }
});

test("dragging a sibling scrollbar cancels the viewport's wheel motion", () => {
  unbind();
  const root = document.createElement("div");
  const scrollbar = document.createElement("div");
  document.body.append(root);
  root.append(element, scrollbar);
  unbind = bindScrollContainerWheel(element, { smooth: true, eventTarget: root });
  try {
    wheel();
    advance(50);
    const position = element.scrollTop;
    scrollbar.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
    expect(frames.size).toBe(0);
    advance(200);
    expect(element.scrollTop).toBe(position);
  } finally { unbind(); root.remove(); }
});
