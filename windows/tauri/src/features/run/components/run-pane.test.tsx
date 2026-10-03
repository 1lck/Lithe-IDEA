import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { TooltipProvider } from "@/ui/tooltip";
import * as processEvents from "../hooks/use-run-process-events";
import { createRunStore, useRunStore } from "../stores/run.store";
import { useRunPreferencesStore } from "../stores/run-preferences.store";
import { PRIMARY_SESSION_ID, type RunSession } from "../types/run.types";
import { mapCoreConfiguration } from "../utils/run-configuration";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let Pane: typeof import("./run-pane").default;
let store: ReturnType<typeof createRunStore>;
let unsubscribe: () => void;
let previousRun: ReturnType<typeof useRunStore.getState>;
let previousFiles: ReturnType<typeof useFileSystemStore.getState>;
let previousPreferences: ReturnType<typeof useRunPreferencesStore.getState>;
let previousAct: PropertyDescriptor | undefined;
let previousObserver: PropertyDescriptor | undefined;
let listenersSpy: ReturnType<typeof spyOn>;
let loadSpy: ReturnType<typeof spyOn>;
let stopSpy: ReturnType<typeof spyOn>;
let pendingStop: Promise<void> | undefined;
const stopped: string[] = [];
const t = createTranslator("en-US");
const configurations = [
  { id: "A", name: "Application A", provider: "java.main", execution: "application" },
  { id: "B", name: "Service B", provider: "npm.script", execution: "service" },
  { id: "C", name: "Service C", provider: "cargo.binary", execution: "service" },
].map(mapCoreConfiguration);

function service(id: string): RunSession {
  return {
    id: `slot-${id}`,
    configurationId: id,
    title: `Service ${id}`,
    output: `Service ${id} output`,
    isRunning: true,
    exitCode: null,
  };
}

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousAct = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  previousObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    configurable: true,
    value: true,
  });
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: class {
      observe() {}
      disconnect() {}
    },
  });
  previousRun = useRunStore.getState();
  previousFiles = useFileSystemStore.getState();
  previousPreferences = useRunPreferencesStore.getState();
  stopped.length = 0;
  pendingStop = undefined;
  store = createRunStore("run-pane-test", {
    stopRunProcess: async (sessionId) => {
      stopped.push(sessionId);
    },
  });
  store.setState({
    status: "ready",
    configurations,
    selectedConfigurationId: "A",
    selectedSessionId: PRIMARY_SESSION_ID,
    primaryConfigurationId: "A",
    primaryOutput: "Application A output",
    primaryRunning: true,
  });
  loadSpy = spyOn(store.getState().actions, "loadProject").mockResolvedValue(undefined);
  const stop = store.getState().actions.stop;
  stopSpy = spyOn(store.getState().actions, "stop").mockImplementation((...args) => {
    pendingStop = stop(...args);
    return pendingStop;
  });
  listenersSpy = spyOn(processEvents, "ensureRunProcessListeners").mockResolvedValue(undefined);
  useRunStore.setState(store.getState());
  unsubscribe = store.subscribe((state) => useRunStore.setState(state));
  useFileSystemStore.setState({ rootFolderPath: "/workspace/project" });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  ({ default: Pane } = await import("./run-pane"));
});

afterEach(() => {
  try {
    act(() => root.unmount());
  } finally {
    unsubscribe();
    stopSpy.mockRestore();
    loadSpy.mockRestore();
    listenersSpy.mockRestore();
    useRunStore.setState(previousRun);
    useFileSystemStore.setState(previousFiles);
    useRunPreferencesStore.setState(previousPreferences);
    container.remove();
    for (const [key, descriptor] of [
      ["IS_REACT_ACT_ENVIRONMENT", previousAct],
      ["ResizeObserver", previousObserver],
    ] as const) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else Reflect.deleteProperty(globalThis, key);
    }
    restoreDom();
  }
});

function render() {
  act(() =>
    root.render(
      <LocaleProvider language="en-US">
        <TooltipProvider>
          <Pane />
        </TooltipProvider>
      </LocaleProvider>,
    ),
  );
}

async function stopVisibleOutput() {
  // The toolbar keeps its Run aria-label while showing the Stop icon.
  const button = container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.run")}"]`);
  expect(button).not.toBeNull();
  await act(async () => {
    button!.click();
    await pendingStop;
  });
}

test("toolbar stops visible primary A after background service B takes store focus", async () => {
  render();
  // Bulk service launch changes process focus without changing the visible configuration.
  act(() => store.setState({ selectedSessionId: "slot-B", sessions: [service("B")] }));
  expect(container.textContent).toContain("Application A output");
  expect(container.textContent).not.toContain("Service B output");
  await stopVisibleOutput();
  expect(stopped).toEqual([PRIMARY_SESSION_ID]);
  expect(store.getState().primaryRunning).toBe(false);
  expect(store.getState().sessions[0].isRunning).toBe(true);
});

test("toolbar stops the visible service slot when another service takes store focus", async () => {
  store.setState({
    selectedConfigurationId: "B",
    selectedSessionId: "slot-B",
    sessions: [service("B")],
  });
  render();
  act(() =>
    store.setState({ selectedSessionId: "slot-C", sessions: [service("B"), service("C")] }),
  );
  expect(container.textContent).toContain("Service B output");
  expect(container.textContent).not.toContain("Service C output");
  await stopVisibleOutput();
  expect(stopped).toEqual(["slot-B"]);
  expect(store.getState().primaryRunning).toBe(true);
  expect(store.getState().sessions.map((session) => session.isRunning)).toEqual([false, true]);
});
