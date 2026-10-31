import { mock } from "bun:test";
import { act } from "react";
import { create } from "zustand";
import { createStore } from "zustand/vanilla";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  createWorkspaceScopedStore,
  useActiveWorkspaceId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { UIState } from "@/features/window/stores/ui-state.store";
import type { FunctionContext } from "../plugin-function-session";
import type { NativeContribution } from "./native-ui.types";

export const restoreDom = installHappyDom();
export const catalog = create(() => ({
  nativeWindows: [] as NativeContribution[],
}));
export const ui = createWorkspaceScopedStore("r13-test-ui", () =>
  createStore<UIState>(
    (set) =>
      ({
        isSidebarVisible: true,
        activeSidebarView: "files",
        isRightSidebarVisible: false,
        activeRightSidebarView: "agent",
        isBottomPaneVisible: false,
        bottomPaneActiveTab: "terminal",
        setActiveView: (activeSidebarView) => set({ activeSidebarView }),
        setActiveRightSidebarView: (activeRightSidebarView) => set({ activeRightSidebarView }),
        setBottomPaneActiveTab: (bottomPaneActiveTab) => set({ bottomPaneActiveTab }),
        setIsSidebarVisible: (isSidebarVisible) => set({ isSidebarVisible }),
        setIsRightSidebarVisible: (isRightSidebarVisible) => set({ isRightSidebarVisible }),
        setIsBottomPaneVisible: (isBottomPaneVisible) => set({ isBottomPaneVisible }),
      }) as UIState,
  ),
);

const settings = create(() => ({
  settings: {
    uiFontSize: 13,
    sidebarWidth: 260,
    rightToolWindowWidth: 300,
    terminalDockPosition: "right",
    terminalDockWidth: 400,
    bottomPaneHeight: 320,
    coreFeatures: { terminal: false, debugger: false },
  },
  actions: { updateSetting: () => {} },
}));
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
export let hostLabel = "main";
export function setHostLabel(label: string) {
  hostLabel = label;
}
const contexts = new Map<string, FunctionContext>();
let openGate: Promise<void> | undefined;
export function setOpenGate(gate?: Promise<void>) {
  openGate = gate;
}

