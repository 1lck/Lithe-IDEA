import { mock } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { NativeContribution } from "./native-ui.types";
import type { DeclarativeWebToolWindow } from "../declarative-plugin-launch";
import {
  fileSystem,
  entries,
  webEntries,
  openGates,
  closeGates,
  prepareGates,
  resetWorkbenchBoundaries,
  workbenchBoundaryModules,
} from "./native-main-layout.test-boundaries";
export {
  savedUi,
  hostLabel,
  setHostLabel,
  terminalMounts,
  terminalUnmounts,
  setEntries,
  setWebEntries,
  webOpened,
  webClosed,
  webLayouts,
  gate,
  opened,
  closed,
  prepared,
  owners,
  openGates,
  closeGates,
  prepareGates,
  cancelled,
  confirmed,
  reads,
} from "./native-main-layout.test-boundaries";
export const restoreDom = installHappyDom();
require("immer").enableMapSet();
for (const [id, exports] of workbenchBoundaryModules) mock.module(id, () => exports);
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

export async function mountMainLayout(
  initial: NativeContribution[],
  webInitial: DeclarativeWebToolWindow[] = [],
) {
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
  resetWorkbenchBoundaries(initial, webInitial);
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
        for (const pending of [
          ...openGates.values(),
          ...closeGates.values(),
          ...prepareGates.values(),
        ])
          pending.release();
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
      for (const entry of [...initial, ...entries, ...webInitial, ...webEntries])
        removeDeclarativeUI(entry.pluginId);
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
