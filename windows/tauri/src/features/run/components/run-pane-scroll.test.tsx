import { afterAll, afterEach, beforeAll, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { create } from "zustand";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useRunPreferencesStore } from "../stores/run-preferences.store";

const restoreDom = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousActFlag = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
// A module in RunPane's import chain resolves the current Tauri window at
// load time; the minimum metadata keeps that resolution inert in tests.
(window as unknown as { __TAURI_INTERNALS__: unknown }).__TAURI_INTERNALS__ = {
  metadata: { currentWindow: { label: "main" }, currentWebview: { label: "main" } },
};
globalThis.DOMRect = window.DOMRect;
globalThis.ResizeObserver = window.ResizeObserver;

// Controllable stand-ins for the stores RunPane reads; only the pieces the
// scroll behavior depends on carry real values, everything else is inert.
const noop = () => undefined;
const useRunStore = create(() => ({
  status: "ready" as const,
  isLoading: false,
  isGenerating: false,
  configurations: [] as unknown[],
  diagnostics: [] as unknown[],
  selectedConfigurationId: null,
  selectedSessionId: null,
  sessions: [] as unknown[],
  primaryOutput: "first line\n",
  primaryRunning: false,
  primaryTitle: "",
  primaryExitCode: null,
  recoveryAction: "none",
  invalidMessage: "",
  saveError: null,
  generationNotice: null,
  javaLaunchDecisions: {} as Record<string, unknown>,
  discoveredJava: [] as unknown[],
  discoveredMaven: [] as unknown[],
  discoveredRuntimes: [] as unknown[],
  globalToolchain: null,
  javaDiscovery: "idle" as const,
  javaDiscoveryMessage: null,
  editingConfigurationId: null,
  actions: {
    clearOutput: noop,
    loadProject: noop,
    runConfiguration: noop,
    stop: noop,
    selectConfiguration: noop,
    continueJavaLaunch: noop,
    cancelJavaLaunch: noop,
    rebuildJavaIndex: noop,
    writeStdin: noop,
    saveEditorChanges: noop,
    generate: noop,
    editConfiguration: noop,
  },
}));
const useUIState = create(() => ({
  isBottomPaneVisible: true,
  setIsBottomPaneVisible: noop,
  openSettingsDialog: noop,
}));
const useFileSystemStore = create(() => ({ rootFolderPath: "" }));
const useBufferStore = create(() => ({ buffers: [] as unknown[], activeBufferId: null }));
const useMavenStore = create(() => ({ root: "", mavenExecutablePath: "" }));

// Narrow stand-ins only: importing the real store modules here would link
// their heavy dependency chains, and other test files in the same bun test
// process replace some of those shared modules with partial mocks, which
// makes late linkers crash on missing exports. Every mock below is a plain
// object, so this file links nothing real beyond the preference store.
// Run this file in a scoped `bun test <path>` (as the timing harness does
// with -FrontendTestPath): in the monolithic full-suite process, residual
// mock registrations from earlier files can still starve the link.
mock.module("../stores/run.store", () => ({ useRunStore, runOptionsFor: () => [] }));
mock.module("@/features/window/stores/ui-state.store", () => ({ useUIState }));
mock.module("@/features/file-system/stores/file-system.store", () => ({ useFileSystemStore }));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore,
  // Earlier test files may replace this module with a minimal mock; carry
  // this export so any late linker of the real module still resolves.
  clearQueuedWorkspaceSessionSave: () => undefined,
}));
mock.module("@/features/maven/stores/maven.store", () => ({ useMavenStore }));
mock.module("../hooks/use-run-process-events", () => ({
  ensureRunProcessListeners: async () => undefined,
}));
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
  LocaleProvider: ({ children }: { children: React.ReactNode }) => children,
}));
mock.module("@/ui/tooltip", () => ({
  default: ({ children }: { children: React.ReactNode }) => children,
}));
// Heavy child dialogs and menus are irrelevant to scroll behavior; mocking
// them keeps this file from linking their large import trees, which other
// test files in the same process may have partially mocked already.
mock.module("./run-configuration-editor", () => ({ RunConfigurationEditor: () => null }));
mock.module("./run-services-menu", () => ({ RunServicesMenu: () => null }));
mock.module("./project-preparation-status", () => ({ ProjectPreparationStatus: () => null }));
mock.module("./java-launch-decision", () => ({ JavaLaunchDecisionBanner: () => null }));

