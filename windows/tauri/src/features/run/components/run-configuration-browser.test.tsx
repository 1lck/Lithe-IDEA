import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import { mapCoreConfiguration } from "../utils/run-configuration";
import { selectRunOutput } from "../utils/run-output-selection";
import { useRunPreferencesStore } from "../stores/run-preferences.store";
import type { RunConfiguration, RunSession } from "../types/run.types";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let Browser: typeof import("./run-configuration-browser").RunConfigurationBrowser;
let previousObserver: PropertyDescriptor | undefined;
let previousAct: PropertyDescriptor | undefined;
let previousFrame: PropertyDescriptor | undefined;
let previousCancelFrame: PropertyDescriptor | undefined;
const frames = new Map<number, FrameRequestCallback>();
let frameId: number;
let width: number;
let rectSpy: ReturnType<typeof spyOn>;
let previousPreferences: ReturnType<typeof useRunPreferencesStore.getState>;
const resizeCallbacks = new Set<() => void>();
const selected: string[] = [];
const launched: string[] = [];
const stopped: string[] = [];
const t = createTranslator("en-US");
const entries = [
  { id: "api", provider: "spring-boot.maven", execution: "service" },
  { id: "maven", provider: "maven.module", execution: "task" },
  { id: "gradle", provider: "gradle.task", execution: "task" },
  { id: "main", provider: "java.main", execution: "application" },
  {
    id: "web",
    provider: "npm.script",
    execution: "service",
    extensions: { npm: { framework: "vue" } },
  },
  { id: "rust", provider: "cargo.binary", execution: "application" },
  { id: "swift", provider: "swift.command", execution: "application" },
  { id: "db", provider: "compose.service", category: "infrastructure", execution: "service" },
].map((entry) => mapCoreConfiguration({ ...entry, name: entry.id }));
const sessions: RunSession[] = [
  {
    id: "api",
    configurationId: "api",
    title: "API",
    output: "API log",
    isRunning: true,
    exitCode: null,
  },
  {
    id: "web",
    configurationId: "web",
    title: "Web",
    output: "Web log",
    isRunning: true,
    exitCode: null,
  },
];

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  previousAct = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  previousFrame = Object.getOwnPropertyDescriptor(globalThis, "requestAnimationFrame");
  previousCancelFrame = Object.getOwnPropertyDescriptor(globalThis, "cancelAnimationFrame");
  frameId = 0;
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) => {
      frames.set(++frameId, callback);
      return frameId;
    },
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true,
    value: (id: number) => frames.delete(id),
  });
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    configurable: true,
    value: true,
  });
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: class {
      constructor(private callback: () => void) {}
      observe() {
        resizeCallbacks.add(this.callback);
      }
      disconnect() {
        resizeCallbacks.delete(this.callback);
      }
    },
  });
  width = 900;
  rectSpy = spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(
    () => ({ width }) as DOMRect,
  );
  previousPreferences = useRunPreferencesStore.getState();
  useRunPreferencesStore.getState().actions.setConfigurationListWidth(230);
  useRunPreferencesStore.getState().actions.setLanguageColumnLayout(144, false);
  selected.length = launched.length = stopped.length = 0;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  ({ RunConfigurationBrowser: Browser } = await import("./run-configuration-browser"));
});

afterEach(() => {
  try {
    act(() => root.unmount());
    expect(resizeCallbacks.size).toBe(0);
    expect(frames.size).toBe(0);
    expect(document.body.style.cursor).toBe("");
    expect(document.body.style.userSelect).toBe("");
  } finally {
    container.remove();
    rectSpy.mockRestore();
    useRunPreferencesStore.setState(previousPreferences);
    resizeCallbacks.clear();
    frames.clear();
    for (const [key, descriptor] of [
      ["ResizeObserver", previousObserver],
      ["IS_REACT_ACT_ENVIRONMENT", previousAct],
      ["requestAnimationFrame", previousFrame],
      ["cancelAnimationFrame", previousCancelFrame],
    ] as const) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else Reflect.deleteProperty(globalThis, key);
    }
    restoreDom();
  }
});

function Harness({
  selectedId,
  configurations = entries,
}: {
  selectedId?: string;
  configurations?: RunConfiguration[];
}) {
  const [localSelection, setSelection] = useState("api");
  const id = selectedId ?? localSelection;
  const output = selectRunOutput(id, sessions, {
    configurationId: "main",
    output: "Main log",
    isRunning: true,
    exitCode: null,
  });
  return (
    <LocaleProvider language="en-US">
      <Browser
        configurations={configurations}
        selectedId={id}
        sessions={sessions}
        onSelect={(value) => {
          selected.push(value);
          setSelection(value);
        }}
        onRun={(configuration) => launched.push(configuration.id)}
        onStop={(sessionId) => stopped.push(sessionId)}
        onEdit={() => {}}
        content={<div data-output>{output.output}</div>}
      />
    </LocaleProvider>
  );
}

