import { afterAll, expect, mock, test } from "bun:test";
import { act, useEffect } from "react";
import { create } from "zustand";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  createNewTerminalEventHandler,
  requestNewTerminal,
} from "@/features/terminal/utils/terminal-launch-actions";
import { openNewTerminalFromGlobalEntry } from "@/features/terminal/utils/terminal-pane-visibility";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");

const ui = create<{
  isBottomPaneVisible: boolean;
  bottomPaneActiveTab: string;
  setIsBottomPaneVisible: (visible: boolean) => void;
  setBottomPaneActiveTab: (tab: string) => void;
}>((set) => ({
  isBottomPaneVisible: true,
  bottomPaneActiveTab: "terminal",
  setIsBottomPaneVisible: (isBottomPaneVisible) => set({ isBottomPaneVisible }),
  setBottomPaneActiveTab: (bottomPaneActiveTab) => set({ bottomPaneActiveTab }),
}));
let mounts = 0;
let unmounts = 0;
const launches: Array<string | undefined> = [];

// Keep the real BottomPane and fullscreen surface. The terminal leaf replaces
// xterm/native PTYs but owns the same production event subscription boundary.
function TerminalProbe({ onFullScreen }: { onFullScreen: () => void }) {
  useEffect(() => {
    mounts++;
    const handler = createNewTerminalEventHandler((directory) => {
      openNewTerminalFromGlobalEntry({
        createTerminal: () => launches.push(directory),
        setBottomPaneActiveTab: ui.getState().setBottomPaneActiveTab,
        setIsBottomPaneVisible: ui.getState().setIsBottomPaneVisible,
      });
    });
    window.addEventListener("terminal-new", handler);
    return () => {
      unmounts++;
      window.removeEventListener("terminal-new", handler);
    };
  }, []);
  return <button onClick={onFullScreen}>Fullscreen terminal</button>;
}

mock.module("@/features/terminal/components/terminal-container", () => ({
  default: TerminalProbe,
}));
mock.module("@/features/window/stores/ui-state.store", () => ({ useUIState: ui }));
mock.module("@/features/window/stores/project.store", () => ({
  useProjectStore: (select: (state: { rootFolderPath: string }) => unknown) =>
    select({ rootFolderPath: "C:/fixture/project" }),
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: (
    select: (state: {
      settings: { coreFeatures: { terminal: boolean; debugger: boolean } };
    }) => unknown,
  ) => select({ settings: { coreFeatures: { terminal: true, debugger: false } } }),
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: {
    use: { actions: () => ({ moveBufferToPane: () => {}, openTerminalBuffer: () => "" }) },
  },
}));
mock.module("@/features/panes/stores/pane.store", () => ({
  usePaneStore: {
    use: { bottomRoot: () => null, actions: () => ({ moveBufferToPane: () => {} }) },
  },
}));
mock.module("@/features/panes/utils/pane-tree", () => ({ getAllPaneGroups: () => [] }));
mock.module("@/features/panes/utils/pane-activation", () => ({
  activateBufferInPaneAndSync: () => {},
}));
mock.module("@/config/backend-capabilities", () => ({
  isBackendCapabilityAvailable: (name: string) => name === "terminal",
}));
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));
mock.module("@/features/debugger/components/debugger-view", () => ({ default: () => null }));
mock.module("@/features/diagnostics/components/diagnostics-buffer", () => ({
  default: () => null,
}));
mock.module("@/features/maven/components/maven-run-pane", () => ({ default: () => null }));
mock.module("@/features/run/components/run-pane", () => ({ default: () => null }));
mock.module("@/features/spring/components/spring-endpoints-pane", () => ({ default: () => null }));
mock.module("@/features/git/components/log/git-log-tool-window", () => ({
  GitLogToolWindow: () => null,
}));
mock.module("./bottom-buffer-pane", () => ({ BottomBufferPane: () => null }));
mock.module("@/features/tabs/utils/internal-tab-drag", () => ({
  clearInternalTabDragData: () => {},
  getInternalTabDragData: () => null,
  getInternalTabDragHover: () => ({ paneId: null }),
}));
const { default: BottomPane } = await import("./bottom-pane");

test.each(["folder", "global"] as const)(
  "a hidden fullscreen panel retains the %s terminal request listener",
  async (entry) => {
    ui.setState({ isBottomPaneVisible: true, bottomPaneActiveTab: "terminal" });
    launches.length = 0;
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    try {
      await act(async () => root.render(<BottomPane />));
      await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
      const mountsBeforeHide = mounts;
      const unmountsBeforeHide = unmounts;
      expect(host.querySelector('[data-slot="workbench-fullscreen-surface"]')).not.toBeNull();
      // This is the visibility change used by the menu/shortcut toggle, rather
      // than the terminal's own minimize button that also resets fullscreen.
      await act(async () => ui.getState().setIsBottomPaneVisible(false));
      expect(
        host.querySelector('[data-slot="workbench-fullscreen-surface"]')?.hasAttribute("hidden"),
      ).toBe(true);
      expect(unmounts).toBe(unmountsBeforeHide);
      await act(async () => {
        if (entry === "folder") requestNewTerminal("C:/fixture/project/selected folder");
        else window.dispatchEvent(new window.CustomEvent("terminal-new"));
      });
      expect(ui.getState().isBottomPaneVisible).toBe(true);
      expect(launches).toEqual([
        entry === "folder" ? "C:/fixture/project/selected folder" : undefined,
      ]);
      expect(
        host.querySelector('[data-slot="workbench-fullscreen-surface"]')?.hasAttribute("hidden"),
      ).toBe(false);
      expect(mounts).toBe(mountsBeforeHide);
    } finally {
      try {
        await act(async () => root.unmount());
      } finally {
        host.remove();
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      }
    }
  },
);
