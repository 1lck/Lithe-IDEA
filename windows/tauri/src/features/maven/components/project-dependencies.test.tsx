import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { normalizePath } from "@/utils/path-helpers";
import { useMavenStore } from "../stores/maven.store";
import type { MavenDependency } from "../types/maven.types";
import { ProjectDependencies } from "./project-dependencies";

const workspaceId = "project-dependencies-navigation";
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let selectFile: ReturnType<
  typeof spyOn<ReturnType<typeof useFileSystemStore.getState>, "handleFileSelect">
>;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  selectFile = spyOn(useFileSystemStore.getState(), "handleFileSelect").mockResolvedValue(
    undefined,
  );
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    selectFile.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
    container.remove();
    restoreDom();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

function row(label: string) {
  const element = [...container.querySelectorAll<HTMLElement>('[role="treeitem"]')].find((item) =>
    item.textContent?.startsWith(label),
  );
  expect(element).toBeDefined();
  return element!;
}

test("dependency double-click opens the nested reactor's root and child POM files", async () => {
  const dependencies: MavenDependency[] = [".", "service"].map((modulePath, index) => ({
    modulePath,
    artifactId: `dependency-${index}`,
    groupId: "example",
    version: "1",
    type: "jar",
    scope: "compile",
    resolution: "resolved",
    children: [],
  }));
  useMavenStore.getStore(workspaceId).setState({
    root: "C:/work",
    project: {
      relativePath: "backend",
      artifactId: "reactor",
      packaging: "pom",
      sourceRoots: [],
      modules: [],
      profiles: [],
      hasWrapper: false,
    },
    dependencyLoads: { ".": { status: "ready", dependencies, error: null } },
  });
  await act(async () =>
    root.render(
      <WorkspaceStoreScopeContext.Provider value={workspaceId}>
        <LocaleProvider language="en-US">
          <ProjectDependencies />
        </LocaleProvider>
      </WorkspaceStoreScopeContext.Provider>,
    ),
  );
  await act(async () => row("reactor").click());
  for (const [index, path] of ["backend/pom.xml", "backend/service/pom.xml"].entries()) {
    await act(async () =>
      row(`dependency-${index}`).dispatchEvent(
        new window.MouseEvent("dblclick", { bubbles: true }),
      ),
    );
    expect(selectFile).toHaveBeenCalledTimes(index + 1);
    expect(normalizePath(selectFile.mock.calls[index][0])).toBe(`C:/work/${path}`);
  }
});
