import { mock } from "bun:test";
import { enableMapSet } from "immer";
import { act, useEffect } from "react";
import { create } from "zustand";
import { createStore } from "zustand/vanilla";
import { installHappyDom } from "@/test-utils/happy-dom";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { ProjectUiSession } from "@/features/window/stores/session.store";
import type { FunctionContext } from "../plugin-function-session";
import type { NativeContribution, NativeNode, NativeValue } from "./native-ui.types";

// Run this file's suite in its own Bun process: native I/O and unrelated leaves
// are replaced, while MainLayout, catalog, UI actions, slots and ports stay real.
export const restoreDom = installHappyDom();
enableMapSet();
// Zustand's Immer middleware uses the CommonJS entry under Bun.
require("immer").enableMapSet();
const noop = () => {};
const Empty = () => null;
mock.module("sonner", () => ({ toast: { warning: noop } }));
mock.module("@tauri-apps/plugin-os", () => ({
  platform: () => "windows",
  arch: () => "x86_64",
}));
const fileSystem = createWorkspaceScopedStore("r14-files", () =>
  createStore(() => ({ rootFolderPath: "/fixture/a" })),
);
const settings = create(() => ({
  settings: {
    displayLanguage: "en-US",
    uiFontSize: 13,
    sidebarWidth: 260,
    rightToolWindowWidth: 300,
    terminalDockPosition: "right",
    terminalDockWidth: 400,
    bottomPaneHeight: 320,
    hiddenSidebarActivityItems: [] as string[],
    coreFeatures: { terminal: true, debugger: false },
    showStatusBar: false,
    vimRelativeLineNumbers: false,
  },
  actions: { updateSetting: noop },
}));
export const savedUi = new Map<string, ProjectUiSession>();
export let hostLabel = "main";
export const setHostLabel = (label: string) => {
  hostLabel = label;
};
export let terminalMounts = 0;
export let terminalUnmounts = 0;
let entries: NativeContribution[] = [];
export function setEntries(next: NativeContribution[]) {
  entries = next;
}
export function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}
export const openGates = new Map<string, ReturnType<typeof gate>>();
export const closeGates = new Map<string, ReturnType<typeof gate>>();
export const opened: Array<{
  bindingId: string;
  entry: NativeContribution;
  path: string;
  host: string;
}> = [];
export const closed: string[] = [];
export const prepared: Array<{
  bindingId: string;
  actionId?: string;
  values?: unknown;
}> = [];
export const owners = new Map<string, string>();
const contexts = new Map<string, FunctionContext>();
const ownerKey = (binding: (typeof opened)[number]) =>
  JSON.stringify([binding.host, binding.path, binding.entry.pluginId, binding.entry.windowId]);
interface NativeInvokeInput {
  pluginId?: string;
  windowId?: string;
  workspacePath?: string;
  operationId?: string;
  bindingId?: string;
  data?: { nodes: NativeNode[] };
  request?: {
    bindingId: string;
    actionId?: string;
    operationId: string;
    values?: Record<string, NativeValue>;
  };
}

