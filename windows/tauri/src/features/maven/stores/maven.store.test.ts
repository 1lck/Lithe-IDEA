import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type {
  MavenDependenciesResponse,
  MavenDiagnostic,
  MavenLaunchPlan,
  MavenProject,
  MavenStoredConfiguration,
  MavenTestResults,
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

const mavenTestProject: MavenProject = {
  ...project,
  modules: [
    {
      relativePath: "service",
      groupId: "dev.lithe",
      artifactId: "service",
      version: "1.0.0",
      packaging: "jar",
      sourceRoots: [],
      modules: [],
    },
  ],
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

const scanMavenProject = mock(
  async (_root: string, _paths?: string[]): Promise<MavenProject | null> => project,
);
const createMavenLaunchPlan = mock(async () => launchPlan);
const createMavenDependencyPlan = mock(async () => launchPlan);
const parseMavenDependencies = mock(
  async (_modulePath: string, _output: string): Promise<MavenDependenciesResponse> =>
    dependencyTree,
);
const parseMavenDiagnostics = mock(
  async (_root: string, _output: string): Promise<MavenDiagnostic[]> => [],
);
const parseMavenTestResults = mock(
  async (_root: string, _output: string): Promise<MavenTestResults> => ({
    testsRun: 0,
    failures: 0,
    errors: 0,
    skipped: 0,
    passed: 0,
    success: true,
    failureDetails: [],
  }),
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
const effectiveConfiguration = {
  settingsPath: "C:/Users/example/.m2/settings.xml",
  localRepositoryPath: "C:/Users/example/.m2/repository",
  mavenExecutablePath: "D:/Tools/apache-maven/bin/mvn.cmd",
  javaHomePath: "C:/Java/jdk-21",
  detectedSettingsPath: "C:/Users/example/.m2/settings.xml",
  detectedLocalRepositoryPath: "C:/Users/example/.m2/repository",
  detectedMavenExecutablePath: "D:/Tools/apache-maven/bin/mvn.cmd",
  detectedJavaHomePath: "C:/Java/jdk-21",
};
const resolveMavenEffectiveConfiguration = mock(async () => effectiveConfiguration);
const startMavenProcess = mock(async () => undefined);
const stopMavenProcess = mock(async () => undefined);
const trace = mock(() => undefined);
const startWatchingMavenPom = mock(async (_path: string) => true);
const stopWatchingMavenPom = mock(async (_path: string) => true);
const createMavenPomWatchOperations = mock((_workspaceId: string) => ({
  startWatching: startWatchingMavenPom,
  stopWatching: stopWatchingMavenPom,
}));
const resolveEffectiveMavenExecutable = mock(
  async (_root: string, configured: string) => configured,
);

const resolveJavaTestClass = mock(async (_root: string, _file: string, className: string): Promise<string | null> => className);

const dependencies = {
  createMavenPomWatchOperations,
  createMavenDependencyPlan,
  createMavenLaunchPlan,
  loadMavenConfiguration,
  parseMavenDiagnostics,
  parseMavenTestResults,
  parseMavenDependencies,
  resolveEffectiveMavenExecutable,
  resolveMavenLaunch,
  resolveJavaTestClass,
  resolveMavenEffectiveConfiguration,
  saveWorkspaceBeforeLaunch,
  scanMavenProject,
  startMavenProcess,
  stopMavenProcess,
  trace,
  writeMavenConfiguration,
} satisfies MavenStoreDependencies;

beforeEach(() => {
  resolveJavaTestClass.mockReset();
  resolveJavaTestClass.mockImplementation(async (_root, _file, className) => className);
  scanMavenProject.mockReset();
  scanMavenProject.mockResolvedValue(project);
  loadMavenConfiguration.mockReset();
  loadMavenConfiguration.mockResolvedValue({});
  resolveEffectiveMavenExecutable.mockReset();
  resolveEffectiveMavenExecutable.mockImplementation(
    async (_root: string, configured: string) => configured,
  );
  writeMavenConfiguration.mockClear();
  createMavenLaunchPlan.mockReset();
  createMavenLaunchPlan.mockResolvedValue(launchPlan);
  createMavenDependencyPlan.mockReset();
  createMavenDependencyPlan.mockResolvedValue(launchPlan);
  parseMavenDiagnostics.mockReset();
  parseMavenDiagnostics.mockResolvedValue([]);
  parseMavenTestResults.mockReset();
  parseMavenTestResults.mockResolvedValue({
    testsRun: 0,
    failures: 0,
    errors: 0,
    skipped: 0,
    passed: 0,
    success: true,
    failureDetails: [],
  });
  parseMavenDependencies.mockReset();
  parseMavenDependencies.mockResolvedValue(dependencyTree);
  resolveMavenLaunch.mockClear();
  resolveMavenEffectiveConfiguration.mockReset();
  resolveMavenEffectiveConfiguration.mockResolvedValue(effectiveConfiguration);
  saveWorkspaceBeforeLaunch.mockReset();
  saveWorkspaceBeforeLaunch.mockResolvedValue(undefined);
  startMavenProcess.mockClear();
  stopMavenProcess.mockClear();
  trace.mockClear();
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

  test("an unset Maven panel carries the resolved installation into the launch context", async () => {
    // JDT LS derives the local repository and mirrors from the installation's
    // conf/settings.xml, so an empty panel must not leave the context blank
    // while Maven builds keep using the configured installation.
    loadMavenConfiguration.mockResolvedValue({
      local: { version: 1, mavenExecutablePath: "" },
    });
    resolveEffectiveMavenExecutable.mockResolvedValueOnce(
      "D:/apache-maven-3.9.16/bin/mvn.cmd",
    );
    const store = createMavenStore("workspace", dependencies);

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(resolveEffectiveMavenExecutable).toHaveBeenCalledWith("D:/work", "");
    expect(store.getState().mavenExecutablePath).toBe("");
    expect(mavenLaunchContext(store.getState())?.mavenExecutablePath).toBe(
      "D:/apache-maven-3.9.16/bin/mvn.cmd",
    );
  });

  test("clearing the Maven path drops the previously resolved installation", async () => {
    loadMavenConfiguration.mockResolvedValue({
      local: { version: 1, mavenExecutablePath: "D:/Tools/apache-maven" },
    });
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    expect(mavenLaunchContext(store.getState())?.mavenExecutablePath).toBe(
      "D:/Tools/apache-maven",
    );

    store.getState().actions.updateLocalConfiguration({
      settingsPath: "",
      localRepositoryPath: "",
      mavenExecutablePath: "",
      javaHomePath: "",
    });

    // Keeping the old selection would import against an installation the user
    // just removed, so the fallback stays empty until the reload recomputes it.
    expect(mavenLaunchContext(store.getState())?.mavenExecutablePath).toBeNull();
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

  test("explicit settings save reports write failure and retries unchanged values", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const settings = {
      settingsPath: "",
      localRepositoryPath: "",
      mavenExecutablePath: "D:/fixture/maven",
      javaHomePath: "D:/fixture/jdk",
    };
    writeMavenConfiguration.mockImplementationOnce(async () => {
      throw new Error("fixture write failed");
    });
    await expect(store.getState().actions.saveLocalConfiguration(settings)).rejects.toThrow("fixture write failed");
    await store.getState().actions.saveLocalConfiguration(settings);
    expect(writeMavenConfiguration).toHaveBeenCalledTimes(2);
    expect(store.getState().configurationSaveError).toBeNull();
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

  test("skips seeding when no Maven project is loaded", () => {
    const store = createMavenStore("workspace", dependencies);
    store.getState().actions.seedLocalConfiguration({
      mavenExecutablePath: "D:/Tools/apache-maven",
    });
    expect(store.getState().mavenExecutablePath).toBe("");
  });

  test("imports a legacy toolchain only before Maven settings exist", async () => {
    const store = createMavenStore("workspace", dependencies);
    store.getState().actions.seedLocalConfiguration({
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    });
    expect(store.getState().mavenExecutablePath).toBe("");

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(store.getState().mavenExecutablePath).toBe("D:/Tools/apache-maven");
    expect(store.getState().javaHomePath).toBe("C:/Java/jdk-21");
    expect(store.getState().reloadRequired).toBe(false);

    store.getState().actions.seedLocalConfiguration({
      settingsPath: "C:/Other/settings.xml",
      mavenExecutablePath: "D:/Other/maven",
    });
    expect(store.getState().settingsPath).toBe("");
    expect(store.getState().mavenExecutablePath).toBe("D:/Tools/apache-maven");
  });

  test("imports a legacy toolchain after a project loads with no saved settings", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    expect(store.getState().mavenExecutablePath).toBe("");

    store.getState().actions.seedLocalConfiguration({
      mavenExecutablePath: "D:/Tools/apache-maven",
    });

    expect(store.getState().mavenExecutablePath).toBe("D:/Tools/apache-maven");
    expect(store.getState().reloadRequired).toBe(false);
  });

  test("keeps automatic fields empty after Maven settings are saved", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    store.getState().actions.updateLocalConfiguration({
      settingsPath: "C:/custom/settings.xml",
      localRepositoryPath: "",
      mavenExecutablePath: "",
      javaHomePath: "",
    });
    store.getState().actions.acknowledgeReload();
    expect(store.getState().reloadRequired).toBe(false);

    store.getState().actions.seedLocalConfiguration({
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    });

    expect(store.getState().settingsPath).toBe("C:/custom/settings.xml");
    expect(store.getState().mavenExecutablePath).toBe("");
    expect(store.getState().javaHomePath).toBe("");
  });

  test("does not import a legacy toolchain over a saved automatic configuration", async () => {
    loadMavenConfiguration.mockResolvedValue({
      local: {
        version: 1,
        settingsPath: null,
        localRepositoryPath: null,
        mavenExecutablePath: null,
        javaHomePath: null,
      },
    });
    const store = createMavenStore("workspace", dependencies);
    store.getState().actions.seedLocalConfiguration({
      mavenExecutablePath: "D:/Tools/apache-maven",
    });

    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    expect(store.getState().mavenExecutablePath).toBe("");
  });

  test("shares the effective machine configuration with every surface", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    // Loading the project already refreshes the detected values.
    expect(store.getState().effectiveConfiguration).toEqual(effectiveConfiguration);
    expect(resolveMavenEffectiveConfiguration).toHaveBeenCalledWith(
      "D:/work",
      "reactor",
      expect.objectContaining({ mavenExecutablePath: "", javaHomePath: "" }),
    );

    // A detection failure hides the detected values instead of reporting one.
    resolveMavenEffectiveConfiguration.mockRejectedValueOnce(new Error("detection failed"));
    await store.getState().actions.resolveEffectiveConfiguration();
    expect(store.getState().effectiveConfiguration).toBeNull();
  });

  test("clears the effective configuration for a workspace without Maven", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    expect(store.getState().effectiveConfiguration).toEqual(effectiveConfiguration);
    resolveMavenEffectiveConfiguration.mockClear();

    // A workspace without a detected Maven project never shows detected values,
    // and never asks the host to detect them either.
    scanMavenProject.mockResolvedValue(null);
    await store.getState().actions.loadProject("D:/plain", []);
    await store.getState().actions.resolveEffectiveConfiguration();

    expect(store.getState().effectiveConfiguration).toBeNull();
    expect(resolveMavenEffectiveConfiguration).not.toHaveBeenCalled();
  });

  test("ignores Maven detection that returns after switching to a non-Maven project", async () => {
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const releaseDetection = deferred<typeof effectiveConfiguration>();
    resolveMavenEffectiveConfiguration.mockImplementationOnce(() => releaseDetection.promise);

    const pendingDetection = store.getState().actions.resolveEffectiveConfiguration();
    try {
      expect(resolveMavenEffectiveConfiguration).toHaveBeenCalledTimes(2);
      scanMavenProject.mockResolvedValue(null);
      await store.getState().actions.loadProject("D:/plain", []);
      await store.getState().actions.resolveEffectiveConfiguration();
      expect(store.getState().effectiveConfigurationStatus).toBe("idle");

      releaseDetection.resolve(effectiveConfiguration);
      await pendingDetection;
      expect(store.getState().effectiveConfiguration).toBeNull();
      expect(store.getState().effectiveConfigurationStatus).toBe("idle");
    } finally {
      releaseDetection.resolve(effectiveConfiguration);
      await pendingDetection;
    }
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

  test("surfaces and logs a native string error from Maven launch resolution", async () => {
    resolveMavenLaunch.mockRejectedValueOnce("Maven executable path does not exist.");
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    await store.getState().actions.runGoals(["compile"], "service", "compile · service");

    expect(startMavenProcess).not.toHaveBeenCalled();
    expect(store.getState().taskStatus).toBe("failed");
    expect(store.getState().taskError).toBe("Maven executable path does not exist.");
    expect(store.getState().output).toBe("Maven executable path does not exist.\n");
    expect(trace).toHaveBeenCalledWith("error", "maven.launch", "Maven task launch failed", {
      workspaceId: "workspace",
      sessionId: expect.any(String),
      stage: "resolve-launch",
      taskTitle: "compile · service",
      reactorPath: "reactor",
      modulePath: "service",
      error: "Maven executable path does not exist.",
    });
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

  test("runs a Java test class and method through the shared Maven launch plan", async () => {
    scanMavenProject.mockResolvedValueOnce(mavenTestProject);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    await store
      .getState()
      .actions.runTestClass("D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java");
    expect(createMavenLaunchPlan).toHaveBeenLastCalledWith(
      "D:/work",
      expect.objectContaining({ reactorPath: "reactor" }),
      [
        "test",
        "-Dtest=com.example.CalculatorTest",
        "-Dsurefire.failIfNoSpecifiedTests=false",
      ],
      "service",
    );
    expect(store.getState().activeTestRun).toEqual({
      module: "service",
      selector: "com.example.CalculatorTest",
      title: "com.example.CalculatorTest",
      className: "com.example.CalculatorTest",
    });

    const classSession = store.getState().activeSessionId;
    expect(classSession).not.toBeNull();
    store.getState().actions.finishProcess(classSession!, 0);
    await Promise.resolve();

    await store
      .getState()
      .actions.runTestMethod(
        "D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java",
        "additionIsCorrect()",
      );
    expect(createMavenLaunchPlan).toHaveBeenLastCalledWith(
      "D:/work",
      expect.objectContaining({ reactorPath: "reactor" }),
      [
        "test",
        "-Dtest=com.example.CalculatorTest#additionIsCorrect",
        "-Dsurefire.failIfNoSpecifiedTests=false",
      ],
      "service",
    );
    expect(store.getState().lastTestRun?.selector).toBe(
      "com.example.CalculatorTest#additionIsCorrect",
    );
    store.getState().actions.finishProcess(store.getState().activeSessionId!, 0);
  });

  test("stops a test process at the injected deadline and ignores its late exit", async () => {
    scanMavenProject.mockResolvedValueOnce(mavenTestProject);
    const timer = new ManualTimer();
    const store = createMavenStore("workspace", dependencies, {
      setTimer: timer.set,
      clearTimer: timer.clear,
    });
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);
    await store
      .getState()
      .actions.runTestClass("D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java");
    const sessionId = store.getState().activeSessionId;

    expect(sessionId).not.toBeNull();
    expect(timer.size).toBe(1);
    store.getState().actions.clearOutput();
    expect(timer.size).toBe(1);
    await timer.fireNext();

    expect(stopMavenProcess).toHaveBeenCalledWith(sessionId);
    expect(store.getState().taskStatus).toBe("failed");
    expect(store.getState().taskError).toContain("timed out");
    expect(store.getState().activeSessionId).toBeNull();
    expect(store.getState().activeTestRun).toBeNull();
    expect(timer.size).toBe(0);

    store.getState().actions.finishProcess(sessionId!, 0);
    expect(store.getState().taskStatus).toBe("failed");
  });

  test("reports a successful Maven launch with no matching tests as a failure", async () => {
    parseMavenTestResults.mockResolvedValueOnce({
      testsRun: 0,
      failures: 0,
      errors: 0,
      skipped: 0,
      passed: 0,
      success: true,
      failureDetails: [],
    });
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const testRun = {
      module: null,
      selector: "com.example.MissingTest",
      title: "com.example.MissingTest",
    } as const;
    await store
      .getState()
      .actions.runGoals(["test", "-Dtest=com.example.MissingTest"], null, testRun.title, testRun);
    const sessionId = store.getState().activeSessionId;
    store.getState().actions.finishProcess(sessionId!, 0);
    await Promise.resolve();
    await Promise.resolve();

    expect(store.getState().taskStatus).toBe("failed");
    expect(store.getState().taskError).toBe('No tests matched selector "com.example.MissingTest".');
    expect(store.getState().testResults?.success).toBe(false);
  });

  test("parses test results after completion and drops a stale result after a newer run", async () => {
    const pendingResults = deferred<MavenTestResults>();
    parseMavenTestResults.mockImplementationOnce(() => pendingResults.promise);
    const parsedResults: MavenTestResults = {
      testsRun: 3,
      failures: 1,
      errors: 0,
      skipped: 1,
      passed: 1,
      success: false,
      failureDetails: [],
    };
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);

    await store.getState().actions.runGoals(
      ["test", "-Dtest=com.example.CalculatorTest"],
      null,
      "com.example.CalculatorTest",
      { module: null, selector: "com.example.CalculatorTest", title: "com.example.CalculatorTest" },
    );
    const completedSession = store.getState().activeSessionId;
    expect(completedSession).not.toBeNull();
    store.getState().actions.appendOutput(completedSession!, "Tests run: 3\n");
    store.getState().actions.finishProcess(completedSession!, 1);

    await store.getState().actions.runGoals(["compile"], null, "compile");
    pendingResults.resolve(parsedResults);
    await pendingResults.promise;
    await Promise.resolve();

    expect(parseMavenTestResults).toHaveBeenCalledWith("D:/work", expect.stringContaining("Tests run: 3"));
    expect(store.getState().testResults).toBeNull();
    expect(store.getState().taskTitle).toBe("compile");
  });

  test("keeps the last test available after clearing output", async () => {
    scanMavenProject.mockResolvedValueOnce(mavenTestProject);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/service/src/test/java/Test.java"]);

    await store
      .getState()
      .actions.runTestClass("D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java");
    const testRun = store.getState().lastTestRun;
    expect(testRun).toEqual({
      module: "service",
      selector: "com.example.CalculatorTest",
      title: "com.example.CalculatorTest",
      className: "com.example.CalculatorTest",
    });

    store.getState().actions.clearOutput();

    expect(store.getState().output).toBe("");
    expect(store.getState().testResults).toBeNull();
    expect(store.getState().lastTestRun).toEqual(testRun);
  });

  test("parses output received after clearing an active test run", async () => {
    const parsedResults: MavenTestResults = {
      testsRun: 1,
      failures: 0,
      errors: 0,
      skipped: 0,
      passed: 1,
      success: true,
      failureDetails: [],
    };
    parseMavenTestResults.mockResolvedValueOnce(parsedResults);
    const store = createMavenStore("workspace", dependencies);
    await store.getState().actions.loadProject("D:/work", ["reactor/pom.xml"]);
    const testRun = {
      module: null,
      selector: "com.example.CalculatorTest",
      title: "com.example.CalculatorTest",
    } as const;
    await store
      .getState()
      .actions.runGoals(["test", "-Dtest=com.example.CalculatorTest"], null, testRun.title, testRun);
    const sessionId = store.getState().activeSessionId;

    store.getState().actions.clearOutput();
    expect(store.getState().activeTestRun).toEqual(testRun);
    store.getState().actions.appendOutput(sessionId!, "Tests run: 1, Failures: 0\n");
    store.getState().actions.finishProcess(sessionId!, 0);
    await Promise.resolve();
    await Promise.resolve();

    expect(parseMavenTestResults).toHaveBeenCalledWith(
      "D:/work",
      expect.stringContaining("Tests run: 1"),
    );
    expect(store.getState().testResults).toEqual(parsedResults);
    expect(store.getState().activeTestRun).toBeNull();
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

describe("Maven test outcomes for editor Run markers", () => {
  const testFile = "D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java";
  const runStartedAt = 1_700_000_000_000;

  function createOutcomeStore() {
    const timer = new ManualTimer();
    const store = createMavenStore("workspace", dependencies, {
      setTimer: timer.set,
      clearTimer: timer.clear,
      now: () => runStartedAt,
    });
    return { store, timer };
  }

  test("reads the selected nested class's reports and replaces only its outcomes", async () => {
    scanMavenProject.mockResolvedValue(mavenTestProject);
    const reportRequests: unknown[] = [];
    parseMavenTestResults.mockImplementationOnce(async (...args: unknown[]) => {
      reportRequests.push(args[2]);
      return {
        testsRun: 1,
        failures: 1,
        errors: 0,
        skipped: 0,
        passed: 0,
        success: false,
        failureDetails: [],
        testCases: [
          {
            className: "com.example.CalculatorTest$Nested",
            method: "adds",
            status: "failed",
            message: "expected 3",
            invocations: 1,
          },
        ],
      };
    });
    const { store } = createOutcomeStore();
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);
    store.setState({
      testOutcomes: [
        { className: "com.example.CalculatorTest", method: "subtracts", status: "passed", invocations: 1 },
        { className: "com.example.CalculatorTest$Nested", method: "adds", status: "passed", invocations: 1 },
        { className: "com.example.OtherTest", method: "other", status: "passed", invocations: 1 },
      ],
    });

    await store
      .getState()
      .actions.runTestMethod(testFile, "adds", undefined, "com.example.CalculatorTest$Nested");
    expect(store.getState().activeTestRun?.selector).toBe("com.example.CalculatorTest$Nested#adds");
    const sessionId = store.getState().activeSessionId;
    store.getState().actions.finishProcess(sessionId!, 1);
    await Promise.resolve();
    await Promise.resolve();

    expect(reportRequests).toEqual([
      {
        module: "reactor/service",
        classes: ["com.example.CalculatorTest$Nested"],
        notBeforeMillis: runStartedAt,
      },
    ]);
    expect(store.getState().testOutcomes).toEqual([
      { className: "com.example.CalculatorTest", method: "subtracts", status: "passed", invocations: 1 },
      { className: "com.example.OtherTest", method: "other", status: "passed", invocations: 1 },
      {
        className: "com.example.CalculatorTest$Nested",
        method: "adds",
        status: "failed",
        message: "expected 3",
        invocations: 1,
      },
    ]);
  });

  test("rejects a class JDT no longer finds in the file without launching a different class", async () => {
    resolveJavaTestClass.mockResolvedValue(null);
    scanMavenProject.mockResolvedValue(mavenTestProject);
    const { store } = createOutcomeStore();
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);

    await store.getState().actions.runTestClass(testFile, undefined, "com.example.Unrelated");

    expect(store.getState().activeTestRun).toBeNull();
    expect(startMavenProcess).not.toHaveBeenCalled();
    expect(store.getState().taskError).toBeTruthy();
  });

  test("runs a sibling top-level class confirmed by JDT instead of the filename class", async () => {
    scanMavenProject.mockResolvedValue(mavenTestProject);
    const { store } = createOutcomeStore();
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);
    try {
      await store.getState().actions.runTestMethod(testFile, "adds", undefined, "com.example.OtherTest");
      expect(resolveJavaTestClass).toHaveBeenCalledWith("D:/work", testFile, "com.example.OtherTest");
      expect(store.getState().activeTestRun?.selector).toBe("com.example.OtherTest#adds");
    } finally {
      await store.getState().actions.stop();
    }
  });

  test("a passing method rerun preserves another method's failure and nested outcomes", async () => {
    scanMavenProject.mockResolvedValue(mavenTestProject);
    const { store } = createOutcomeStore();
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);
    const className = "com.example.CalculatorTest";
    const otherFailure = { className, method: "subtracts", status: "failed" as const, invocations: 1 };
    const nestedFailure = { ...otherFailure, className: className + "$Nested", method: "adds" };
    const passed = { className, method: "adds", status: "passed" as const, invocations: 1 };
    store.setState({ testOutcomes: [otherFailure, nestedFailure, { ...passed, status: "failed" }] });
    parseMavenTestResults.mockResolvedValueOnce({
      testsRun: 1, failures: 0, errors: 0, skipped: 0, passed: 1,
      success: true, failureDetails: [], testCases: [passed],
    });
    try {
      await store.getState().actions.runTestMethod(testFile, "adds");
      store.getState().actions.finishProcess(store.getState().activeSessionId!, 0);
      // The parser mock resolves immediately; flush its registered completion.
      await Promise.resolve();
      await Promise.resolve();
      expect(store.getState().testOutcomes).toEqual([otherFailure, nestedFailure, passed]);
    } finally {
      await store.getState().actions.stop();
    }
  });

  test("keeps earlier outcomes when a run wrote no readable reports", async () => {
    scanMavenProject.mockResolvedValue(mavenTestProject);
    const { store } = createOutcomeStore();
    await store.getState().actions.loadProject("D:/work", ["reactor/service/pom.xml"]);
    const previous = [
      { className: "com.example.OtherTest", method: "other", status: "passed" as const, invocations: 1 },
    ];
    store.setState({ testOutcomes: previous });

    await store.getState().actions.runTestClass(testFile);
    store.getState().actions.finishProcess(store.getState().activeSessionId!, 0);
    await Promise.resolve();
    await Promise.resolve();

    expect(store.getState().testOutcomes).toEqual(previous);
  });
});
