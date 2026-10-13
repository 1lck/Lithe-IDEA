import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { MavenProject } from "../types/maven.types";
import type { MavenReloadSnapshot } from "../stores/maven.store";
import {
  reloadJavaForMavenWorkspace,
  reloadMavenWorkspaceProjects,
  type MavenWorkspaceReloadDependencies,
} from "./reload-maven-workspace";

afterEach(() => workspaceRuntimeRegistry.resetForTests());

/**
 * Dependencies for scenarios where no Java session can take the reload in
 * place, which exercises the restart path.
 */
const withoutRunningJavaSession = {
  getMavenContext: () => null,
  updateJavaMavenConfiguration: mock(async () => ({ kind: "noSession" as const })),
  trace: mock(() => undefined),
};

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
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 0,
    projectReloadRevision: 0,
    project: mavenProject("old-a") as MavenProject | null,
    activeSessionId: null as string | null,
    output: "A output",
    actions: {
      loadProject: mock(async () => {
        await finishScan.promise;
        mavenA.project = mavenProject("new-a");
      }),
      acknowledgeReload: acknowledgeA,
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const mavenB = {
    root: "D:/work-b" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 0,
    projectReloadRevision: 0,
    project: mavenProject("project-b") as MavenProject | null,
    activeSessionId: "session-b",
    output: "B output",
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload: mock(() => undefined),
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const fileSystemA = { rootFolderPath: "D:/work-a", getAllProjectFiles: getFilesA };
  const fileSystemB = { rootFolderPath: "D:/work-b", getAllProjectFiles: getFilesB };
  const stop = mock(async () => undefined);
  const prewarm = mock(async () => ({ kind: "ready" as const }));
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
    ...withoutRunningJavaSession,
    getJavaOwner: () => ({ stop, prewarm }),
  });

  try {
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
      ...withoutRunningJavaSession,
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

test("acknowledges only the configuration revision active when Java reload starts", async () => {
  const projectFiles = deferred<never[]>();
  const acknowledgeReload = mock(() => undefined);
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 4,
    projectReloadRevision: 4,
    project: mavenProject("project") as MavenProject | null,
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload,
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const reload = reloadJavaForMavenWorkspace(
    { workspaceId: "workspace", root: "D:/work" },
    {
      hasWorkspace: () => true,
      getMavenState: () => maven,
      getFileSystemState: () => ({
        rootFolderPath: "D:/work",
        getAllProjectFiles: () => projectFiles.promise,
      }),
      ...withoutRunningJavaSession,
      getJavaOwner: () => ({
        stop: mock(async () => undefined),
        prewarm: mock(async () => ({ kind: "ready" as const })),
      }),
    },
  );

  maven.reloadRevision = 5;
  projectFiles.resolve([]);

  expect(await reload).toBe("completed");
  expect(acknowledgeReload).toHaveBeenCalledWith(4);
});

test("does not restart Java when the Maven scan fails with an old project", async () => {
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as "ready" | "failed",
    projectError: null as string | null,
    reloadRevision: 0,
    projectReloadRevision: 0,
    project: mavenProject("old") as MavenProject | null,
    actions: {
      loadProject: mock(async () => {
        maven.projectStatus = "failed";
        maven.projectError = "Malformed pom.xml";
      }),
      acknowledgeReload: mock(() => undefined),
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const stop = mock(async () => undefined);
  const prewarm = mock(async () => ({ kind: "ready" as const }));

  const outcome = await reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "D:/work" },
    {
      hasWorkspace: () => true,
      getMavenState: () => maven,
      getFileSystemState: () => ({
        rootFolderPath: "D:/work",
        getAllProjectFiles: async () => [],
      }),
      ...withoutRunningJavaSession,
      getJavaOwner: () => ({ stop, prewarm }),
    },
  );

  expect(outcome).toBe("failed");
  expect(maven.project?.artifactId).toBe("old");
  expect(stop).not.toHaveBeenCalled();
  expect(prewarm).not.toHaveBeenCalled();
});

test("coalesces concurrent reload requests for the same workspace root", async () => {
  const finishScan = deferred<void>();
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 0,
    projectReloadRevision: 0,
    project: mavenProject("project") as MavenProject | null,
    actions: {
      loadProject: mock(async () => {
        await finishScan.promise;
      }),
      acknowledgeReload: mock(() => undefined),
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const dependencies = {
    hasWorkspace: () => true,
    getMavenState: () => maven,
    getFileSystemState: () => ({
      rootFolderPath: "D:/work",
      getAllProjectFiles: async () => [],
    }),
    ...withoutRunningJavaSession,
    getJavaOwner: () => ({
      stop: mock(async () => undefined),
      prewarm: mock(async () => ({ kind: "ready" as const })),
    }),
  };

  const first = reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "D:/work" },
    dependencies,
  );
  const second = reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "D:\\work\\" },
    dependencies,
  );
  finishScan.resolve(undefined);

  expect(first).toBe(second);
  expect(await first).toBe("completed");
  expect(maven.actions.loadProject).toHaveBeenCalledTimes(1);
});

