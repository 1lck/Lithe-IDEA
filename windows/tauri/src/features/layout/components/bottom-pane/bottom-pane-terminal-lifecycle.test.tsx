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
const writes: Array<[string, unknown]> = [];
const settings = create(() => ({
  settings: {
    coreFeatures: { terminal: true, debugger: false },
    terminalDockPosition: "bottom" as "bottom" | "right",
    terminalDockWidth: 400,
    bottomPaneHeight: 320,
  },
  actions: {
    updateSetting: (key: string, value: unknown) => {
      writes.push([key, value]);
      settings.setState((state) => ({ settings: { ...state.settings, [key]: value } }));
    },
  },
}));
const terminal = create(() => ({ widthMode: "full" as "full" | "editor" }));

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
  return (
    <>
      <button onClick={onFullScreen}>Fullscreen terminal</button>
      <input defaultValue="running session" />
      <TerminalDockHandle />
    </>
  );
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
  useSettingsStore: settings,
}));
mock.module("@/features/terminal/stores/terminal.store", () => ({ useTerminalStore: terminal }));
mock.module("@/features/keymaps/hooks/use-command-shortcut", () => ({
  useCommandShortcut: () => undefined,
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
const { TerminalDockLayout, TerminalDockHandle } = await import("../terminal-dock-layout");

async function dockFixture() {
  ui.setState({ isBottomPaneVisible: true, bottomPaneActiveTab: "terminal" });
  settings.setState((state) => ({
    settings: {
      ...state.settings,
      terminalDockPosition: "bottom",
      terminalDockWidth: 400,
      bottomPaneHeight: 320,
    },
  }));
  terminal.setState({ widthMode: "full" });
  writes.length = 0;
  launches.length = 0;
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const dimensionDescriptors = ["clientWidth", "clientHeight"].map(
    (key) => [key, Object.getOwnPropertyDescriptor(HTMLElement.prototype, key)] as const,
  );
  Object.defineProperty(HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get: () => 1000,
  });
  Object.defineProperty(HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get: () => 700,
  });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const render = async (workspaceKey = "project-a") =>
    act(async () =>
      root.render(
        <TerminalDockLayout
          workspaceKey={workspaceKey}
          sidebar={<span>Project</span>}
          tools={<span>Agent</span>}
          editor={<textarea defaultValue="editor" />}
          panel={<BottomPane />}
        />,
      ),
    );
  const destroy = async () => {
    await act(async () => root.unmount());
    host.remove();
    for (const [key, descriptor] of dimensionDescriptors) {
      if (descriptor) Object.defineProperty(HTMLElement.prototype, key, descriptor);
      else Reflect.deleteProperty(HTMLElement.prototype, key);
    }
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  };
  try {
    await render();
    const grid = host.querySelector<HTMLDivElement>("[data-terminal-dock]")!;
    grid.getBoundingClientRect = () => new DOMRect(100, 80, 1000, 700);
    (grid.children[1] as HTMLElement).getBoundingClientRect = () => new DOMRect(200, 80, 700, 380);
    (grid.children[3] as HTMLElement).getBoundingClientRect = () =>
      settings.getState().settings.terminalDockPosition === "right"
        ? new DOMRect(700, 80, 400, 700)
        : new DOMRect(100, 460, 1000, 320);
    const pointer = async (type: string, x: number, y: number, element: EventTarget = document) =>
      act(async () => {
        element.dispatchEvent(
          new window.PointerEvent(type, {
            bubbles: true,
            button: 0,
            pointerId: 1,
            clientX: x,
            clientY: y,
          }),
        );
      });
    const begin = () =>
      pointer("pointerdown", 400, 470, host.querySelector('[aria-label="terminal.movePanel"]')!);
    return { host, grid, root, render, destroy, pointer, begin };
  } catch (error) {
    await destroy();
    throw error;
  }
}

test("bottom/right docking commits only on drop and keeps the terminal DOM, input, listener and editor", async () => {
  const fixture = await dockFixture();
  const { host, grid, begin, pointer } = fixture;
  try {
    const input = host.querySelector("input")!;
    input.value = "unfinished command";
    const editor = host.querySelector("textarea");
    const initialMounts = mounts;
    const initialUnmounts = unmounts;
    await begin();
    await pointer("pointermove", 1000, 180);
    expect(host.querySelector('[data-terminal-dock-preview="right"]')).not.toBeNull();
    expect(writes).toEqual([]);
    expect(grid.dataset.terminalDock).toBe("bottom");
    await pointer("pointerup", 1000, 180);
    expect(writes).toEqual([["terminalDockPosition", "right"]]);
    await act(async () =>
      host
        .querySelector('[aria-label="terminal.movePanel"]')!
        .dispatchEvent(new window.MouseEvent("click", { bubbles: true, detail: 1 })),
    );
    expect(writes).toHaveLength(1);
    expect(grid.dataset.terminalDock).toBe("right");
    expect(host.querySelector('[role="separator"]')?.getAttribute("aria-orientation")).toBe(
      "vertical",
    );
    await begin();
    await pointer("pointermove", 400, 700);
    expect(host.querySelector('[data-terminal-dock-preview="bottom"]')).not.toBeNull();
    await pointer("pointerup", 400, 700);
    expect(grid.dataset.terminalDock).toBe("bottom");
    await act(async () => terminal.setState({ widthMode: "editor" }));
    expect(grid.style.gridTemplateAreas).toContain('"sidebar panel tools"');
    await act(async () => ui.getState().setIsBottomPaneVisible(false));
    await act(async () => requestNewTerminal("C:/same-session"));
    expect(host.querySelector("input")).toBe(input);
    expect(input.value).toBe("unfinished command");
    expect(host.querySelector("textarea")).toBe(editor);
    expect(mounts).toBe(initialMounts);
    expect(unmounts).toBe(initialUnmounts);
    expect(launches).toEqual(["C:/same-session"]);
  } finally {
    await fixture.destroy();
  }
});

test.each([
  "escape",
  "outside",
  "invalid",
  "blur",
  "pointercancel",
  "workspace",
  "unmount",
  "resize",
])(
  "terminal docking cancels on %s without persisting or accepting a stale release",
  async (reason) => {
    const fixture = await dockFixture();
    try {
      await fixture.begin();
      await fixture.pointer("pointermove", 1000, 180);
      await act(async () => {
        if (reason === "escape")
          document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
        if (reason === "blur" || reason === "resize")
          window.dispatchEvent(new window.Event(reason));
      });
      if (reason === "pointercancel") await fixture.pointer("pointercancel", 1000, 180);
      if (reason === "workspace") await fixture.render("project-b");
      if (reason === "unmount") await act(async () => fixture.root.unmount());
      await fixture.pointer(
        "pointerup",
        reason === "outside" ? 1200 : reason === "invalid" ? 400 : 1000,
        180,
      );
      expect(writes).toEqual([]);
      expect(fixture.host.querySelector("[data-terminal-dock-preview]")).toBeNull();
      expect(document.body.style.cursor).toBe("");
      expect(document.body.style.userSelect).toBe("");
    } finally {
      // React root.unmount is idempotent; destroy also restores fixture-owned DOM globals.
      await fixture.destroy();
    }
  },
);

test("terminal docking supports a keyboard click, bounded resizing and other tools staying at bottom", async () => {
  const fixture = await dockFixture();
  try {
    await act(async () =>
      fixture.host.querySelector<HTMLButtonElement>('[aria-label="terminal.movePanel"]')!.click(),
    );
    expect(fixture.grid.dataset.terminalDock).toBe("right");
    writes.length = 0;
    const input = fixture.host.querySelector("input");
    await fixture.pointer(
      "pointerdown",
      700,
      200,
      fixture.host.querySelector('[role="separator"]')!,
    );
    await fixture.pointer("pointermove", -5000, 200);
    expect(writes).toEqual([]);
    await fixture.pointer("pointerup", -5000, 200);
    expect(writes).toEqual([["terminalDockWidth", 640]]);
    await act(async () => ui.getState().setBottomPaneActiveTab("run"));
    expect(fixture.grid.dataset.terminalDock).toBe("bottom");
    expect(fixture.host.querySelector('[role="separator"]')?.getAttribute("aria-orientation")).toBe(
      "horizontal",
    );
    await act(async () => ui.getState().setBottomPaneActiveTab("terminal"));
    expect(fixture.grid.dataset.terminalDock).toBe("right");
    expect(fixture.host.querySelector("input")).toBe(input);
  } finally {
    await fixture.destroy();
  }
});

test("bottom resizing follows Y, commits once and cancels a resize when the panel hides", async () => {
  const fixture = await dockFixture();
  try {
    const separator = () => fixture.host.querySelector('[role="separator"]')!;
    await fixture.pointer("pointerdown", 200, 460, separator());
    await fixture.pointer("pointermove", 900, 360);
    expect(writes).toEqual([]);
    await fixture.pointer("pointerup", 900, 360);
    expect(writes).toEqual([["bottomPaneHeight", 420]]);
    writes.length = 0;
    await fixture.pointer("pointerdown", 200, 360, separator());
    await fixture.pointer("pointermove", 200, -1000);
    await act(async () => ui.getState().setIsBottomPaneVisible(false));
    await fixture.pointer("pointerup", 200, -1000);
    expect(writes).toEqual([]);
    expect(document.body.style.cursor).toBe("");
  } finally {
    await fixture.destroy();
  }
});

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
