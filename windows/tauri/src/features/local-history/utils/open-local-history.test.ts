import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { useLocalHistoryStore } from "@/features/local-history/stores/local-history.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { toast } from "sonner";
import { canOpenProjectLocalHistory, openProjectLocalHistory } from "./open-local-history";

const restorers: Array<{ mockRestore: () => void }> = [];
let previousSettings: ReturnType<typeof useSettingsStore.getState>["settings"];

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "local-history-test", name: "Local History" },
    "ready",
  );
  previousSettings = useSettingsStore.getState().settings;
  useSettingsStore.setState({
    settings: { ...previousSettings, displayLanguage: "en-US" },
  });
});

afterEach(() => {
  for (const restorer of restorers.splice(0)) restorer.mockRestore();
  useSettingsStore.setState({ settings: previousSettings });
  workspaceRuntimeRegistry.resetForTests();
});

test.each([
  "",
  "remote://host/project",
  "wsl://Ubuntu/project",
  "diff://history/file",
  "file://project",
])("project local history rejects unsupported workspace paths: %s", (path) => {
  expect(canOpenProjectLocalHistory(path)).toBe(false);
  expect(canOpenProjectLocalHistory(null)).toBe(false);
  expect(canOpenProjectLocalHistory(undefined)).toBe(false);

  const warning = spyOn(toast, "warning").mockImplementation(() => "toast");
  const setTargetPath = spyOn(useLocalHistoryStore.getState().actions, "setTargetPath");
  const openView = spyOn(useUIState.getState(), "openCommandPaletteView");
  restorers.push(warning, setTargetPath, openView);

  openProjectLocalHistory(path);

  expect(warning).toHaveBeenCalledWith(
    "Project local history is only available for local workspaces.",
  );
  expect(setTargetPath).not.toHaveBeenCalled();
  expect(openView).not.toHaveBeenCalled();
});

test.each(["C:/project", "\\\\server\\share\\project", "//server/share/project"])(
  "project local history opens for a native local workspace: %s",
  (path) => {
    expect(canOpenProjectLocalHistory(path)).toBe(true);
    const setTargetPath = spyOn(
      useLocalHistoryStore.getState().actions,
      "setTargetPath",
    ).mockImplementation(() => {});
    const openView = spyOn(useUIState.getState(), "openCommandPaletteView").mockImplementation(
      () => {},
    );
    restorers.push(setTargetPath, openView);

    openProjectLocalHistory(path);

    expect(setTargetPath).toHaveBeenCalledWith(path, true);
    expect(openView).toHaveBeenCalledWith("local-history");
  },
);