// Keep NativeToolWindow, its owned typed port and real function sessions. Only
// the Tauri/native provider and unrelated workbench feature leaves are replaced.
mock.module("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ label: hostLabel }),
}));
mock.module("@/platform/tauri-core", () => ({
  invoke: async (command: string, input: any) => {
    if (command === "plugins.nativeUI.validateData")
      return { status: "ok", nodes: input.data.nodes };
    if (command === "declarative_plugins_native_function_open") {
      const entry = catalog
        .getState()
        .nativeWindows.find(
          (entry) => entry.pluginId === input.pluginId && entry.windowId === input.windowId,
        )!;
      const bindingId = `binding-${opened.length + 1}`;
      opened.push({
        bindingId,
        entry,
        path: input.workspacePath,
        host: hostLabel,
      });
      await openGate;
      return {
        bindingId,
        settingIdentity: "settings",
        packageIdentity: entry.packageIdentity,
      };
    }
    if (command === "declarative_plugins_native_function_close") {
      closed.push(input.bindingId);
      return;
    }
    if (command === "declarative_plugins_native_function_prepare") {
      const request = input.request;
      prepared.push(request);
      const binding = opened.find((entry) => entry.bindingId === request.bindingId)!;
      const context = {
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
      const context = contexts.get(input.operationId)!;
      const binding = opened.find((entry) =>
        context.actionId.startsWith(`__native__:${entry.bindingId}:`),
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
  createWebFunctionApproval: () => ({
    approve: async () => true,
    close: () => {},
  }),
}));
mock.module("@/features/plugins/declarative-plugin-ui", () => ({
  useDeclarativePluginUI: catalog,
}));
mock.module("@/features/window/stores/ui-state.store", () => ({
  useUIState: ui,
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: settings,
}));
mock.module("@/features/keymaps/hooks/use-command-shortcut", () => ({
  useCommandShortcut: () => undefined,
}));
mock.module("@/features/terminal/stores/terminal.store", () => ({
  useTerminalStore: create(() => ({ widthMode: "full" })),
}));
mock.module("@/features/window/stores/project.store", () => ({
  useProjectStore: (select: any) => select({ rootFolderPath: "/fixture/workspace" }),
}));
mock.module("@/features/panes/stores/pane.store", () => ({
  usePaneStore: {
    use: {
      bottomRoot: () => null,
      actions: () => ({ moveBufferToPane: () => {} }),
    },
  },
}));
mock.module("@/features/panes/utils/pane-tree", () => ({
  getAllPaneGroups: () => [],
}));
mock.module("@/features/panes/utils/pane-activation", () => ({
  activateBufferInPaneAndSync: () => {},
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: {
    use: { actions: () => ({ openTerminalBuffer: () => "" }) },
  },
}));
mock.module("@/config/backend-capabilities", () => ({
  isBackendCapabilityAvailable: () => false,
}));
for (const path of [
  "@/features/debugger/components/debugger-view",
  "@/features/diagnostics/components/diagnostics-buffer",
  "@/features/maven/components/maven-run-pane",
  "@/features/run/components/run-pane",
  "@/features/spring/components/spring-endpoints-pane",
  "@/features/terminal/components/terminal-container",
])
  mock.module(path, () => ({ default: () => null }));
mock.module("@/features/git/components/log/git-log-tool-window", () => ({
  GitLogToolWindow: () => null,
}));
mock.module("@/features/layout/components/bottom-pane/bottom-buffer-pane", () => ({
  BottomBufferPane: () => null,
}));

const { createRoot } = await import("react-dom/client");
const { LocaleProvider } = await import("@/i18n/locale-provider");
const { TerminalDockLayout } = await import("@/features/layout/components/terminal-dock-layout");
const { ResizablePane } = await import("@/features/layout/components/resizable-pane");
const { default: BottomPane } =
  await import("@/features/layout/components/bottom-pane/bottom-pane");
const { NativeToolWindowSlot } = await import("./native-tool-window-slot");
const { NativeContributionButton } = await import("./native-contribution-button");
const { nativePanelStates } = await import("./native-contributions");
// Preload the real lazy leaf to make React's module boundary deterministic.
await import("./native-tool-window");

function Workbench() {
  const workspaceId = useActiveWorkspaceId();
  const entries = catalog((state) => state.nativeWindows);
  const left = ui((state) => state.isSidebarVisible);
  const right = ui((state) => state.isRightSidebarVisible);
  return (
    <LocaleProvider language="en-US">
      <TerminalDockLayout
        workspaceKey={workspaceId}
        rightRail={
          <>
            {entries.map((entry) => (
              <NativeContributionButton key={entry.windowId} entry={entry} />
            ))}
          </>
        }
        sidebar={
          <ResizablePane position="left" widthKey="sidebarWidth" hidden={!left}>
            <NativeToolWindowSlot placement="left">
              <span>Files</span>
            </NativeToolWindowSlot>
          </ResizablePane>
        }
        tools={
          <ResizablePane position="right" widthKey="rightToolWindowWidth" hidden={!right}>
            <NativeToolWindowSlot placement="right">
              <span>Agent</span>
            </NativeToolWindowSlot>
          </ResizablePane>
        }
        editor={<input aria-label="Editor" />}
        panel={<BottomPane />}
      />
    </LocaleProvider>
  );
}

export async function mountWorkbench(entries: NativeContribution[]) {
  const environment = globalThis as typeof globalThis & {
    IS_REACT_ACT_ENVIRONMENT?: boolean;
  };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
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
  contexts.clear();
  openGate = undefined;
  hostLabel = "main";
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "r13-a", name: "Fixture", path: "/fixture/a" },
    "ready",
  );
  ui.setState(ui.getInitialState());
  catalog.setState({ nativeWindows: entries });
  for (const entry of entries) nativePanelStates.revoke(entry.pluginId);
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const close = async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      dimensions.forEach((key, index) =>
        previous[index]
          ? Object.defineProperty(HTMLElement.prototype, key, previous[index]!)
          : Reflect.deleteProperty(HTMLElement.prototype, key),
      );
      environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      for (const entry of entries) nativePanelStates.revoke(entry.pluginId);
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "workspace:welcome", name: "Files" },
        "empty",
      );
      for (const id of ["r13-a", "r13-b"]) workspaceRuntimeRegistry.removeWorkspace(id);
    }
  };
  try {
    await act(async () => root.render(<Workbench key={hostLabel} />));
  } catch (error) {
    await close();
    throw error;
  }
  return {
    host,
    close,
    render: () => act(async () => root.render(<Workbench key={hostLabel} />)),
  };
}
