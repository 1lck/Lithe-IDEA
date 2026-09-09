import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type {
  MavenDependenciesResponse,
  MavenDiagnostic,
  MavenLaunchPlan,
  MavenProject,
  MavenStoredConfiguration,
} from "../types/maven.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  createMavenStore,
  mavenLaunchContext,
  mavenLaunchContextForWorkspace,
  useMavenStore,
  type MavenReloadSnapshot,
  type MavenStoreDependencies,
} from "./maven.store";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

const project: MavenProject = {
  relativePath: "reactor",
  groupId: "dev.lithe",
  artifactId: "demo",
  version: "1.0.0",
  packaging: "pom",
  sourceRoots: [],
  hasWrapper: true,
  profiles: [
    { id: "default", isActiveByDefault: true },
    { id: "dev", isActiveByDefault: false },
  ],
  modules: [],
};

const launchPlan: MavenLaunchPlan = {
  version: 1,
  executable: { toolchain: "project-maven" },
  arguments: ["-B", "compile"],
  workingDirectory: "reactor",
  configurationFingerprint: "fixture-fingerprint",
};

const dependencyTree: MavenDependenciesResponse = {
  modulePath: "service",
  dependencies: [
    {
      modulePath: "service",
      groupId: "org.example",
      artifactId: "library",
      version: "1.0.0",
      type: "jar",
      classifier: null,
      scope: "compile",
      resolution: "resolved",
      selectedVersion: null,
      children: [],
    },
  ],
};

const scanMavenProject = mock(async (_root: string, _paths?: string[]) => project);
const createMavenLaunchPlan = mock(async () => launchPlan);
const createMavenDependencyPlan = mock(async () => launchPlan);
const parseMavenDependencies = mock(
  async (_modulePath: string, _output: string): Promise<MavenDependenciesResponse> =>
    dependencyTree,
);
const parseMavenDiagnostics = mock(
  async (_root: string, _output: string): Promise<MavenDiagnostic[]> => [],
);
const loadMavenConfiguration = mock(async () => ({}));
const writeMavenConfiguration = mock(
  async (
    _root: string,
    _reactorPath: string,
    _configuration: MavenStoredConfiguration,
  ): Promise<void> => undefined,
);
const resolveMavenLaunch = mock(async () => ({
  executable: "D:/Tools/apache-maven/bin/mvn.cmd",
  workingDirectory: "D:/work/reactor",
  environment: {},
}));
const saveWorkspaceBeforeLaunch = mock(async (_workspaceId: string): Promise<void> => undefined);
const startMavenProcess = mock(async () => undefined);
const stopMavenProcess = mock(async () => undefined);
const startWatchingMavenPom = mock(async (_path: string) => true);
const stopWatchingMavenPom = mock(async (_path: string) => true);
const createMavenPomWatchOperations = mock((_workspaceId: string) => ({
  startWatching: startWatchingMavenPom,
  stopWatching: stopWatchingMavenPom,
}));

const dependencies = {
  createMavenPomWatchOperations,
  createMavenDependencyPlan,
  createMavenLaunchPlan,
  loadMavenConfiguration,
  parseMavenDiagnostics,
  parseMavenDependencies,
  resolveMavenLaunch,
  saveWorkspaceBeforeLaunch,
  scanMavenProject,
  startMavenProcess,
  stopMavenProcess,
  writeMavenConfiguration,
} satisfies MavenStoreDependencies;

beforeEach(() => {
  scanMavenProject.mockReset();
  scanMavenProject.mockResolvedValue(project);
  loadMavenConfiguration.mockReset();
  loadMavenConfiguration.mockResolvedValue({});
  writeMavenConfiguration.mockClear();
  createMavenLaunchPlan.mockReset();
  createMavenLaunchPlan.mockResolvedValue(launchPlan);
  createMavenDependencyPlan.mockReset();
  createMavenDependencyPlan.mockResolvedValue(launchPlan);
  parseMavenDiagnostics.mockReset();
  parseMavenDiagnostics.mockResolvedValue([]);
  parseMavenDependencies.mockReset();
  parseMavenDependencies.mockResolvedValue(dependencyTree);
  resolveMavenLaunch.mockClear();
  saveWorkspaceBeforeLaunch.mockReset();
  saveWorkspaceBeforeLaunch.mockResolvedValue(undefined);
  startMavenProcess.mockClear();
  stopMavenProcess.mockClear();
  createMavenPomWatchOperations.mockClear();
  startWatchingMavenPom.mockReset();
  startWatchingMavenPom.mockResolvedValue(true);
  stopWatchingMavenPom.mockReset();
  stopWatchingMavenPom.mockResolvedValue(true);
});