test("does not coalesce case-sensitive workspace roots", async () => {
  const finishUpper = deferred<void>();
  const finishLower = deferred<void>();
  const createDependencies = (root: string, finish: Deferred<void>) => {
    const loadProject = mock(async () => {
      await finish.promise;
    });
    const maven = {
      root: root as string | null,
      visiblePaths: ["pom.xml"],
      projectStatus: "ready" as const,
      projectError: null as string | null,
      reloadRevision: 0,
      projectReloadRevision: 0,
      project: mavenProject(root) as MavenProject | null,
      actions: {
        loadProject,
        acknowledgeReload: mock(() => undefined),
        restoreReloadSnapshot: mock(
          (
            _snapshot: MavenReloadSnapshot,
            _projectRevision: number,
            _reloadRevision: number,
            _message: string,
          ) => undefined,
        ),
      },
    };
    return {
      loadProject,
      dependencies: {
        hasWorkspace: () => true,
        getMavenState: () => maven,
        getFileSystemState: () => ({
          rootFolderPath: root,
          getAllProjectFiles: async () => [],
        }),
        ...withoutRunningJavaSession,
        getJavaOwner: () => ({
          stop: mock(async () => undefined),
          prewarm: mock(async () => ({ kind: "ready" as const })),
        }),
      },
    };
  };
  const upper = createDependencies("wsl://Ubuntu/work/Project", finishUpper);
  const lower = createDependencies("wsl://Ubuntu/work/project", finishLower);
  const upperReload = reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "wsl://Ubuntu/work/Project" },
    upper.dependencies,
  );
  const lowerReload = reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "wsl://Ubuntu/work/project" },
    lower.dependencies,
  );

  try {
    expect(upperReload).not.toBe(lowerReload);
    expect(upper.loadProject).toHaveBeenCalledTimes(1);
    expect(lower.loadProject).toHaveBeenCalledTimes(1);
  } finally {
    finishUpper.resolve(undefined);
    finishLower.resolve(undefined);
    await Promise.all([upperReload, lowerReload]);
  }
});

test("refreshes Java after the last Maven descriptor is removed", async () => {
  const acknowledgeReload = mock(() => undefined);
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 3,
    projectReloadRevision: 3,
    project: mavenProject("old") as MavenProject | null,
    actions: {
      loadProject: mock(async () => {
        maven.project = null;
      }),
      acknowledgeReload,
      restoreReloadSnapshot: mock(
        (
          _snapshot: MavenReloadSnapshot,
          _projectRevision: number,
          _reloadRevision: number,
          _message: string,
        ) => undefined,
      ),
    },
  };
  const stop = mock(async () => undefined);
  const prewarm = mock(async () => ({ kind: "ready" as const }));

  const outcome = await reloadMavenWorkspaceProjects(
    { workspaceId: "workspace", root: "D:/work" },
    {
      hasWorkspace: () => true,
      getMavenState: () => maven,
      getFileSystemState: () => ({
        rootFolderPath: "D:/work",
        getAllProjectFiles: async () => [
          { name: "Main.java", path: "D:/work/src/Main.java", isDir: false },
        ],
      }),
      ...withoutRunningJavaSession,
      getJavaOwner: () => ({ stop, prewarm }),
    },
  );

  expect(outcome).toBe("noProject");
  expect(stop).toHaveBeenCalledTimes(1);
  expect(prewarm).toHaveBeenCalledWith(
    { workspaceId: "workspace", root: "D:/work" },
    "D:/work/src/Main.java",
  );
  expect(acknowledgeReload).toHaveBeenCalledWith(3);
});

test("keeps reload actionable when Java restart fails", async () => {
  const restoreReloadSnapshot = mock(
    (
      _snapshot: MavenReloadSnapshot,
      _projectRevision: number,
      _reloadRevision: number,
      _message: string,
    ) => undefined,
  );
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 1,
    projectReloadRevision: 1,
    project: mavenProject("project") as MavenProject | null,
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload: mock(() => undefined),
      restoreReloadSnapshot,
    },
  };

  await expect(
    reloadMavenWorkspaceProjects(
      { workspaceId: "workspace", root: "D:/work" },
      {
        hasWorkspace: () => true,
        getMavenState: () => maven,
        getFileSystemState: () => ({
          rootFolderPath: "D:/work",
          getAllProjectFiles: async () => [],
        }),
        ...withoutRunningJavaSession,
        getJavaOwner: () => ({
          stop: mock(async () => {
            throw new Error("JDT LS did not stop");
          }),
          prewarm: mock(async () => ({ kind: "ready" as const })),
        }),
      },
    ),
  ).rejects.toThrow("JDT LS did not stop");

  expect(restoreReloadSnapshot).toHaveBeenCalledWith(
    expect.objectContaining({ project: maven.project }),
    1,
    1,
    "JDT LS did not stop",
  );
});

