import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type {
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

const scanMavenProject = mock(async (_root: string, _paths?: string[]) => project);
const createMavenLaunchPlan = mock(async () => launchPlan);
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

const dependencies = {
  createMavenLaunchPlan,
  loadMavenConfiguration,
  parseMavenDiagnostics,
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
  parseMavenDiagnostics.mockReset();
  parseMavenDiagnostics.mockResolvedValue([]);
  resolveMavenLaunch.mockClear();
  saveWorkspaceBeforeLaunch.mockReset();
  saveWorkspaceBeforeLaunch.mockResolvedValue(undefined);
  startMavenProcess.mockClear();
  stopMavenProcess.mockClear();
});

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
    expect(store.getState().output).toBe("Maven task cancelled.\n");

    store.getState().actions.clearOutput();

    expect(store.getState().taskStatus).toBe("idle");
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
    expect(store.getState().runningTitle).toBe("test");
  });
});