class ManualTimer {
  private nextId = 1;
  private readonly callbacks = new Map<number, () => void | Promise<void>>();

  readonly set = (callback: () => void | Promise<void>) => {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id as unknown as ReturnType<typeof setTimeout>;
  };

  readonly clear = (timer: ReturnType<typeof setTimeout>) => {
    this.callbacks.delete(timer as unknown as number);
  };

  get size(): number {
    return this.callbacks.size;
  }

  async fireNext(): Promise<void> {
    const id = [...this.callbacks.keys()].sort((left, right) => left - right)[0];
    if (id === undefined) throw new Error("No timer is scheduled.");
    const callback = this.callbacks.get(id);
    this.callbacks.delete(id);
    await callback?.();
  }
}

afterEach(() => workspaceRuntimeRegistry.resetForTests());

describe("Maven workspace state", () => {
  test("resolves workspace A without mutating active workspace B", async () => {
    const workspaceA = useMavenStore.getStore("workspace-a");
    const workspaceB = useMavenStore.getStore("workspace-b");
    const loadWorkspaceB = mock(async () => undefined);
    workspaceA.setState({
      root: "D:/work-a",
      projectStatus: "ready",
      project: { ...project, artifactId: "project-a" },
    });
    workspaceB.setState((state) => ({
      root: "D:/work-b",
      projectStatus: "ready",
      project: { ...project, artifactId: "project-b" },
      activeSessionId: "session-b",
      output: "B output",
      actions: { ...state.actions, loadProject: loadWorkspaceB },
    }));
    workspaceRuntimeRegistry.activateWorkspace({ id: "workspace-b", name: "B" }, "ready");
    const workspaceBBefore = {
      root: workspaceB.getState().root,
      project: workspaceB.getState().project,
      activeSessionId: workspaceB.getState().activeSessionId,
      output: workspaceB.getState().output,
    };

    const context = await mavenLaunchContextForWorkspace(
      "D:/work-a",
      ["src/Main.java"],
      "workspace-a",
    );

    expect(context?.reactorPath).toBe("reactor");
    expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe("workspace-b");
    expect({
      root: workspaceB.getState().root,
      project: workspaceB.getState().project,
      activeSessionId: workspaceB.getState().activeSessionId,
      output: workspaceB.getState().output,
    }).toEqual(workspaceBBefore);
    expect(loadWorkspaceB).not.toHaveBeenCalled();
  });

  test("restores portable selections and machine-local paths into one launch context", async () => {
    loadMavenConfiguration.mockResolvedValue({
      portable: {
        version: 1,
        selectedProfiles: ["qa", "dev"],
        customProfiles: ["qa"],
        skipTests: true,
      },
      local: {
        version: 1,
        settingsPath: "C:/Users/example/.m2/settings.xml",
        localRepositoryPath: "D:/maven-repo",
        mavenExecutablePath: "D:/Tools/apache-maven",
        javaHomePath: "C:/Java/jdk-21",
      },
    });
    const store = createMavenStore("workspace", dependencies);

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(mavenLaunchContext(store.getState())).toEqual({
      version: 1,
      reactorPath: "reactor",
      profiles: ["dev", "qa"],
      settingsPath: "C:/Users/example/.m2/settings.xml",
      localRepositoryPath: "D:/maven-repo",
      skipTests: true,
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    });
  });

  test("watches the reactor and every recursively discovered module POM", async () => {
    scanMavenProject.mockResolvedValueOnce({
      ...project,
      modules: [
        {
          relativePath: "module-a",
          artifactId: "module-a",
          packaging: "pom",
          sourceRoots: [],
          modules: [
            {
              relativePath: "module-a/module-b",
              artifactId: "module-b",
              packaging: "jar",
              sourceRoots: [],
              modules: [],
            },
          ],
        },
      ],
    });
    const store = createMavenStore("workspace", dependencies);

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(createMavenPomWatchOperations).toHaveBeenCalledWith("workspace");
    expect(startWatchingMavenPom.mock.calls.map(([path]) => path)).toEqual([
      "D:/work\\reactor\\module-a\\module-b\\pom.xml",
      "D:/work\\reactor\\module-a\\pom.xml",
      "D:/work\\reactor\\pom.xml",
    ]);
  });

  test("updates POM watches when the scanned module set changes", async () => {
    const module = (relativePath: string) => ({
      relativePath,
      artifactId: relativePath,
      packaging: "jar",
      sourceRoots: [],
      modules: [],
    });
    scanMavenProject.mockResolvedValueOnce({
      ...project,
      relativePath: ".",
      modules: [module("module-a"), module("module-b")],
    });
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["pom.xml"]);
    startWatchingMavenPom.mockClear();
    stopWatchingMavenPom.mockClear();
    scanMavenProject.mockResolvedValueOnce({
      ...project,
      relativePath: ".",
      modules: [module("module-a"), module("module-c")],
    });

    await store.getState().actions.loadProject("D:/work", ["pom.xml"]);

    expect(stopWatchingMavenPom).toHaveBeenCalledTimes(1);
    expect(stopWatchingMavenPom).toHaveBeenCalledWith("D:/work\\module-b\\pom.xml");
    expect(startWatchingMavenPom.mock.calls.map(([path]) => path)).toEqual([
      "D:/work\\module-a\\pom.xml",
      "D:/work\\module-c\\pom.xml",
      "D:/work\\pom.xml",
    ]);
  });

  test("releases the previous root POM watches before registering the next root", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/first", ["reactor/pom.xml"]);
    startWatchingMavenPom.mockClear();
    stopWatchingMavenPom.mockClear();

    await store.getState().actions.loadProject("D:/second", ["reactor/pom.xml"]);

    expect(stopWatchingMavenPom).toHaveBeenCalledWith("D:/first\\reactor\\pom.xml");
    expect(startWatchingMavenPom).toHaveBeenCalledWith("D:/second\\reactor\\pom.xml");
    expect(stopWatchingMavenPom.mock.invocationCallOrder[0]).toBeLessThan(
      startWatchingMavenPom.mock.invocationCallOrder[0] ?? Number.MAX_SAFE_INTEGER,
    );
  });

  test("persists portable and local values in separate documents", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const writeStarted = deferred<void>();
    writeMavenConfiguration.mockImplementationOnce(async () => {
      writeStarted.resolve(undefined);
    });

    store.getState().actions.updateLocalConfiguration({
      settingsPath: "C:/Users/example/.m2/settings.xml",
      localRepositoryPath: "D:/maven-repo",
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    });
    await writeStarted.promise;

    const calls = writeMavenConfiguration.mock.calls;
    const configuration = calls[calls.length - 1]?.[2];
    expect(configuration?.portable).toEqual({
      version: 1,
      selectedProfiles: ["default"],
      customProfiles: [],
      skipTests: false,
    });
    expect(configuration?.portable).not.toHaveProperty("settingsPath");
    expect(configuration?.portable).not.toHaveProperty("localRepositoryPath");
    expect(configuration?.local).toEqual({
      version: 1,
      settingsPath: "C:/Users/example/.m2/settings.xml",
      localRepositoryPath: "D:/maven-repo",
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    });
  });

  test("serializes rapid configuration writes so the newest value wins", async () => {
    const firstStarted = deferred<void>();
    const firstWrite = deferred<void>();
    const secondStarted = deferred<void>();
    writeMavenConfiguration
      .mockImplementationOnce(async () => {
        firstStarted.resolve(undefined);
        await firstWrite.promise;
      })
      .mockImplementationOnce(async () => {
        secondStarted.resolve(undefined);
      });
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    store.getState().actions.setSkipTests(true);
    store.getState().actions.setSkipTests(false);
    try {
      await firstStarted.promise;
      expect(writeMavenConfiguration).toHaveBeenCalledTimes(1);

      firstWrite.resolve(undefined);
      await secondStarted.promise;

      expect(writeMavenConfiguration).toHaveBeenCalledTimes(2);
      expect(writeMavenConfiguration.mock.calls[1]?.[2].portable?.skipTests).toBe(false);
    } finally {
      firstWrite.resolve(undefined);
    }
  });

  test("waits for a pending configuration write before reloading", async () => {
    const firstStarted = deferred<void>();
    const firstWrite = deferred<void>();
    const reloadScanStarted = deferred<void>();
    const reloadConfigurationStarted = deferred<void>();
    writeMavenConfiguration.mockImplementationOnce(async () => {
      firstStarted.resolve(undefined);
      await firstWrite.promise;
    });
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    scanMavenProject.mockImplementationOnce(async () => {
      reloadScanStarted.resolve(undefined);
      return project;
    });
    loadMavenConfiguration.mockImplementationOnce(async () => {
      reloadConfigurationStarted.resolve(undefined);
      return {};
    });
    let reload: Promise<void> | undefined;

    try {
      store.getState().actions.setSkipTests(true);
      await firstStarted.promise;
      reload = store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
      await reloadScanStarted.promise;

      expect(loadMavenConfiguration).toHaveBeenCalledTimes(1);
      firstWrite.resolve(undefined);
      await reloadConfigurationStarted.promise;
      await reload;

      expect(loadMavenConfiguration).toHaveBeenCalledTimes(2);
    } finally {
      firstWrite.resolve(undefined);
      await reload;
    }
  });

  test("preserves the newest in-memory configuration when reload writes fail", async () => {
    const firstWriteStarted = deferred<void>();
    const releaseFirstWrite = deferred<void>();
    const reloadScan = deferred<typeof project>();
    writeMavenConfiguration
      .mockImplementationOnce(async () => {
        firstWriteStarted.resolve(undefined);
        await releaseFirstWrite.promise;
        throw new Error("Unable to save settings");
      })
      .mockRejectedValueOnce(new Error("Unable to save settings"));
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    scanMavenProject.mockImplementationOnce(() => reloadScan.promise);
    let reload: Promise<void> | undefined;

    try {
      store.getState().actions.setSkipTests(true);
      await firstWriteStarted.promise;
      reload = store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
      store.getState().actions.setSkipTests(false);
      reloadScan.resolve(project);
      releaseFirstWrite.resolve(undefined);
      await reload;

      expect(writeMavenConfiguration).toHaveBeenCalledTimes(2);
      expect(store.getState().skipTests).toBe(false);
      expect(store.getState().configurationSaveError).toBe("Unable to save settings");
    } finally {
      releaseFirstWrite.resolve(undefined);
      reloadScan.resolve(project);
      await reload;
    }
  });

  test("does not overwrite a configuration edit made while stored settings load", async () => {
    const configurationLoadStarted = deferred<void>();
    const storedConfiguration = deferred<MavenStoredConfiguration>();
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    loadMavenConfiguration.mockImplementationOnce(async () => {
      configurationLoadStarted.resolve(undefined);
      return storedConfiguration.promise;
    });
    const reload = store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    try {
      await configurationLoadStarted.promise;
      store.getState().actions.setSkipTests(true);
      storedConfiguration.resolve({
        portable: {
          version: 1,
          selectedProfiles: ["default"],
          customProfiles: [],
          skipTests: false,
        },
      });
      await reload;

      expect(store.getState().skipTests).toBe(true);
    } finally {
      storedConfiguration.resolve({});
      await reload;
    }
  });

  test("does not let an older scan replace a newer workspace", async () => {
    const firstScan = deferred<typeof project>();
    const secondScan = deferred<typeof project>();
    scanMavenProject
      .mockImplementationOnce(() => firstScan.promise)
      .mockImplementationOnce(() => secondScan.promise);
    const store = createMavenStore("workspace", dependencies);

    const first = store.getState().actions.loadProject("D:/first", ["pom.xml"]);
    const second = store.getState().actions.loadProject("D:/second", ["pom.xml"]);
    secondScan.resolve({ ...project, artifactId: "second" });
    await second;
    firstScan.resolve({ ...project, artifactId: "first" });
    await first;

    expect(store.getState().root).toBe("D:/second");
    expect(store.getState().project?.artifactId).toBe("second");
  });

  test("does not carry a pending reload into a different root when its scan fails", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/first", ["pom.xml"]);
    store.getState().actions.markPomReloadRequired("pom.xml");
    scanMavenProject.mockRejectedValueOnce(new Error("Unreadable new project"));

    await store.getState().actions.loadProject("D:/second", ["pom.xml"]);

    expect(store.getState().root).toBe("D:/second");
    expect(store.getState().reloadRequired).toBe(false);
    expect(store.getState().projectReloadRequired).toBe(false);
    expect(store.getState().projectError).toBe("Unreadable new project");
  });

  test("keeps the last usable project when a same-workspace reload fails", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    scanMavenProject.mockRejectedValueOnce(new Error("Malformed pom.xml"));

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(store.getState().project).toEqual(project);
    expect(store.getState().projectStatus).toBe("failed");
    expect(store.getState().projectError).toBe("Malformed pom.xml");
    expect(store.getState().reloadRequired).toBe(true);
    expect(mavenLaunchContext(store.getState())?.reactorPath).toBe("reactor");
    expect(stopWatchingMavenPom).not.toHaveBeenCalled();
  });

  test("marks repeated POM changes as one pending reload", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");

    expect(store.getState().reloadRequired).toBe(true);
    expect(store.getState().projectReloadRequired).toBe(true);
    expect(store.getState().projectError).toBeNull();
  });

  test("keeps configuration-only reloads Java-only and preserves a failed write", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    writeMavenConfiguration.mockRejectedValueOnce(new Error("Unable to save settings"));

    store.getState().actions.setSkipTests(true);

    expect(store.getState().reloadRequired).toBe(true);
    expect(store.getState().projectReloadRequired).toBe(false);
    await store
      .getState()
      .actions.loadProject("D:/work", [...store.getState().visiblePaths]);
    expect(store.getState().skipTests).toBe(true);
    expect(store.getState().configurationSaveError).toBe("Unable to save settings");

    store.getState().actions.markPomReloadRequired("module/pom.xml");
    expect(store.getState().projectReloadRequired).toBe(true);
  });

  test("includes a newly observed nested POM in the next Maven scan", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    store.getState().actions.markPomReloadRequired("module/pom.xml");
    store.getState().actions.markPomReloadRequired("module/pom.xml");
    const visiblePaths = store.getState().visiblePaths;
    await store.getState().actions.loadProject("D:/work", visiblePaths);

    expect(visiblePaths).toEqual(["module/pom.xml", "reactor/pom.xml"]);
    expect(scanMavenProject).toHaveBeenLastCalledWith("D:/work", visiblePaths);
  });

  test("restores the prior Maven model when Java synchronization fails", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const previous = store.getState();
    const snapshot: MavenReloadSnapshot = {
      projectStatus: previous.projectStatus,
      projectError: previous.projectError,
      project: previous.project,
      selectedProfiles: [...previous.selectedProfiles],
      customProfiles: [...previous.customProfiles],
      skipTests: previous.skipTests,
      settingsPath: previous.settingsPath,
      localRepositoryPath: previous.localRepositoryPath,
      mavenExecutablePath: previous.mavenExecutablePath,
      javaHomePath: previous.javaHomePath,
    };
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const projectReloadRevision = store.getState().projectReloadRevision;
    const reloadRevision = store.getState().reloadRevision;
    scanMavenProject.mockResolvedValueOnce({ ...project, artifactId: "reloaded" });
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    store
      .getState()
      .actions.restoreReloadSnapshot(
        snapshot,
        projectReloadRevision,
        reloadRevision,
        "JDT LS did not restart",
      );

    expect(store.getState().project?.artifactId).toBe("demo");
    expect(store.getState().projectStatus).toBe("failed");
    expect(store.getState().projectError).toBe("JDT LS did not restart");
    expect(store.getState().reloadRequired).toBe(true);
    expect(store.getState().reloadRevision).toBe(reloadRevision + 1);
  });

  test("restores the Maven model without discarding configuration edited during Java sync", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const previous = store.getState();
    const snapshot: MavenReloadSnapshot = {
      projectStatus: previous.projectStatus,
      projectError: previous.projectError,
      project: previous.project,
      selectedProfiles: [...previous.selectedProfiles],
      customProfiles: [...previous.customProfiles],
      skipTests: previous.skipTests,
      settingsPath: previous.settingsPath,
      localRepositoryPath: previous.localRepositoryPath,
      mavenExecutablePath: previous.mavenExecutablePath,
      javaHomePath: previous.javaHomePath,
    };
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const projectReloadRevision = store.getState().projectReloadRevision;
    const reloadRevision = store.getState().reloadRevision;
    scanMavenProject.mockResolvedValueOnce({ ...project, artifactId: "reloaded" });
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    store.getState().actions.setSkipTests(true);
    store
      .getState()
      .actions.restoreReloadSnapshot(
        snapshot,
        projectReloadRevision,
        reloadRevision,
        "JDT LS did not restart",
      );

    expect(store.getState().project?.artifactId).toBe("demo");
    expect(store.getState().projectStatus).toBe("failed");
    expect(store.getState().projectError).toBe("JDT LS did not restart");
    expect(store.getState().skipTests).toBe(true);
    expect(store.getState().reloadRequired).toBe(true);
  });

  test("does not restore an old Maven snapshot over a newer POM revision", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const previous = store.getState();
    const snapshot: MavenReloadSnapshot = {
      projectStatus: previous.projectStatus,
      projectError: previous.projectError,
      project: previous.project,
      selectedProfiles: [...previous.selectedProfiles],
      customProfiles: [...previous.customProfiles],
      skipTests: previous.skipTests,
      settingsPath: previous.settingsPath,
      localRepositoryPath: previous.localRepositoryPath,
      mavenExecutablePath: previous.mavenExecutablePath,
      javaHomePath: previous.javaHomePath,
    };
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const olderProjectRevision = store.getState().projectReloadRevision;
    const olderRevision = store.getState().reloadRevision;
    scanMavenProject.mockResolvedValueOnce({ ...project, artifactId: "reloaded" });
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("newer/pom.xml");

    store
      .getState()
      .actions.restoreReloadSnapshot(
        snapshot,
        olderProjectRevision,
        olderRevision,
        "Older reload failed",
      );

    expect(store.getState().project?.artifactId).toBe("reloaded");
    expect(store.getState().projectStatus).toBe("ready");
    expect(store.getState().projectError).toBeNull();
    expect(store.getState().reloadRequired).toBe(true);
  });

  test("keeps a newer POM change pending when an older scan completes", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const scan = deferred<typeof project>();
    scanMavenProject.mockImplementationOnce(() => scan.promise);

    const reload = store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    scan.resolve({ ...project, artifactId: "reloaded" });
    await reload;

    expect(store.getState().project?.artifactId).toBe("reloaded");
    expect(store.getState().reloadRequired).toBe(true);
  });

  test("keeps the current POM reload pending until Java synchronization is acknowledged", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const reloadRevision = store.getState().reloadRevision;

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(store.getState().reloadRequired).toBe(true);
    store.getState().actions.acknowledgeReload(reloadRevision);
    expect(store.getState().reloadRequired).toBe(false);
    expect(store.getState().projectReloadRequired).toBe(false);
  });

  test("does not acknowledge a newer POM revision from an older reload", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");
    const olderRevision = store.getState().reloadRevision;
    store.getState().actions.markPomReloadRequired("reactor/pom.xml");

    store.getState().actions.acknowledgeReload(olderRevision);
    expect(store.getState().reloadRequired).toBe(true);

    store.getState().actions.acknowledgeReload(store.getState().reloadRevision);
    expect(store.getState().reloadRequired).toBe(false);
  });

  test("cancels a pending launch without starting a stale process", async () => {
    const pendingPlan = deferred<MavenLaunchPlan>();
    createMavenLaunchPlan.mockImplementationOnce(() => pendingPlan.promise);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    const run = store.getState().actions.runGoals(["compile"], null, "compile");
    await Promise.resolve();
    await store.getState().actions.stop();
    pendingPlan.resolve(launchPlan);
    await run;

    expect(startMavenProcess).not.toHaveBeenCalled();
    expect(store.getState().taskStatus).toBe("cancelled");
    expect(store.getState().activeSessionId).toBeNull();
    expect(store.getState().taskTitle).toBe("compile");
    expect(store.getState().output).toBe("Maven task cancelled.\n");

    store.getState().actions.clearOutput();

    expect(store.getState().taskStatus).toBe("idle");
    expect(store.getState().taskTitle).toBeNull();
    expect(store.getState().output).toBe("");
  });

  test("waits for workspace files to save before creating a launch plan", async () => {
    const pendingSave = deferred<void>();
    saveWorkspaceBeforeLaunch.mockImplementationOnce(() => pendingSave.promise);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    const run = store.getState().actions.runGoals(["compile"], null, "compile");
    try {
      await Promise.resolve();
      expect(saveWorkspaceBeforeLaunch).toHaveBeenCalledWith("workspace");
      expect(createMavenLaunchPlan).not.toHaveBeenCalled();
    } finally {
      pendingSave.resolve(undefined);
      await run;
    }

    expect(createMavenLaunchPlan).toHaveBeenCalledTimes(1);
    expect(startMavenProcess).toHaveBeenCalledTimes(1);
  });

  test("does not launch Maven when workspace files cannot be saved", async () => {
    saveWorkspaceBeforeLaunch.mockRejectedValueOnce(
      new Error("Unable to start because modified files could not be saved: App.java."),
    );
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    await store.getState().actions.runGoals(["compile"], null, "compile");

    expect(createMavenLaunchPlan).not.toHaveBeenCalled();
    expect(startMavenProcess).not.toHaveBeenCalled();
    expect(store.getState().taskStatus).toBe("failed");
    expect(store.getState().taskError).toContain("App.java");
    expect(store.getState().taskTitle).toBe("compile");

    store.getState().actions.clearOutput();

    expect(store.getState().taskStatus).toBe("idle");
    expect(store.getState().taskError).toBeNull();
    expect(store.getState().taskTitle).toBeNull();
    expect(store.getState().issues).toEqual([]);
    expect(store.getState().lastExitCode).toBeNull();
  });

  test("keeps cancellation when process exit arrives before stop completes", async () => {
    const stopFinished = deferred<undefined>();
    stopMavenProcess.mockImplementationOnce(() => stopFinished.promise);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.runGoals(["compile"], null, "compile");
    const sessionId = store.getState().activeSessionId;
    expect(sessionId).not.toBeNull();

    const stop = store.getState().actions.stop();
    try {
      expect(store.getState().taskStatus).toBe("stopping");
      store.getState().actions.finishProcess(sessionId!, 143);
      expect(store.getState().taskStatus).toBe("cancelled");

      stopFinished.resolve(undefined);
      await stop;

      expect(store.getState().output.match(/Maven task cancelled\./g)).toHaveLength(1);
      expect(store.getState().lastExitCode).toBeNull();
    } finally {
      stopFinished.resolve(undefined);
      await stop;
    }
  });

  test("does not let diagnostics from a completed task replace a newer run", async () => {
    const pendingDiagnostics =
      deferred<Array<{ path: string; line: number; severity: "error"; message: string }>>();
    parseMavenDiagnostics.mockImplementationOnce(() => pendingDiagnostics.promise);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.runGoals(["compile"], null, "compile");
    const completedSession = store.getState().activeSessionId;
    expect(completedSession).not.toBeNull();

    store.getState().actions.finishProcess(completedSession!, 1);
    await store.getState().actions.runGoals(["test"], null, "test");
    pendingDiagnostics.resolve([
      { path: "src/Old.java", line: 3, severity: "error", message: "old task" },
    ]);
    await pendingDiagnostics.promise;
    await Promise.resolve();

    expect(store.getState().issues).toEqual([]);
    expect(store.getState().taskTitle).toBe("test");
  });
});