test("keeps reload actionable when Java preparation reports failure", async () => {
  const acknowledgeReload = mock(() => undefined);
  const restoreReloadSnapshot = mock(
    (
      _snapshot: MavenReloadSnapshot,
      _projectRevision: number,
      _reloadRevision: number,
      _message: string,
    ) => undefined,
  );
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 2,
    projectReloadRevision: 2,
    project: mavenProject("project") as MavenProject | null,
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload,
      restoreReloadSnapshot,
    },
  };

  await expect(
    reloadMavenWorkspaceProjects(
      { workspaceId: "workspace", root: "D:/work" },
      {
        hasWorkspace: () => true,
        getMavenState: () => maven,
        getFileSystemState: () => ({
          rootFolderPath: "D:/work",
          getAllProjectFiles: async () => [
            { name: "Main.java", path: "D:/work/src/Main.java", isDir: false },
          ],
        }),
        ...withoutRunningJavaSession,
        getJavaOwner: () => ({
          stop: mock(async () => undefined),
          prewarm: mock(async () => ({ kind: "timedOut" as const })),
        }),
      },
    ),
  ).rejects.toThrow("Unable to reload the Java language server.");

  expect(acknowledgeReload).not.toHaveBeenCalled();
  expect(restoreReloadSnapshot).toHaveBeenCalledWith(
    expect.objectContaining({ project: maven.project }),
    2,
    2,
    "Unable to reload the Java language server.",
  );
});

function singleWorkspaceReload(options: {
  updateJavaMavenConfiguration: MavenWorkspaceReloadDependencies["updateJavaMavenConfiguration"];
}) {
  const acknowledgeReload = mock((_revision?: number) => undefined);
  const maven = {
    root: "D:/work" as string | null,
    visiblePaths: ["pom.xml"],
    projectStatus: "ready" as const,
    projectError: null as string | null,
    reloadRevision: 4,
    projectReloadRevision: 0,
    project: mavenProject("demo") as MavenProject | null,
    actions: {
      loadProject: mock(async () => undefined),
      acknowledgeReload,
      restoreReloadSnapshot: mock(() => undefined),
    },
  };
  const fileSystem = {
    rootFolderPath: "D:/work",
    getAllProjectFiles: mock(async () => [
      { name: "Main.java", path: "D:/work/src/Main.java", isDir: false },
    ]),
  };
  const stop = mock(async () => undefined);
  const prewarm = mock(async () => ({ kind: "ready" as const }));
  const context = {
    version: 1 as const,
    reactorPath: ".",
    profiles: [],
    settingsPath: "D:/maven/conf/settings.xml",
    localRepositoryPath: "D:/dev/.m2/repository",
    skipTests: false,
    mavenExecutablePath: "D:/maven/bin/mvn.cmd",
    javaHomePath: null,
  };
  const dependencies: MavenWorkspaceReloadDependencies = {
    hasWorkspace: () => true,
    getMavenState: () => maven,
    getMavenContext: () => context,
    getFileSystemState: () => fileSystem,
    getJavaOwner: () => ({ stop, prewarm }),
    updateJavaMavenConfiguration: options.updateJavaMavenConfiguration,
    trace: mock(() => undefined),
  };
  return { acknowledgeReload, context, dependencies, prewarm, stop };
}

test("reloads a running Java session in place with a forced Maven project update", async () => {
  // #970: restarting reused the JDT LS workspace state and skipped every
  // project whose pom.xml had not changed, so missing artifacts stayed missing.
  const updateJavaMavenConfiguration = mock(async () => ({
    kind: "updated" as const,
    settingsChanged: false,
    projectsReloaded: true,
    profilesUpdating: false,
  }));
  const reload = singleWorkspaceReload({ updateJavaMavenConfiguration });

  const outcome = await reloadJavaForMavenWorkspace(
    { workspaceId: "workspace", root: "D:/work" },
    reload.dependencies,
  );

  expect(outcome).toBe("completed");
  expect(updateJavaMavenConfiguration).toHaveBeenCalledWith("D:/work", reload.context, true);
  expect(reload.stop).not.toHaveBeenCalled();
  expect(reload.prewarm).not.toHaveBeenCalled();
  expect(reload.acknowledgeReload).toHaveBeenCalledWith(4);
});

test("starts the Java session when none is running to reload", async () => {
  const reload = singleWorkspaceReload({
    updateJavaMavenConfiguration: mock(async () => ({ kind: "noSession" as const })),
  });

  const outcome = await reloadJavaForMavenWorkspace(
    { workspaceId: "workspace", root: "D:/work" },
    reload.dependencies,
  );

  expect(outcome).toBe("completed");
  expect(reload.prewarm).toHaveBeenCalledWith(
    { workspaceId: "workspace", root: "D:/work" },
    "D:/work/src/Main.java",
  );
});

test("restarts a Java session that cannot take the reload", async () => {
  const reload = singleWorkspaceReload({
    updateJavaMavenConfiguration: mock(async () => {
      throw new Error("The Java language session is no longer running.");
    }),
  });

  const outcome = await reloadJavaForMavenWorkspace(
    { workspaceId: "workspace", root: "D:/work" },
    reload.dependencies,
  );

  expect(outcome).toBe("completed");
  expect(reload.stop).toHaveBeenCalledTimes(1);
  expect(reload.prewarm).toHaveBeenCalledTimes(1);
  expect(reload.acknowledgeReload).toHaveBeenCalledWith(4);
});
