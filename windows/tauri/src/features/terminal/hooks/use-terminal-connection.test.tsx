import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { IDisposable, Terminal as XtermTerminal } from "@xterm/xterm";
import { installHappyDom } from "@/test-utils/happy-dom";

mock.module("@/platform/tauri-core", () => ({
  invoke: async () => undefined,
}));

mock.module("@tauri-apps/api/event", () => ({
  listen: async () => () => undefined,
}));

mock.module("@/extensions/themes/theme-registry", () => ({
  themeRegistry: {
    onThemeChange: () => () => undefined,
  },
}));

mock.module("@/features/terminal/utils/terminal-protocol", () => ({
  TERMINAL_OUTPUT_HIGH_WATERMARK: 500_000,
  getTerminalOutputFlowAction: () => "none",
  getTerminalSize: () => ({ cols: 80, pixelHeight: 0, pixelWidth: 0, rows: 24 }),
  releaseTerminalEventChannel: () => undefined,
  subscribeToTerminalEvents: () => () => undefined,
  terminalSizesEqual: (left: { cols: number } | null, right: { cols: number }) =>
    left?.cols === right.cols,
}));

const { setFrontendDiagnosticEnabled } = await import("@/features/logging/frontend-log-runtime");
const { useTerminalConnection } = await import("./use-terminal-connection");

const actEnvironment = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean;
};

let restoreDom: () => void;
let previousActEnvironment: boolean | undefined;
let previousResizeObserver: PropertyDescriptor | undefined;
let host: HTMLDivElement;
let root: Root;
let rootMounted = false;
let intervalCallbacks: Map<number, () => void>;
let clearedIntervalIDs: number[];
let nextIntervalID: number;
let renderListeners: Set<(event: { end: number; start: number }) => void>;
let scrollListeners: Set<(position: number) => void>;

class TestResizeObserver {
  static instances: TestResizeObserver[] = [];

  readonly observed: Element[] = [];
  disconnected = false;

  constructor(_callback: ResizeObserverCallback) {
    TestResizeObserver.instances.push(this);
  }

  observe(target: Element | SVGElement) {
    this.observed.push(target);
  }

  unobserve() {}

  disconnect() {
    this.disconnected = true;
  }
}

function subscribe<T>(listeners: Set<T>, listener: T): IDisposable {
  listeners.add(listener);
  return { dispose: () => void listeners.delete(listener) };
}

function createTerminal(element: HTMLElement): XtermTerminal {
  renderListeners = new Set();
  scrollListeners = new Set();
  return {
    cols: 80,
    rows: 24,
    element,
    options: { theme: {} },
    getSelection: () => "",
    onData: () => ({ dispose: () => undefined }),
    onBinary: () => ({ dispose: () => undefined }),
    onResize: () => ({ dispose: () => undefined }),
    onSelectionChange: () => ({ dispose: () => undefined }),
    onRender: (listener: (event: { end: number; start: number }) => void) =>
      subscribe(renderListeners, listener),
    onScroll: (listener: (position: number) => void) => subscribe(scrollListeners, listener),
    write: (_data: string | Uint8Array, onComplete?: () => void) => onComplete?.(),
    writeln: () => undefined,
  } as unknown as XtermTerminal;
}

const getTerminalTheme = () => ({}) as NonNullable<XtermTerminal["options"]["theme"]>;
const updateSession = () => undefined;

function Probe({ terminal }: { terminal: XtermTerminal }) {
  useTerminalConnection({
    connectionId: "connection-1",
    getTerminalTheme,
    isInitialized: true,
    sessionId: "session-1",
    terminal,
    updateSession,
  });
  return null;
}

function mount(terminal: XtermTerminal) {
  act(() => root.render(<Probe terminal={terminal} />));
  rootMounted = true;
}

function unmount() {
  if (!rootMounted) return;
  act(() => root.unmount());
  rootMounted = false;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  previousResizeObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: TestResizeObserver,
    writable: true,
  });
  TestResizeObserver.instances = [];
  intervalCallbacks = new Map();
  clearedIntervalIDs = [];
  nextIntervalID = 0;

  window.setInterval = ((callback: TimerHandler) => {
    if (typeof callback !== "function") throw new Error("expected an interval callback");
    const id = ++nextIntervalID;
    intervalCallbacks.set(id, callback as () => void);
    return id;
  }) as typeof window.setInterval;
  window.clearInterval = ((id: number) => {
    intervalCallbacks.delete(id);
    clearedIntervalIDs.push(id);
  }) as typeof window.clearInterval;

  setFrontendDiagnosticEnabled(false);
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  rootMounted = false;
});

afterEach(() => {
  unmount();
  setFrontendDiagnosticEnabled(false);
  expect(intervalCallbacks.size).toBe(0);
  host.remove();
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  if (previousResizeObserver) {
    Object.defineProperty(globalThis, "ResizeObserver", previousResizeObserver);
  } else {
    Reflect.deleteProperty(globalThis, "ResizeObserver");
  }
  restoreDom();
});

test("diagnostic resources follow setting changes and are released on terminal cleanup", () => {
  const terminalElement = document.createElement("div");
  const viewport = document.createElement("div");
  viewport.className = "xterm-viewport";
  const screen = document.createElement("div");
  screen.className = "xterm-screen";
  const canvas = document.createElement("canvas");
  terminalElement.append(viewport, screen, canvas);
  const terminal = createTerminal(terminalElement);

  mount(terminal);

  expect(intervalCallbacks.size).toBe(0);
  expect(TestResizeObserver.instances).toHaveLength(0);
  expect(renderListeners.size).toBe(0);
  expect(scrollListeners.size).toBe(0);

  act(() => setFrontendDiagnosticEnabled(true));

  expect(intervalCallbacks.size).toBe(1);
  expect(TestResizeObserver.instances).toHaveLength(1);
  expect(TestResizeObserver.instances[0]?.observed).toEqual([
    terminalElement,
    viewport,
    screen,
    canvas,
  ]);
  expect(renderListeners.size).toBe(1);
  expect(scrollListeners.size).toBe(1);

  const firstIntervalID = [...intervalCallbacks.keys()][0];
  const firstObserver = TestResizeObserver.instances[0];
  act(() => setFrontendDiagnosticEnabled(false));

  expect(intervalCallbacks.size).toBe(0);
  expect(clearedIntervalIDs).toEqual([firstIntervalID]);
  expect(firstObserver?.disconnected).toBe(true);
  expect(renderListeners.size).toBe(0);
  expect(scrollListeners.size).toBe(0);

  act(() => setFrontendDiagnosticEnabled(true));

  expect(intervalCallbacks.size).toBe(1);
  expect(TestResizeObserver.instances).toHaveLength(2);
  expect(renderListeners.size).toBe(1);
  expect(scrollListeners.size).toBe(1);

  const secondIntervalID = [...intervalCallbacks.keys()][0];
  const secondObserver = TestResizeObserver.instances[1];
  unmount();

  expect(intervalCallbacks.size).toBe(0);
  expect(clearedIntervalIDs).toEqual([firstIntervalID, secondIntervalID]);
  expect(secondObserver?.disconnected).toBe(true);
  expect(renderListeners.size).toBe(0);
  expect(scrollListeners.size).toBe(0);

  act(() => {
    setFrontendDiagnosticEnabled(false);
    setFrontendDiagnosticEnabled(true);
  });

  expect(intervalCallbacks.size).toBe(0);
  expect(TestResizeObserver.instances).toHaveLength(2);
  expect(renderListeners.size).toBe(0);
  expect(scrollListeners.size).toBe(0);
});