describe("Maven dependency state", () => {
  test("loads and parses one module without replacing build task state", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.setState({ output: "existing build output", taskStatus: "running" });

    await store.getState().actions.loadDependencies("service");

    const sessionId = store.getState().activeDependencySessionId;
    expect(sessionId).toStartWith("maven-dependency:");
    expect(createMavenDependencyPlan).toHaveBeenCalledWith(
      "D:/work",
      expect.objectContaining({ reactorPath: "reactor" }),
      "service",
    );
    expect(store.getState().dependencyLoads.service?.status).toBe("loading");
    expect(store.getState().output).toBe("existing build output");
    store.getState().actions.appendDependencyOutput(sessionId!, "[INFO] tree\n");
    await store.getState().actions.finishDependencyProcess(sessionId!, 0);

    expect(parseMavenDependencies).toHaveBeenCalledWith("service", "[INFO] tree\n");
    expect(store.getState().dependencyLoads.service).toEqual({
      status: "ready",
      dependencies: dependencyTree.dependencies,
      error: null,
    });
    expect(store.getState().taskStatus).toBe("running");
    expect(store.getState().output).toBe("existing build output");
  });

  test("stops a dependency process at the injected deadline", async () => {
    const timer = new ManualTimer();
    const store = createMavenStore("workspace", dependencies, {
      setTimer: timer.set,
      clearTimer: timer.clear,
    });
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.loadDependencies("service");
    const sessionId = store.getState().activeDependencySessionId;

    expect(timer.size).toBe(1);
    await timer.fireNext();

    expect(stopMavenProcess).toHaveBeenCalledWith(sessionId);
    expect(store.getState().activeDependencySessionId).toBeNull();
    expect(store.getState().dependencyLoads.service?.status).toBe("failed");
    expect(store.getState().dependencyLoads.service?.error).toContain("timed out");
  });

  test("shows explicit cancellation for a module dependency request", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.loadDependencies("service");
    const sessionId = store.getState().activeDependencySessionId;

    await store.getState().actions.cancelDependencies("service");

    expect(stopMavenProcess).toHaveBeenCalledWith(sessionId);
    expect(store.getState().dependencyLoads.service).toEqual({
      status: "cancelled",
      dependencies: [],
      error: null,
    });
  });

  test("drops a parsed result after Maven configuration invalidates the request", async () => {
    const pending = deferred<MavenDependenciesResponse>();
    parseMavenDependencies.mockImplementationOnce(async () => pending.promise);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.loadDependencies("service");
    const sessionId = store.getState().activeDependencySessionId;
    const finishing = store.getState().actions.finishDependencyProcess(sessionId!, 0);

    store.getState().actions.setSelectedProfiles(["dev"]);
    pending.resolve(dependencyTree);
    await finishing;

    expect(store.getState().dependencyLoads).toEqual({});
  });

  test("cancels a module still being parsed when another dependency request starts", async () => {
    const pending = deferred<MavenDependenciesResponse>();
    parseMavenDependencies.mockImplementationOnce(async () => pending.promise);
    const timer = new ManualTimer();
    const store = createMavenStore("workspace", dependencies, {
      setTimer: timer.set,
      clearTimer: timer.clear,
    });
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    await store.getState().actions.loadDependencies("service");
    const sessionId = store.getState().activeDependencySessionId;
    const finishing = store.getState().actions.finishDependencyProcess(sessionId!, 0);

    await store.getState().actions.loadDependencies("other");

    expect(store.getState().dependencyLoads.service?.status).toBe("cancelled");
    expect(store.getState().dependencyLoads.other?.status).toBe("loading");
    pending.resolve(dependencyTree);
    await finishing;
    expect(store.getState().dependencyLoads.service?.status).toBe("cancelled");
    await store.getState().actions.cancelDependencies("other");
  });
});
