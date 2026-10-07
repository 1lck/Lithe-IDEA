import type { StoreApi } from "zustand";
import { getActiveSidebarView } from "@/features/layout/utils/sidebar-pane-utils";
import type { WorkspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  buildWindowTitleContext,
  type WindowTitleBufferState,
  type WindowTitlePaneState,
  type WindowTitleProject,
} from "../utils/window-title-context";

interface WindowTitleSourceDependencies {
  registry: Pick<WorkspaceRuntimeRegistry, "getActiveWorkspaceId" | "getWorkspace" | "subscribe">;
  tabs: {
    getState: () => { projectTabs: readonly WindowTitleProject[] };
    subscribe: (listener: () => void) => () => void;
  };
  keyboardContext?: {
    getState: () => { contexts: { terminalFocus?: boolean } };
    subscribe: (listener: () => void) => () => void;
  };
  focus?: {
    isSidebarFocused: () => boolean;
    subscribe: (listener: () => void) => () => void;
  };
}

export interface WindowTitleSidebarState {
  isSidebarVisible: boolean;
  isGitViewActive: boolean;
  isGitHubPRsViewActive: boolean;
  activeSidebarView?: string;
}

const PANE_STORE_KEY = "pane";
const BUFFER_STORE_KEY = "editor-buffer";
const UI_STORE_KEY = "window-ui";

export function createWindowTitleSource({ registry, tabs, keyboardContext, focus }: WindowTitleSourceDependencies) {
  return {
    readContext: () => {
      const workspaceId = registry.getActiveWorkspaceId();
      const runtime = registry.getWorkspace(workspaceId);
      const panes = runtime?.stores.get(PANE_STORE_KEY) as StoreApi<WindowTitlePaneState> | undefined;
      const buffers = runtime?.stores.get(BUFFER_STORE_KEY) as StoreApi<WindowTitleBufferState> | undefined;
      const context = buildWindowTitleContext({
        projects: tabs.getState().projectTabs,
        workspaceId,
        status: runtime?.status,
        panes: panes?.getState(),
        buffers: buffers?.getState(),
      });
      // 底部终端使用独立标签状态，只读现有键盘焦点，不改变编辑器活动分屏。
      if (keyboardContext?.getState().contexts.terminalFocus) context.fileName = null;
      const ui = (runtime?.stores.get(UI_STORE_KEY) as StoreApi<WindowTitleSidebarState> | undefined)?.getState();
      if (ui?.isSidebarVisible && getActiveSidebarView(ui) === "search" && focus?.isSidebarFocused()) {
        context.fileName = null;
      }
      return context;
    },
    subscribe: (listener: (force?: boolean) => void) => {
      let paneStore: StoreApi<unknown> | undefined;
      let bufferStore: StoreApi<unknown> | undefined;
      let unsubscribePane: (() => void) | undefined;
      let unsubscribeBuffer: (() => void) | undefined;
      let uiStore: StoreApi<unknown> | undefined;
      let unsubscribeUi: (() => void) | undefined;
      let lifecycleKey: string;
      const changed = () => listener();

      const bindActiveStores = () => {
        const runtime = registry.getWorkspace(registry.getActiveWorkspaceId());
        const nextPaneStore = runtime?.stores.get(PANE_STORE_KEY);
        const nextBufferStore = runtime?.stores.get(BUFFER_STORE_KEY);
        if (nextPaneStore !== paneStore) {
          unsubscribePane?.();
          paneStore = nextPaneStore;
          unsubscribePane = paneStore?.subscribe(changed);
        }
        if (nextBufferStore !== bufferStore) {
          unsubscribeBuffer?.();
          bufferStore = nextBufferStore;
          unsubscribeBuffer = bufferStore?.subscribe(changed);
        }
        const nextUiStore = runtime?.stores.get(UI_STORE_KEY);
        if (nextUiStore !== uiStore) {
          unsubscribeUi?.();
          uiStore = nextUiStore;
          unsubscribeUi = uiStore?.subscribe(changed);
        }
      };
      // 初始化登记可能变化而标题文本不变，此时仍需宿主重新读取身份快照。
      const readLifecycleKey = () => JSON.stringify(tabs.getState().projectTabs.map(({ id }) => [id, registry.getWorkspace(id)?.status]));

      // 仅观察已经创建的工作区状态，不为窗口标题初始化编辑器或项目运行时。
      bindActiveStores();
      lifecycleKey = readLifecycleKey();
      const unsubscribeRegistry = registry.subscribe(() => {
        bindActiveStores();
        const nextLifecycleKey = readLifecycleKey();
        const force = nextLifecycleKey !== lifecycleKey;
        lifecycleKey = nextLifecycleKey;
        listener(force);
      });
      const unsubscribeTabs = tabs.subscribe(changed);
      const unsubscribeFocus = focus?.subscribe(changed);
      let terminalFocus = keyboardContext?.getState().contexts.terminalFocus;
      const unsubscribeKeyboard = keyboardContext?.subscribe(() => {
        const nextTerminalFocus = keyboardContext.getState().contexts.terminalFocus;
        if (nextTerminalFocus === terminalFocus) return;
        terminalFocus = nextTerminalFocus;
        listener();
      });

      return () => {
        unsubscribeRegistry();
        unsubscribeTabs();
        unsubscribeKeyboard?.();
        unsubscribeFocus?.();
        unsubscribeUi?.();
        unsubscribePane?.();
        unsubscribeBuffer?.();
      };
    },
  };
}
