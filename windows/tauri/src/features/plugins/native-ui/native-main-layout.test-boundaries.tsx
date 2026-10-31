import { enableMapSet } from "immer";
import { useEffect } from "react";
import { create } from "zustand";
import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import type { ProjectUiSession } from "@/features/window/stores/session.store";
import type { ProjectTab } from "@/features/window/stores/workspace-tabs.store";
import type { FunctionContext } from "../plugin-function-session";
import type { NativeContribution, NativeNode, NativeValue } from "./native-ui.types";
import type { DeclarativeWebToolWindow } from "../declarative-plugin-launch";

// Only native I/O and unrelated workbench leaves are controlled. Both Bun and
// Edge consume these same boundary doubles; layout, catalog, docking, native
// sessions and function ownership remain production modules.
enableMapSet();
export const workbenchBoundaryModules = new Map<string, Record<string, unknown>>();
const mock = {
  module(id: string, factory: () => Record<string, unknown>) {
    workbenchBoundaryModules.set(id, factory());
  },
};
const noop = () => {};
const Empty = () => null;
mock.module("sonner", () => ({ toast: { warning: noop } }));
mock.module("@tauri-apps/plugin-os", () => ({
  platform: () => "windows",
  arch: () => "x86_64",
}));
let workspaceSwitcher: ((id: string) => void) | undefined;
export const setWorkspaceSwitcher = (switcher: ((id: string) => void) | undefined) => {
  workspaceSwitcher = switcher;
};
export const fileSystem = createWorkspaceScopedStore("r14-files", () =>
  createStore(() => ({
    rootFolderPath: "/fixture/a",
    isSwitchingProject: false,
    switchToProject: async (id: string) => workspaceSwitcher?.(id),
    closeProject: async () => {
      throw new Error("Project close is outside this fixture");
    },
  })),
);
export const workspaceTabs = create<{
  projectTabs: ProjectTab[];
  actions: { getActiveProjectTab(): ProjectTab | undefined };
}>((_set, get) => ({
  projectTabs: [],
  actions: {
    getActiveProjectTab: (): ProjectTab | undefined =>
      get().projectTabs.find((tab) => tab.isActive),
  },
}));
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
export let entries: NativeContribution[] = [];
export function setEntries(next: NativeContribution[]) {
  entries = next;
}
export let webEntries: DeclarativeWebToolWindow[] = [];
export function setWebEntries(next: DeclarativeWebToolWindow[]) {
  webEntries = next;
}
export const webOpened: Array<{
  mountId: string;
  pluginId: string;
  path: string;
  packageIdentity: string;
  bounds: unknown;
}> = [];
export const webClosed: string[] = [];
export const webLayouts: Array<{ mountId: string; visible: boolean }> = [];
export function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}
export const openGates = new Map<string, ReturnType<typeof gate>>();
export const prepareGates = new Map<string, ReturnType<typeof gate>>();
export const cancelled: string[] = [];
export const confirmed: string[] = [];
export const reads: string[] = [];
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
  selectedId?: string | null;
  operationId?: string;
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
  mountId?: string;
  expectedPackageIdentity?: string;
  bounds?: unknown;
  visible?: boolean;
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
      return [...new Set([...entries, ...webEntries].map((entry) => entry.pluginId))].map(
        (pluginId) => ({
          pluginId,
          displayName: pluginId,
          enabled: true,
          status: "accepted",
        }),
      );
    if (command === "declarative_plugins_web_windows") return webEntries;
    if (command === "declarative_plugins_native_windows") return entries;
    if (command === "declarative_plugins_mount_web_window") {
      const mountId = `web-${webOpened.length + 1}`;
      webOpened.push({
        mountId,
        pluginId: input.pluginId!,
        path: input.workspacePath!,
        packageIdentity: input.expectedPackageIdentity!,
        bounds: input.bounds,
      });
      await openGates.get(mountId)?.promise;
      return { mountId };
    }
    if (command === "declarative_plugins_layout_web_window") {
      webLayouts.push({ mountId: input.mountId!, visible: input.visible! });
      return;
    }
    if (command === "declarative_plugins_unmount_web_window") {
      await closeGates.get(input.mountId!)?.promise;
      webClosed.push(input.mountId!);
      return;
    }
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
      if (request.actionId) await prepareGates.get(binding.bindingId)?.promise;
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
      reads.push(input.operationId!);
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
    if (command === "declarative_plugins_function_cancel") {
      cancelled.push(input.operationId!);
      return;
    }
    if (command === "declarative_plugins_function_confirm") {
      confirmed.push(input.operationId!);
      return;
    }
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
  useWorkspaceTabsStore: Object.assign(workspaceTabs, {
    use: { projectTabs: () => workspaceTabs((state) => state.projectTabs) },
  }),
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
  getSymlinkInfo: async (path: string) => {
    if (path !== "/fixture/a" && path !== "/fixture/b") throw new Error("Unknown fixture path");
    return { is_dir: true };
  },
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

export function resetWorkbenchBoundaries(
  initial: NativeContribution[],
  webInitial: DeclarativeWebToolWindow[] = [],
) {
  opened.length = closed.length = prepared.length = 0;
  webOpened.length = webClosed.length = 0;
  webLayouts.length = 0;
  terminalMounts = terminalUnmounts = 0;
  contexts.clear();
  owners.clear();
  savedUi.clear();
  prepareGates.clear();
  cancelled.length = 0;
  confirmed.length = reads.length = 0;
  openGates.clear();
  closeGates.clear();
  hostLabel = "main";
  workspaceSwitcher = undefined;
  workspaceTabs.setState({ projectTabs: [] });
  setEntries(initial);
  setWebEntries(webInitial);
}
