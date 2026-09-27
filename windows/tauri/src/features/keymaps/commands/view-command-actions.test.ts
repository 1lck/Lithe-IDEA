import { afterEach, describe, expect, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { registerCommands } from "./command-registry";
import { toggleSpringEndpointsPane } from "./view-command-actions";
import { keymapRegistry } from "../utils/registry";

afterEach(() => {
  workspaceRuntimeRegistry.resetForTests();
});

describe("toggleSpringEndpointsPane", () => {
  test("opens and closes the Spring Endpoints bottom-pane tab", () => {
    useUIState.setState({
      isBottomPaneVisible: false,
      bottomPaneActiveTab: "terminal",
    });

    toggleSpringEndpointsPane();
    expect(useUIState.getState().isBottomPaneVisible).toBe(true);
    expect(useUIState.getState().bottomPaneActiveTab).toBe("springEndpoints");

    toggleSpringEndpointsPane();
    expect(useUIState.getState().isBottomPaneVisible).toBe(false);
    expect(useUIState.getState().bottomPaneActiveTab).toBe("springEndpoints");
  });
});

describe("Spring Endpoints command registration", () => {
  test("registers the workbench command", () => {
    registerCommands();
    expect(keymapRegistry.getCommand("workbench.toggleSpringEndpoints")).toMatchObject({
      title: "Toggle Spring Endpoints",
      category: "View",
    });
  });
});