mock.module("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ label: hostLabel }),
}));
mock.module("@/platform/tauri-core", () => ({
  invoke: async (command: string, input: NativeInvokeInput) => {
    if (command === "declarative_plugins_state")
      return [...new Set(entries.map((entry) => entry.pluginId))].map((pluginId) => ({
        pluginId,
        displayName: pluginId,
        enabled: true,
        status: "accepted",
      }));
    if (command === "declarative_plugins_web_windows") return [];
    if (command === "declarative_plugins_native_windows") return entries;
    if (command === "declarative_plugins_manifest") return { ui: { commands: [] } };
    if (command === "plugins.nativeUI.validateData")
      return { status: "ok", nodes: input.data!.nodes };
    if (command === "declarative_plugins_native_function_open") {
      const entry = entries.find(
        (entry) => entry.pluginId === input.pluginId && entry.windowId === input.windowId,
      )!;
      const binding = {
        bindingId: `binding-${opened.length + 1}`,
        entry,
        path: input.workspacePath!,
        host: hostLabel,
      };
      opened.push(binding);
      owners.set(ownerKey(binding), binding.bindingId);
      await openGates.get(binding.bindingId)?.promise;
      return {
        bindingId: binding.bindingId,
        settingIdentity: "settings",
        packageIdentity: entry.packageIdentity,
      };
    }
    if (command === "declarative_plugins_native_function_close") {
      const binding = opened.find((binding) => binding.bindingId === input.bindingId)!;
      await closeGates.get(binding.bindingId)?.promise;
      closed.push(binding.bindingId);
      if (owners.get(ownerKey(binding)) === binding.bindingId) owners.delete(ownerKey(binding));
      return;
    }
    if (command === "declarative_plugins_native_function_prepare") {
      const request = input.request!;
      prepared.push(request);
      const binding = opened.find((binding) => binding.bindingId === request.bindingId)!;
      const context: FunctionContext = {
        pluginId: binding.entry.pluginId,
        actionId: `__native__:${binding.bindingId}:${request.actionId ?? ""}`,
        operationId: request.operationId,
        functionId: "fixture.load",
        workspacePath: binding.path,
        settingIdentity: "settings",
        window: binding.host,
        windowIncarnation: 1,
        generation: 1,
        packageIdentity: binding.entry.packageIdentity,
      };
      contexts.set(request.operationId, context);
      return {
        context,
        title: "Fixture",
        confirm: false,
        executesProjectCode: false,
        mayUseNetwork: false,
        program: {},
        launchPlan: {},
      };
    }
    if (command === "declarative_plugins_function_state") {
      const context = contexts.get(input.operationId!)!;
      const binding = opened.find((binding) =>
        context.actionId.startsWith(`__native__:${binding.bindingId}:`),
      )!;
      return {
        context,
        phase: "succeeded",
        result: { nodes: binding.entry.native.nodes },
      };
    }
    if (
      ["declarative_plugins_function_confirm", "declarative_plugins_function_cancel"].includes(
        command,
      )
    )
      return;
    throw new Error(`Unexpected native command: ${command}`);
  },
}));
mock.module("../plugin-web-function-approval", () => ({
  createWebFunctionApproval: () => ({ approve: async () => true, close: noop }),
}));
mock.module("../plugin-web-appearance", () => ({
  getPluginWebAppearance: noop,
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: settings,
}));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: fileSystem,
}));
mock.module("@/features/window/stores/project.store", () => ({
  useProjectStore: fileSystem,
}));
mock.module("@/features/workspace/persistence/workspace-session-repository", () => ({
  workspaceSessionRepository: {
    saveUi: (path: string, state: ProjectUiSession) => savedUi.set(path, structuredClone(state)),
    loadUi: (path: string) => savedUi.get(path),
  },
}));
mock.module("@/features/window/stores/workspace-pane-session", () => ({
  buildCurrentProjectPaneSession: noop,
  buildPaneLayoutFromSession: noop,
}));
const buffer = create(() => ({
  buffers: [],
  activeBufferId: null,
  actions: {
    openOnboardingBuffer: noop,
    openExtensionsBuffer: noop,
    closeBuffer: noop,
    openTerminalBuffer: noop,
  },
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: Object.assign(buffer, {
    use: { actions: () => buffer.getState().actions },
  }),
}));
mock.module("@/features/panes/stores/pane.store", () => ({
  usePaneStore: {
    use: {
      bottomRoot: () => null,
      actions: () => ({ moveBufferToPane: noop }),
    },
  },
}));
mock.module("@/features/panes/utils/pane-tree", () => ({
  getAllPaneGroups: () => [],
}));
mock.module("@/features/panes/utils/pane-activation", () => ({
  activateBufferInPaneAndSync: noop,
}));
mock.module("@/features/terminal/stores/terminal.store", () => ({
  useTerminalStore: create(() => ({ widthMode: "full" })),
}));
mock.module("@/config/backend-capabilities", () => ({
  isBackendCapabilityAvailable: (id: string) => id === "terminal",
}));
mock.module("@/features/terminal/components/terminal-container", () => ({
  default: ({ className }: { className?: string }) => {
    useEffect(() => {
      terminalMounts++;
      return () => {
        terminalUnmounts++;
      };
    }, []);
    return <div data-testid="terminal-session" className={className} />;
  },
}));
mock.module("@/features/build-systems/build-systems-service", () => ({
  useBuildSystemsCatalogStore: create(() => ({ entries: [] })),
}));
mock.module("@/features/build-systems/actions/build-system-tool-window-actions", () => ({
  toggleBuildSystemWindow: noop,
}));
mock.module("@/features/maven/stores/maven.store", () => ({
  useMavenStore: create(() => ({ projectStatus: "idle", project: null })),
}));
mock.module("@/features/keymaps/commands/view-command-actions", () => ({
  toggleMavenPane: noop,
  toggleTerminalPane: noop,
}));
mock.module("@/features/keymaps/hooks/use-command-shortcut", () => ({
  useCommandShortcut: noop,
}));
mock.module("@/features/vim/stores/vim.store", () => ({
  useVimStore: {
    use: {
      relativeLineNumbers: () => false,
      actions: () => ({ setRelativeLineNumbers: noop }),
    },
  },
}));
mock.module("@/features/onboarding/stores/onboarding.store", () => ({
  useOnboardingStore: create(() => ({
    isOpen: false,
    context: null,
    actions: { consumeOpenRequest: noop },
  })),
}));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({
  useWorkspaceTabsStore: {
    getState: () => ({ actions: { getActiveProjectTab: () => null } }),
  },
}));
mock.module("@/features/layout/components/sidebar/main-sidebar", () => ({
  MainSidebar: () => <div data-testid="files-sidebar" />,
  SidebarActivityRail: Empty,
}));

