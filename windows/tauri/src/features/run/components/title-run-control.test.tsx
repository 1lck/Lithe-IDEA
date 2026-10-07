import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { TooltipProvider } from "@/ui/tooltip";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useRunStore } from "../stores/run.store";
import { mapCoreConfiguration } from "../utils/run-configuration";
import * as events from "../hooks/use-run-process-events";
import { TitleRunControl } from "./title-run-control";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let previousRun: ReturnType<typeof useRunStore.getState>;
let previousFiles: ReturnType<typeof useFileSystemStore.getState>;
let previousUi: ReturnType<typeof useUIState.getState>;
let previousAct: PropertyDescriptor | undefined;
let listeners: ReturnType<typeof spyOn>;
let run: ReturnType<typeof spyOn>;
let stop: ReturnType<typeof spyOn>;
let load: ReturnType<typeof spyOn>;
const t = createTranslator("en-US");
const configuration = mapCoreConfiguration({
  id: "boot",
  name: "DemoApplication",
  provider: "spring-boot.main",
  execution: "service",
});
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    configurable: true,
    value: true,
  });
  previousRun = useRunStore.getState();
  previousFiles = useFileSystemStore.getState();
  previousUi = useUIState.getState();
  listeners = spyOn(events, "ensureRunProcessListeners").mockResolvedValue(undefined);
  run = spyOn(previousRun.actions, "runConfiguration").mockResolvedValue("slot-boot");
  stop = spyOn(previousRun.actions, "stop").mockResolvedValue(undefined);
  load = spyOn(previousRun.actions, "loadProject").mockResolvedValue(undefined);
  useFileSystemStore.setState({ rootFolderPath: "/workspace" });
  useRunStore.setState({
    root: "/workspace",
    status: "ready",
    configurations: [configuration],
    selectedConfigurationId: "boot",
    isLoading: false,
    isGenerating: false,
    diagnostics: [],
    sessions: [],
    primaryRunning: false,
    primaryPreparing: false,
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    listeners.mockRestore();
    run.mockRestore();
    stop.mockRestore();
    load.mockRestore();
    useRunStore.setState(previousRun, true);
    useFileSystemStore.setState(previousFiles);
    useUIState.setState(previousUi);
    container.remove();
    if (previousAct) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", previousAct);
    else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT");
    restoreDom();
  }
});
async function render() {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <TooltipProvider>
          <TitleRunControl />
        </TooltipProvider>
      </LocaleProvider>,
    ),
  );
}
test("recognized Spring Boot appears in the title selector and launches through the Run owner", async () => {
  await render();
  expect(container.textContent).toContain("DemoApplication");
  expect(container.querySelector('[data-run-icon="spring"]')).not.toBeNull();
  const button = container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.run")}"]`);
  expect(button?.disabled).toBe(false);
  await act(async () => button!.click());
  expect(run).toHaveBeenCalledWith("boot", undefined);
  expect(useUIState.getState().bottomPaneActiveTab).toBe("run");
});
test("stop owns the selected service, not a different background service", async () => {
  useRunStore.setState({
    sessions: [
      {
        id: "slot-boot",
        configurationId: "boot",
        title: "Boot",
        isRunning: true,
        output: "",
        exitCode: null,
      },
      {
        id: "slot-other",
        configurationId: "other",
        title: "Other",
        isRunning: true,
        output: "",
        exitCode: null,
      },
    ],
    selectedSessionId: "slot-other",
  });
  await render();
  await act(async () =>
    container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.stop")}"]`)!.click(),
  );
  expect(stop).toHaveBeenCalledWith("slot-boot", undefined);
});
test("loading or no matching configuration cannot start an unrelated target", async () => {
  useRunStore.setState({ selectedConfigurationId: "missing", isLoading: true });
  await render();
  expect(
    container.querySelector<HTMLButtonElement>(`button[aria-label="${t("run.run")}"]`)?.disabled,
  ).toBe(true);
  expect(run).not.toHaveBeenCalled();
});
test("closing the workspace removes the run controls", async () => {
  useFileSystemStore.setState({ rootFolderPath: undefined });
  await render();
  expect(container.querySelector('[data-testid="title-run-control"]')).toBeNull();
});

test("the configuration gear is removed while a separate Debug control is visible", async () => {
  await render();
  expect(container.querySelector(`button[aria-label="${t("javaRun.editRun")}"]`)).toBeNull();
  const debug = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${t("javaRun.debug")}"]`,
  );
  expect(debug).not.toBeNull();
  expect(debug?.disabled).toBe(true);
});

test("a recognized Java debug target enables Debug and a live Run displays independent Rerun and Stop", async () => {
  useRunStore.setState({
    configurations: [
      { ...configuration, debugAdapter: "jdwp", sourcePath: "src/DemoApplication.java" },
    ],
    sessions: [
      {
        id: "boot",
        configurationId: "boot",
        executionId: "owned-run",
        title: "Boot",
        isRunning: true,
        output: "",
        exitCode: null,
      },
    ],
  });
  await render();
  expect(
    container.querySelector<HTMLButtonElement>(`button[aria-label="${t("javaRun.debug")}"]`)
      ?.disabled,
  ).toBe(false);
  const rerun = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${t("javaRun.rerun")}"]`,
  );
  expect(rerun?.disabled).toBe(false);
  expect(container.querySelector(`button[aria-label="${t("run.stop")}"]`)).not.toBeNull();
  await act(async () => rerun!.click());
  expect(run).toHaveBeenCalledWith("boot", undefined);
  expect(stop).not.toHaveBeenCalled();
});
