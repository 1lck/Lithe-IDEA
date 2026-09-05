import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { MavenProject } from "../types/maven.types";
import {
  reloadJavaForMavenWorkspace,
  reloadMavenWorkspaceProjects,
} from "./reload-maven-workspace";

afterEach(() => workspaceRuntimeRegistry.resetForTests());

type Deferred<T> = {
  promise: Promise<T>;
  resolve(value: T): void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function mavenProject(artifactId: string): MavenProject {
  return {
    relativePath: ".",
    artifactId,
    packaging: "jar",
    sourceRoots: [],
    modules: [],
    profiles: [],
    hasWrapper: true,
  };
}

test("finishes workspace A reload without reading or mutating active workspace B", async () => {
  const scanStarted = deferred<void>();
  const finishScan = deferred<void>();
  const acknowledgeA = mock(() => undefined);
  const getFilesA = mock(async () => [
    { name: "Main.java", path: "D:/work-a/src/Main.java", isDir: false },
  ]);
  const getFilesB = mock(async () => [
    { name: "Wrong.java", path: "D:/work-b/src/Wrong.java", isDir: false },
  ]);
  const mavenA = {
    root: "D:/work-a" as string | null,
    visiblePaths: ["pom.xml"],
    project: mavenProject("old-a") as MavenProject | null,
    activeSessionId: null as string | null,
    output: "A output",
    actions: {
      loadProject: mock(async () => {
        scanStarted.resolve(undefined);
        await finishScan.promise;
        mavenA.project = mavenProject("new-a");
      }),
      acknowledgeReload: acknowledgeA,
    },
  };
  const mavenB = {
    root: "D:/work-b" as string | null,
    visiblePaths: ["pom.xml"],
    project: mavenProject("project-b") as MavenProject | null,
    activeSessionId: "session-b",
    output: "B output",
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload: mock(() => undefined),
    },
  };
  const fileSystemA = { rootFolderPath: "D:/work-a", getAllProjectFiles: getFilesA };
  const fileSystemB = { rootFolderPath: "D:/work-b", getAllProjectFiles: getFilesB };
  const stop = mock(async () => undefined);
  const prewarm = mock(async () => ({ kind: "ready" }));
  const mavenStates = new Map([
    ["workspace-a", mavenA],
    ["workspace-b", mavenB],
  ]);
  const fileSystemStates = new Map([
    ["workspace-a", fileSystemA],
    ["workspace-b", fileSystemB],
  ]);
  const scopeA = { workspaceId: "workspace-a", root: "D:/work-a" };
  workspaceRuntimeRegistry.ensureWorkspace({ id: "workspace-a", name: "A" }, "ready");
  const getMavenState = mock((workspaceId: string) => mavenStates.get(workspaceId)!);
  const getFileSystemState = mock((workspaceId: string) => fileSystemStates.get(workspaceId)!);
  const reload = reloadMavenWorkspaceProjects(scopeA, {
    hasWorkspace: (workspaceId) => workspaceRuntimeRegistry.hasWorkspace(workspaceId),
    getMavenState,
    getFileSystemState,
    getJavaOwner: () => ({ stop, prewarm }),
  });

  try {
    await scanStarted.promise;
    workspaceRuntimeRegistry.activateWorkspace({ id: "workspace-b", name: "B" }, "ready");
    const workspaceBBefore = {
      project: mavenB.project,
      activeSessionId: mavenB.activeSessionId,
      output: mavenB.output,
      rootFolderPath: fileSystemB.rootFolderPath,
    };
    finishScan.resolve(undefined);

    expect(await reload).toBe("completed");
    expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe("workspace-b");
    expect({
      project: mavenB.project,
      activeSessionId: mavenB.activeSessionId,
      output: mavenB.output,
      rootFolderPath: fileSystemB.rootFolderPath,
    }).toEqual(workspaceBBefore);
    expect(mavenB.actions.loadProject).not.toHaveBeenCalled();
    expect(mavenB.actions.acknowledgeReload).not.toHaveBeenCalled();
    expect(getFilesB).not.toHaveBeenCalled();
    expect(getMavenState.mock.calls.every(([workspaceId]) => workspaceId === "workspace-a")).toBe(
      true,
    );
    expect(
      getFileSystemState.mock.calls.every(([workspaceId]) => workspaceId === "workspace-a"),
    ).toBe(true);
    expect(stop).toHaveBeenCalledWith(scopeA);
    expect(prewarm).toHaveBeenCalledWith(scopeA, "D:/work-a/src/Main.java");
    expect(acknowledgeA).toHaveBeenCalledTimes(1);
  } finally {
    finishScan.resolve(undefined);
    await reload;
  }
});

test("does not recreate stores after the workspace is closed", async () => {
  const getMavenState = mock(() => {
    throw new Error("Maven store must not be recreated");
  });
  const getFileSystemState = mock(() => {
    throw new Error("File-system store must not be recreated");
  });
  const getJavaOwner = mock(() => {
    throw new Error("Java owner must not be resolved");
  });

  const outcome = await reloadJavaForMavenWorkspace(
    { workspaceId: "closed-workspace", root: "D:/closed" },
    {
      hasWorkspace: () => false,
      getMavenState,
      getFileSystemState,
      getJavaOwner,
    },
  );

  expect(outcome).toBe("stale");
  expect(getMavenState).not.toHaveBeenCalled();
  expect(getFileSystemState).not.toHaveBeenCalled();
  expect(getJavaOwner).not.toHaveBeenCalled();
});