for (const [path, name] of [
  ["@/features/debugger/services/debug-adapter-events", "initializeDebuggerEventBridge"],
  ["@/features/maven/hooks/use-maven-resolution-problems", "useMavenResolutionNotifications"],
  ["@/features/panes/hooks/use-pane-keyboard", "usePaneKeyboard"],
  ["@/features/window/hooks/use-menu-events-wrapper", "useMenuEventsWrapper"],
  ["@/features/settings/hooks/use-auto-update", "useAutoUpdate"],
  ["@/features/bootstrap/startup-performance", "recordStartupMilestone"],
  ["@/features/editor/engines/monaco/language-contributions", "prewarmCommonLanguageTokenizers"],
  ["@/utils/frontend-trace", "frontendTrace"],
  ["@/features/maven/actions/maven-tool-window-actions", "closeMavenToolWindow"],
  ["@/features/agent/actions/agent-tool-window-actions", "closeAgentToolWindow"],
  [
    "@/features/notifications/actions/notifications-tool-window-actions",
    "closeNotificationsToolWindow",
  ],
] as const)
  mock.module(path, () => ({ [name]: noop }));
mock.module("@/features/file-system/hooks/use-file-system-folder-drop", () => ({
  useFileSystemFolderDrop: () => ({ isDraggingOver: false }),
}));
mock.module("@/features/file-system/controllers/platform", () => ({
  getSymlinkInfo: noop,
}));

for (const [path, name] of [
  ["@/features/git/runtime/git-status-refresh-host", "GitStatusRefreshHost"],
  ["@/features/panes/components/split-view-root", "CachedWorkspaceSplitViews"],
  ["@/features/references/components/references-popover", "ReferencesPopover"],
  ["@/features/notifications/components/notifications-tool-window", "NotificationsToolWindow"],
  ["@/features/notifications/components/notifications-trigger", "NotificationsTrigger"],
  ["@/features/agent/components/agent-trigger", "AgentTrigger"],
  ["@/features/window/components/pending-buffer-close-dialog", "PendingBufferCloseDialog"],
  ["@/features/window/components/project-tab-bar", "ProjectTabBar"],
  ["@/features/plugins/plugin-function-cleanup-notices", "PluginFunctionCleanupNotices"],
  ["@/features/layout/components/app-update-details-dialog", "AppUpdateDetailsDialog"],
  ["@/features/layout/components/welcome-screen", "WelcomeScreen"],
  ["@/features/file-system/components/project-name-menu", "ProjectNameMenu"],
  ["@/features/window/components/window-close-guard", "WindowCloseGuard"],
  ["@/extensions/ui/components/extension-dialog", "ExtensionDialogs"],
  ["@/features/terminal/components/terminal-host", "TerminalHost"],
  ["@/features/agent/components/agent-panel", "AgentPanel"],
  ["@/features/git/components/log/git-log-tool-window", "GitLogToolWindow"],
  ["@/features/layout/components/bottom-pane/bottom-buffer-pane", "BottomBufferPane"],
] as const)
  mock.module(path, () => ({ [name]: Empty }));
for (const path of [
  "@/features/window/components/title-bar/title-bar",
  "@/features/layout/components/footer/footer",
  "@/features/command-palette/components/command-palette",
  "@/features/quick-open/components/quick-open",
  "@/features/file-system/components/linux-folder-picker-dialog",
  "@/features/maven/components/maven-pane",
  "@/features/build-systems/components/build-system-pane",
  "@/features/debugger/components/debugger-view",
  "@/features/diagnostics/components/diagnostics-buffer",
  "@/features/maven/components/maven-run-pane",
  "@/features/run/components/run-pane",
  "@/features/spring/components/spring-endpoints-pane",
])
  mock.module(path, () => ({ default: Empty }));