function render(selectedId?: string, configurations?: RunConfiguration[]) {
  act(() => root.render(<Harness selectedId={selectedId} configurations={configurations} />));
}
function language(title: string) {
  return container.querySelector<HTMLButtonElement>(`button[title="${title}"][aria-pressed]`)!;
}
function titles() {
  return Array.from(container.querySelectorAll("nav button[aria-expanded]")).map(
    (button) => button.textContent,
  );
}

test("three columns browse a polyglot project without mixing configuration types or session logs", () => {
  render();
  expect(
    Array.from(container.querySelectorAll('nav[aria-label="Languages / ecosystems"] button')).map(
      (button) => button.getAttribute("title"),
    ),
  ).toEqual(["Java", "Node.js", "Rust", "Swift", "Infrastructure"]);
  expect(titles()).toEqual(["Spring Boot", "Java Application", "Gradle", "Maven Module"]);
  const nav = container.querySelector('nav[aria-label="Languages / ecosystems"]')!;
  expect(nav.textContent).toBe("JavaNode.jsRustSwiftInfrastructure");
  expect(language("Java").getAttribute("aria-label")).toBe("Java");
  expect(
    container.querySelector('nav[aria-label="Run configurations"]')?.previousElementSibling,
  ).toBeNull();
  expect(container.querySelector("[data-output]")?.textContent).toBe("API log");
  act(() => language("Node.js").click());
  expect(titles()).toEqual(["Vue"]);
  expect(selected).toEqual(["web"]);
  expect(container.querySelector("[data-output]")?.textContent).toBe("Web log");
  act(() =>
    container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.stop")}"]`)!.click(),
  );
  expect(stopped).toEqual(["web"]);
  act(() => language("Rust").click());
  expect(container.querySelector("[data-output]")?.textContent).toBe("");
  act(() =>
    container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.title")}"]`)!.click(),
  );
  expect(launched).toEqual(["rust"]);
  act(() => language("Java").click());
  expect(container.querySelector("[data-output]")?.textContent).toBe("API log");
  expect(sessions.map((session) => session.isRunning)).toEqual([true, true]);
});

test("external configuration selection reveals its ecosystem and rescans remove empty languages", () => {
  render("rust");
  expect(language("Rust").getAttribute("aria-pressed")).toBe("true");
  expect(titles()).toEqual(["Cargo"]);
  render("api");
  expect(language("Java").getAttribute("aria-pressed")).toBe("true");
  render(
    "api",
    entries.filter((entry) => entry.provider === "npm.script"),
  );
  expect(language("Node.js").getAttribute("aria-pressed")).toBe("true");
  expect(language("Java")).toBeNull();
  expect(titles()).toEqual(["Vue"]);
  render(undefined, []);
  expect(container.querySelectorAll("nav button")).toHaveLength(0);
});

test("a narrow pane keeps accessible language icons and clamps the resizable middle column", () => {
  render();
  const nav = container.querySelector('nav[aria-label="Languages / ecosystems"]')!;
  expect((nav.parentElement as HTMLElement).style.width).toBe("144px");
  width = 600;
  act(() => resizeCallbacks.forEach((callback) => callback()));
  expect((nav.parentElement as HTMLElement).style.width).toBe("32px");
  expect(language("Java").getAttribute("aria-label")).toBe("Java");
  expect(nav.parentElement!.getAttribute("data-compact")).toBe("true");
  expect(language("Node.js").querySelectorAll("image")).toHaveLength(2);
  const separator = separatorFor("run.resizeConfigurationList");
  act(() =>
    separator.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })),
  );
  expect(Number(separator.getAttribute("aria-valuenow"))).toBeLessThanOrEqual(240);
  expect(Number(separator.getAttribute("aria-valuemax"))).toBe(240);
  act(() => language("Node.js").click());
  expect(titles()).toEqual(["Vue"]);
});

function separatorFor(key: "run.resizeLanguages" | "run.resizeConfigurationList") {
  return container.querySelector<HTMLElement>(`[role="separator"][aria-label="${t(key)}"]`)!;
}

function pointer(target: EventTarget, type: string, clientX: number) {
  act(() => target.dispatchEvent(new window.MouseEvent(type, { clientX, bubbles: true })));
}

function flushFrame() {
  const callbacks = [...frames.values()];
  frames.clear();
  act(() => callbacks.forEach((callback) => callback(0)));
}

test("language sidebar drag changes local widths per frame and persists only on completion", () => {
  width = 700;
  useRunPreferencesStore.getState().actions.setConfigurationListWidth(420);
  render();
  const separator = separatorFor("run.resizeLanguages");
  const rail = separator.parentElement!;
  const middle = separatorFor("run.resizeConfigurationList").parentElement!;
  pointer(separator, "pointerdown", 144);
  pointer(document, "pointermove", 170);
  pointer(document, "pointermove", 500);
  expect(frames.size).toBe(1);
  expect(rail.style.width).toBe("144px");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(144);
  flushFrame();
  expect(rail.style.width).toBe("192px");
  expect(middle.style.width).toBe("180px");
  // React and persisted preferences remain at their starting width while the DOM tracks the drag.
  expect(separator.getAttribute("aria-valuenow")).toBe("144");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(144);
  pointer(document, "pointerup", 500);
  expect(separator.getAttribute("aria-valuenow")).toBe("192");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(192);
  expect(useRunPreferencesStore.getState().configurationListWidth).toBe(420);
  expect(document.body.style.cursor).toBe("");
  pointer(document, "pointermove", 550);
  expect(frames.size).toBe(0);
});

