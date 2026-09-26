import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { EMPTY_SPRING_INDEX, type SpringIndex, type SpringIndexError } from "../types/spring.types";
import { useSpringStore } from "../stores/spring.store";
import { SpringEndpointsPane } from "./spring-endpoints-pane";

const WORKSPACE_ID = "workspace-spring-endpoints";
const ROOT = "C:/work/demo";

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

async function setSpringState(update: {
  phase: "idle" | "loading" | "ready" | "failed";
  loadedRoot: string | null;
  index?: SpringIndex;
  error?: SpringIndexError | null;
}) {
  await act(async () => {
    workspaceRuntimeRegistry.activateWorkspace(
      { id: WORKSPACE_ID, name: "Spring endpoints test" },
      "ready",
    );
    useSpringStore.setState({
      requestedRoot: ROOT,
      loadedRoot: update.loadedRoot,
      root: ROOT,
      index: update.index ?? EMPTY_SPRING_INDEX,
      phase: update.phase,
      error: update.error ?? null,
      isIndexing: update.phase === "loading",
    });
    useFileSystemStore.setState({ rootFolderPath: ROOT });
  });
}

let restoreDom: (() => void) | undefined;
let container: HTMLDivElement;
let root: Root;
let previousActEnvironment: boolean | undefined;

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

async function renderPane(): Promise<void> {
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <SpringEndpointsPane />
      </LocaleProvider>,
    );
  });
}

describe("SpringEndpointsPane", () => {
  test("renders initial loading, successful empty, and failure states distinctly", async () => {
    await setSpringState({ phase: "loading", loadedRoot: null });
    await renderPane();
    expect(container.textContent).toContain("Indexing Spring project...");

    await setSpringState({ phase: "ready", loadedRoot: ROOT });
    await renderPane();
    expect(container.textContent).toContain("No Spring MVC endpoints found");

    await setSpringState({
      phase: "failed",
      loadedRoot: null,
      error: { category: "rootUnavailable", detail: "C:/private/workspace" },
    });
    await renderPane();
    expect(container.textContent).toContain("The Spring workspace root is unavailable.");
    expect(container.textContent).not.toContain("C:/private/workspace");
  });

  test("renders endpoint rows and keeps them visible during refresh or stale refresh", async () => {
    const index = endpointIndex();
    await setSpringState({ phase: "ready", loadedRoot: ROOT, index });
    await renderPane();
    expect(container.textContent).toContain("1 route");
    expect(container.textContent).toContain("/api/users");
    expect(container.textContent).toContain("UserController.listUsers");
    expect(container.textContent).toContain("src/main/java/UserController.java");

    await setSpringState({ phase: "loading", loadedRoot: ROOT, index });
    await renderPane();
    expect(container.textContent).toContain("/api/users");
    expect(container.textContent).toContain("Updating Spring endpoints...");

    await setSpringState({
      phase: "failed",
      loadedRoot: ROOT,
      index,
      error: { category: "indexFailed", detail: "refresh failed" },
    });
    await renderPane();
    expect(container.textContent).toContain("/api/users");
    expect(container.textContent).toContain("Showing the last successful Spring index.");
  });

  test("keeps the filter input stable and clears it when the workspace root changes", async () => {
    await setSpringState({ phase: "ready", loadedRoot: ROOT, index: endpointIndex() });
    await renderPane();

    const input = container.querySelector("input") as HTMLInputElement;
    expect(input.value).toBe("");
    expect(container.textContent).toContain("/api/users");

    await act(async () => {
      useFileSystemStore.setState({ rootFolderPath: "D:/other/demo" });
      useSpringStore.setState({
        requestedRoot: "D:/other/demo",
        loadedRoot: "D:/other/demo",
        root: "D:/other/demo",
        phase: "ready",
        index: endpointIndex(),
      });
    });
    await renderPane();
    expect(input.value).toBe("");
    expect(container.textContent).toContain("/api/users");
  });

  test("opens the indexed controller location when a row is activated", async () => {
    await setSpringState({ phase: "ready", loadedRoot: ROOT, index: endpointIndex() });
    const handleFileSelect = mock(async () => "buffer");
    await act(async () => {
      useFileSystemStore.setState({ handleFileSelect });
    });
    await renderPane();

    const row = container.querySelector("button[aria-label^='GET /api/users']");
    expect(row).not.toBeNull();
    await act(async () => {
      row?.dispatchEvent(new Event("click", { bubbles: true }));
    });

    expect(handleFileSelect).toHaveBeenCalledWith(
      "C:/work/demo/src/main/java/UserController.java",
      false,
      12,
      3,
    );
  });
});