export const { useUIState: ui } = await import("@/features/window/stores/ui-state.store");
export const {
  refreshDeclarativeUI,
  removeDeclarativeUI,
  useDeclarativePluginUI: catalog,
} = await import("../declarative-plugin-ui");
export const { nativePanelStates } = await import("./native-contributions");
const { MainLayout } = await import("@/features/layout/components/main-layout");
const { LocaleProvider } = await import("@/i18n/locale-provider");
const { createRoot } = await import("react-dom/client");
await import("./native-tool-window");
await import("@/features/layout/components/bottom-pane/bottom-pane");

export async function activate(id: "a" | "b") {
  const workspaceId = `r14-${id}`;
  ui.getStore(workspaceId);
  workspaceRuntimeRegistry.getStore("native-plugin-docking", workspaceId);
  fileSystem.getStore(workspaceId).setState({ rootFolderPath: `/fixture/${id}` });
  workspaceRuntimeRegistry.activateWorkspace(
    { id: workspaceId, name: id, path: `/fixture/${id}` },
    "ready",
  );
  workspaceRuntimeRegistry.updateWorkspaceStatus(workspaceId, "ready");
}

export async function mountMainLayout(initial: NativeContribution[]) {
  const environment = globalThis as typeof globalThis & {
    IS_REACT_ACT_ENVIRONMENT?: boolean;
  };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const frame = window.requestAnimationFrame;
  const cancelFrame = window.cancelAnimationFrame;
  const timeout = window.setTimeout;
  const frames = new Map<number, FrameRequestCallback>();
  const timers: Array<() => void> = [];
  // MainLayout defers BottomPane by one frame and one zero-delay task. Drive
  // that exact startup boundary; other component timers retain their owner.
  window.requestAnimationFrame = (callback) => {
    const id = frames.size + 1;
    frames.set(id, callback);
    return id;
  };
  window.cancelAnimationFrame = (id) => {
    frames.delete(id);
  };
  window.setTimeout = ((callback: TimerHandler, delay?: number, ...args: unknown[]) => {
    if (typeof callback !== "function")
      throw new TypeError("This test scheduler accepts function callbacks only");
    const invoke = () => callback(...args);
    if (delay === 0) {
      timers.push(invoke);
      return 0;
    }
    return timeout.call(window, invoke, delay);
  }) as typeof window.setTimeout;
  const dimensions = ["clientWidth", "clientHeight", "offsetWidth", "offsetHeight"] as const;
  const previous = dimensions.map((key) =>
    Object.getOwnPropertyDescriptor(HTMLElement.prototype, key),
  );
  for (const key of dimensions)
    Object.defineProperty(HTMLElement.prototype, key, {
      configurable: true,
      get: () => (key.endsWith("Height") ? 300 : 800),
    });
  opened.length = closed.length = prepared.length = 0;
  terminalMounts = terminalUnmounts = 0;
  contexts.clear();
  owners.clear();
  savedUi.clear();
  openGates.clear();
  closeGates.clear();
  hostLabel = "main";
  setEntries(initial);
  const host = document.createElement("div");
  document.body.append(host);
  let root = createRoot(host);
  const render = async () => {
    await act(async () =>
      root.render(
        <LocaleProvider language="en-US">
          <MainLayout />
        </LocaleProvider>,
      ),
    );
    await act(async () => {
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(0);
      for (const callback of timers.splice(0)) callback();
    });
  };
  const close = async () => {
    try {
      await act(async () => {
        for (const pending of [...openGates.values(), ...closeGates.values()]) pending.release();
        root.unmount();
      });
    } finally {
      host.remove();
      window.requestAnimationFrame = frame;
      window.cancelAnimationFrame = cancelFrame;
      window.setTimeout = timeout;
      frames.clear();
      timers.length = 0;
      dimensions.forEach((key, index) =>
        previous[index]
          ? Object.defineProperty(HTMLElement.prototype, key, previous[index]!)
          : Reflect.deleteProperty(HTMLElement.prototype, key),
      );
      for (const entry of [...initial, ...entries]) removeDeclarativeUI(entry.pluginId);
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "workspace:welcome", name: "Files" },
        "empty",
      );
      for (const id of ["r14-a", "r14-b"]) workspaceRuntimeRegistry.removeWorkspace(id);
      environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  };
  try {
    await activate("a");
    ui.setState(ui.getInitialState());
    await refreshDeclarativeUI();
    await render();
  } catch (error) {
    await close();
    throw error;
  }
  return {
    host,
    close,
    render,
    rebuild: async () => {
      await act(async () => root.unmount());
      root = createRoot(host);
      await render();
    },
  };
}
