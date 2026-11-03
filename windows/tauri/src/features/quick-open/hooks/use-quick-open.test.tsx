import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { EMPTY_SPRING_INDEX, type SpringIndex } from "@/features/spring/types/spring.types";
import { useSpringStore } from "@/features/spring/stores/spring.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { installHappyDom } from "@/test-utils/happy-dom";

const WORKSPACE_ID = "workspace-quick-open-endpoints";
const ROOT = "C:/work/demo";

mock.module("@/features/quick-open/hooks/use-file-loader", () => ({
  useFileLoader: () => ({
    files: [],
    hasLoadedFiles: true,
    isLoadingFiles: false,
    isIndexing: false,
    rootFolderPath: ROOT,
  }),
}));
mock.module("@/features/quick-open/hooks/use-symbol-search", () => ({
  useSymbolSearch: () => ({ symbols: [], isLoading: false }),
}));
mock.module("@/features/quick-open/hooks/use-workspace-symbol-search", () => ({
  useWorkspaceSymbolSearch: () => ({ symbols: [], isLoading: false }),
  getWorkspaceSymbolKey: () => "workspace-symbol",
}));
mock.module("@/features/editor/hooks/use-center-cursor", () => ({
  useCenterCursor: () => ({ centerCursorInViewport: () => {} }),
}));

const { useQuickOpen } = await import("./use-quick-open");

function endpointIndex(): SpringIndex {
  return {
    ...EMPTY_SPRING_INDEX,
    endpoints: [
      {
        id: "users",
        httpMethods: ["GET"],
        route: "/api/users",
        controller: "UserController",
        method: "listUsers",
        path: "src/main/java/UserController.java",
        line: 12,
        column: 3,
      },
    ],
  };
}

let restoreDom: (() => void) | undefined;
let container: HTMLDivElement;
let root: Root;
let previousActEnvironment: boolean | undefined;
let quickOpen: ReturnType<typeof useQuickOpen> | undefined;

beforeEach(() => {
  restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & {
    IS_REACT_ACT_ENVIRONMENT?: boolean;
  };
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
  });
  quickOpen = undefined;
  container.remove();
  workspaceRuntimeRegistry.resetForTests();
  const actEnvironment = globalThis as typeof globalThis & {
    IS_REACT_ACT_ENVIRONMENT?: boolean;
  };
  if (previousActEnvironment === undefined) {
    delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  } else {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
  restoreDom?.();
});

function Probe() {
  quickOpen = useQuickOpen();
  return null;
}

describe("useQuickOpen endpoint results", () => {
  test("searches Spring routes in the default mode and navigates to the controller line", async () => {
    const handleFileSelect = mock(async () => "buffer");
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_ID, name: "Quick open" }, "ready");
      useFileSystemStore.setState({ rootFolderPath: ROOT, handleFileSelect });
      useSpringStore.setState({
        requestedRoot: ROOT,
        root: ROOT,
        loadedRoot: ROOT,
        index: endpointIndex(),
        phase: "ready",
        error: null,
        isIndexing: false,
      });
      useUIState.setState({ isQuickOpenVisible: true });
      root.render(<Probe />);
    });

    await act(async () => {
      quickOpen?.setQuery("/api/users");
    });

    expect(quickOpen?.endpointResults).toHaveLength(1);
    expect(quickOpen?.endpointResults[0]?.endpoint.route).toBe("/api/users");

    await act(async () => {
      if (!quickOpen) return;
      quickOpen.handleInputKeyDown({
        key: "Enter",
        preventDefault: () => {},
      } as Parameters<typeof quickOpen.handleInputKeyDown>[0]);
    });

    expect(handleFileSelect).toHaveBeenCalledWith(
      "C:/work/demo/src/main/java/UserController.java",
      false,
      12,
      3,
      undefined,
      false,
    );
  });

  test("keeps route results out of symbol modes", async () => {
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_ID, name: "Quick open" }, "ready");
      useFileSystemStore.setState({ rootFolderPath: ROOT, handleFileSelect: async () => "buffer" });
      useSpringStore.setState({
        requestedRoot: ROOT,
        root: ROOT,
        loadedRoot: ROOT,
        index: endpointIndex(),
        phase: "ready",
        error: null,
        isIndexing: false,
      });
      useUIState.setState({ isQuickOpenVisible: true });
      root.render(<Probe />);
    });

    await act(async () => {
      quickOpen?.setQuery("#api/users");
    });

    expect(quickOpen?.endpointResults).toEqual([]);
  });

  test("hides endpoints after a same-root refresh fails", async () => {
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_ID, name: "Quick open" }, "ready");
      useFileSystemStore.setState({ rootFolderPath: ROOT, handleFileSelect: async () => "buffer" });
      useSpringStore.setState({
        requestedRoot: ROOT,
        root: ROOT,
        loadedRoot: ROOT,
        index: endpointIndex(),
        phase: "ready",
        error: null,
        isIndexing: false,
      });
      useUIState.setState({ isQuickOpenVisible: true });
      root.render(<Probe />);
    });

    await act(async () => {
      quickOpen?.setQuery("/api/users");
    });
    expect(quickOpen?.endpointResults).toHaveLength(1);

    await act(async () => {
      useSpringStore.setState({
        phase: "failed",
        error: { category: "indexFailed", detail: "refresh failed" },
        isIndexing: false,
      });
    });

    expect(quickOpen?.endpointResults).toEqual([]);
  });

  test("ignores endpoints loaded for another workspace root", async () => {
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_ID, name: "Quick open" }, "ready");
      useFileSystemStore.setState({ rootFolderPath: ROOT, handleFileSelect: async () => "buffer" });
      useSpringStore.setState({
        requestedRoot: "D:/other/demo",
        root: "D:/other/demo",
        loadedRoot: "D:/other/demo",
        index: endpointIndex(),
        phase: "ready",
        error: null,
        isIndexing: false,
      });
      useUIState.setState({ isQuickOpenVisible: true });
      root.render(<Probe />);
    });

    await act(async () => {
      quickOpen?.setQuery("/api/users");
    });

    expect(quickOpen?.endpointResults).toEqual([]);
  });
});