test("drag collapse preserves saved width across remount and keeps language navigation available", () => {
  render();
  const separator = separatorFor("run.resizeLanguages");
  act(() =>
    separator.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })),
  );
  expect(separator.parentElement!.style.width).toBe("160px");
  expect(container.querySelector("button[aria-expanded][title]")).toBeNull();
  pointer(separator, "pointerdown", 160);
  pointer(document, "pointermove", 79);
  flushFrame();
  expect(separator.parentElement!.style.width).toBe("32px");
  expect(separator.parentElement!.dataset.compact).toBe("true");
  expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(false);
  pointer(document, "pointerup", 79);
  expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(true);
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(160);
  expect(language("Java").getAttribute("title")).toBe("Java");
  act(() => language("Node.js").click());
  expect(titles()).toEqual(["Vue"]);
  act(() => root.unmount());
  root = createRoot(container);
  render();
  const restoredSeparator = separatorFor("run.resizeLanguages");
  expect(restoredSeparator.parentElement!.style.width).toBe("32px");
  act(() =>
    restoredSeparator.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }),
    ),
  );
  expect(separatorFor("run.resizeLanguages").parentElement!.style.width).toBe("160px");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(160);
});

test("resizing the window terminates a drag and narrow automatic collapse restores the preferred width", () => {
  render();
  pointer(separatorFor("run.resizeLanguages"), "pointerdown", 144);
  pointer(document, "pointermove", 210);
  width = 600;
  act(() => resizeCallbacks.forEach((callback) => callback()));
  expect(frames.size).toBe(0);
  expect(document.body.style.cursor).toBe("");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(210);
  expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(false);
  expect(separatorFor("run.resizeLanguages").getAttribute("aria-disabled")).toBe("true");
  width = 900;
  act(() => resizeCallbacks.forEach((callback) => callback()));
  expect(separatorFor("run.resizeLanguages").parentElement!.style.width).toBe("210px");
});

test("dragging the collapsed rail expands immediately and threshold hysteresis prevents flicker", () => {
  useRunPreferencesStore.getState().actions.setLanguageColumnLayout(160, true);
  render();
  const separator = separatorFor("run.resizeLanguages");
  const rail = separator.parentElement!;
  pointer(separator, "pointerdown", 32);
  for (const [x, expectedWidth, compact] of [
    [95, "32px", "true"],
    [96, "112px", "false"],
    [83, "112px", "false"],
    [79, "32px", "true"],
    [85, "32px", "true"],
    [130, "130px", "false"],
  ] as const) {
    pointer(document, "pointermove", x);
    flushFrame();
    expect(rail.style.width).toBe(expectedWidth);
    expect(rail.dataset.compact).toBe(compact);
    expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(true);
    expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(160);
  }
  pointer(document, "pointerup", 130);
  expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(false);
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(130);
  expect(language("Java").getAttribute("aria-label")).toBe("Java");
});

test("clicking a space-clamped separator without dragging preserves the preferred width", () => {
  width = 700;
  useRunPreferencesStore.getState().actions.setLanguageColumnLayout(240, false);
  render();
  pointer(separatorFor("run.resizeLanguages"), "pointerdown", 192);
  pointer(document, "pointerup", 192);
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(240);
});

test("release before the last frame restores the starting layout after a collapse preview", () => {
  render();
  const separator = separatorFor("run.resizeLanguages");
  const rail = separator.parentElement!;
  pointer(separator, "pointerdown", 144);
  pointer(document, "pointermove", 79);
  flushFrame();
  expect(rail.dataset.compact).toBe("true");
  pointer(document, "pointermove", 144);
  expect(frames.size).toBe(1);
  pointer(document, "pointerup", 144);
  expect(frames.size).toBe(0);
  expect(rail.style.width).toBe("144px");
  expect(rail.dataset.compact).toBe("false");
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(144);
  expect(useRunPreferencesStore.getState().languageColumnCollapsed).toBe(false);
});

test("unmount during language drag cancels its frame, commits width and removes document listeners", () => {
  render();
  pointer(separatorFor("run.resizeLanguages"), "pointerdown", 144);
  pointer(document, "pointermove", 190);
  expect(frames.size).toBe(1);
  act(() => root.unmount());
  expect(frames.size).toBe(0);
  expect(useRunPreferencesStore.getState().languageColumnWidth).toBe(190);
  pointer(document, "pointermove", 230);
  expect(frames.size).toBe(0);
  root = createRoot(container);
});
