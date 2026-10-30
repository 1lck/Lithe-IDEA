import { expect, test } from "bun:test";
import { observeWebPanelViewport, webPanelLayout } from "./web-panel-viewport";

function viewport() {
  const overlays: Array<{
    hidden: boolean;
    modal: boolean;
    rect: { left: number; top: number; right: number; bottom: number };
    getClientRects(): unknown[];
    getBoundingClientRect(): unknown;
    matches(): boolean;
  }> = [];
  const document = {
    documentElement: { clientWidth: 200, clientHeight: 100 },
    hidden: false,
    defaultView: {
      devicePixelRatio: 1.25,
      getComputedStyle: () => ({ visibility: "visible", display: "block" }),
    },
    querySelectorAll: () => overlays,
  };
  let rect = { left: -20, top: 5, right: 120, bottom: 110 };
  const element = {
    ownerDocument: document,
    getBoundingClientRect: () => rect,
    contains: () => false,
  } as unknown as HTMLElement;
  return {
    element,
    document,
    overlays,
    move: (next: typeof rect) => {
      rect = next;
    },
  };
}

test("fractional DPI uses physical client coordinates and clips the native child to the viewport", () => {
  const { element } = viewport();
  expect(webPanelLayout(element)).toEqual({
    bounds: { x: 0, y: 6.25, width: 150, height: 118.75 },
    visible: true,
    focus: false,
  });
});

test("a hidden document or a fully clipped slot cannot show a native child", () => {
  const fixture = viewport();
  fixture.document.hidden = true;
  expect(webPanelLayout(fixture.element).visible).toBe(false);
  fixture.document.hidden = false;
  fixture.move({ left: 210, top: 0, right: 300, bottom: 100 });
  expect(webPanelLayout(fixture.element).visible).toBe(false);
});

test("native airspace yields to overlapping DOM menus and modal focus traps", () => {
  const fixture = viewport();
  const overlay = {
    hidden: false,
    modal: false,
    rect: { left: 150, top: 0, right: 190, bottom: 20 },
    getClientRects: () => [{}],
    getBoundingClientRect() {
      return this.rect;
    },
    matches() {
      return this.modal;
    },
  };
  fixture.overlays.push(overlay);
  expect(webPanelLayout(fixture.element).visible).toBe(true);
  overlay.rect = { left: 30, top: 10, right: 90, bottom: 50 };
  expect(webPanelLayout(fixture.element).visible).toBe(false);
  overlay.hidden = true;
  expect(webPanelLayout(fixture.element).visible).toBe(true);
  overlay.hidden = false;
  overlay.modal = true;
  overlay.rect = { left: 150, top: 0, right: 190, bottom: 20 };
  expect(webPanelLayout(fixture.element).visible).toBe(false);
});

test("ancestor layout changes coalesce and disposal releases observers, frames and listeners", () => {
  const fixture = viewport();
  const frames = new Map<number, FrameRequestCallback>();
  const observed: unknown[] = [];
  const listeners = new Set<EventListenerOrEventListenerObject>();
  let resized = () => {};
  let mutated = () => {};
  let disconnected = 0;
  let nextFrame = 0;
  const events = {
    addEventListener: (_type: string, callback: EventListenerOrEventListenerObject) =>
      listeners.add(callback),
    removeEventListener: (_type: string, callback: EventListenerOrEventListenerObject) =>
      listeners.delete(callback),
  };
  Object.assign(fixture.document, events, { body: {} });
  Object.assign(fixture.document.defaultView, events, {
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    ResizeObserver: class {
      constructor(callback: () => void) {
        resized = callback;
      }
      observe(target: unknown) {
        observed.push(target);
      }
      disconnect() {
        disconnected++;
      }
    },
    MutationObserver: class {
      constructor(callback: () => void) {
        mutated = callback;
      }
      observe() {}
      disconnect() {
        disconnected++;
      }
    },
  });
  const ancestor = { parentElement: null };
  Object.assign(fixture.element, { parentElement: ancestor });
  const layouts: ReturnType<typeof webPanelLayout>[] = [];
  const stop = observeWebPanelViewport(fixture.element, (layout) => layouts.push(layout));
  try {
    expect(observed).toEqual([fixture.element, ancestor]);
    fixture.move({ left: 30, top: 5, right: 170, bottom: 100 });
    resized();
    mutated();
    resized();
    expect(frames.size).toBe(1);
    const callbacks = [...frames.values()];
    frames.clear();
    for (const callback of callbacks) callback(0);
    expect(layouts).toHaveLength(2);
    expect(layouts[1].bounds.x).toBe(37.5);
    mutated();
    expect(frames.size).toBe(1);
  } finally {
    stop();
  }
  expect(disconnected).toBe(2);
  expect(frames.size).toBe(0);
  expect(listeners.size).toBe(0);
  resized();
  mutated();
  expect(frames.size).toBe(0);
  expect(layouts).toHaveLength(2);
});