const { default: RunPane } = await import("./run-pane");

let root: Root | undefined;
let container: HTMLDivElement | undefined;

const mountPane = () => {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root!.render(<RunPane />);
  });
};

// happy-dom computes no layout, so the scroll geometry the effect reads is
// stubbed per element: content grows to 600px in a 150px viewport.
const stubScrollGeometry = (element: Element) => {
  Object.defineProperty(element, "scrollHeight", { get: () => 600, configurable: true });
  Object.defineProperty(element, "clientHeight", { get: () => 150, configurable: true });
};

const scrollContainer = (): HTMLElement => {
  const node = [...(container?.querySelectorAll("div") ?? [])].find(
    (div) => String(div.className).includes("overflow-auto") && div.querySelector("pre"),
  );
  if (!node) throw new Error("run output scroll container was not rendered");
  return node as HTMLElement;
};

const setOutput = (text: string) => {
  act(() => {
    useRunStore.setState({ primaryOutput: text });
  });
};

const setPaneVisible = (visible: boolean) => {
  act(() => {
    useUIState.setState({ isBottomPaneVisible: visible });
  });
};

const clickToggle = () => {
  const button = document.querySelector('button[aria-label="run.scrollToEnd"]');
  if (!button) throw new Error("scroll-to-end toggle was not rendered");
  act(() => {
    button.dispatchEvent(new window.Event("click", { bubbles: true }));
  });
};

beforeAll(() => {
  mountPane();
  stubScrollGeometry(scrollContainer());
});

beforeEach(() => {
  useRunPreferencesStore.setState({ scrollOutputToEnd: true });
});

afterEach(() => {
  useRunPreferencesStore.setState({ scrollOutputToEnd: true });
  useUIState.setState({ isBottomPaneVisible: true });
});

afterAll(async () => {
  act(() => {
    root?.unmount();
  });
  container?.remove();
  // Let React's scheduler drain its pending macrotask before the DOM globals
  // go away, so a late callback does not crash against a closed window.
  await new Promise((resolve) => setTimeout(resolve, 50));
  actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActFlag;
  restoreDom();
});

test("pinned on: growing output keeps the view at the end", () => {
  scrollContainer().scrollTop = 0;
  setOutput("first line\nsecond line\n");

  expect(scrollContainer().scrollTop).toBe(600);
});

test("the toggle renders beside Clear output with localized tooltips", async () => {
  const toggle = document.querySelector('button[aria-label="run.scrollToEnd"]');
  const clear = document.querySelector('button[aria-label="run.clearOutput"]');
  expect(toggle).not.toBeNull();
  expect(clear).not.toBeNull();
  // The pin sits immediately to the left of Clear run output in the header.
  expect(toggle!.compareDocumentPosition(clear!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

  const { createTranslator } = await import("@/i18n/locale");
  expect(createTranslator("en-US")("run.scrollToEnd")).toBe("Always scroll output to the end");
  expect(createTranslator("zh-CN")("run.scrollToEnd")).toBe("输出始终滚动到最后一行");
});

test("pinned off: growing output leaves the user's scroll position alone", () => {
  clickToggle();
  expect(useRunPreferencesStore.getState().scrollOutputToEnd).toBe(false);

  scrollContainer().scrollTop = 42;
  setOutput("first line\nsecond line\nthird line\n");

  expect(scrollContainer().scrollTop).toBe(42);
});

test("hidden pane: output grows unseen, reopening scrolls back to the end", () => {
  scrollContainer().scrollTop = 42;

  setPaneVisible(false);
  setOutput("first line\nhidden growth\n");
  expect(scrollContainer().scrollTop).toBe(42);

  setPaneVisible(true);
  expect(scrollContainer().scrollTop).toBe(600);
});
