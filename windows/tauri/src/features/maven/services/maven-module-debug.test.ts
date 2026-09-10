import { expect, mock, test } from "bun:test";
import type { RunConfiguration } from "@/features/run/types/run.types";
import {
  createRunStore,
  releaseRunSessionWorkspace,
  type RunStoreDependencies,
} from "@/features/run/stores/run.store";
import {
  registerDebugSessionCleanup,
  releaseDebugSessionResources,
} from "@/features/debugger/services/debug-session-resources";
import { startMavenModuleDebug, type MavenModuleDebugDependencies } from "./maven-module-debug";

const configuration: RunConfiguration = {
  id: "spring-boot.maven:backend",
  name: "backend",
  provider: "spring-boot.maven",
  kindTitle: "Spring Boot",
  execution: "service",
  modulePath: "backend",
  cwd: ".",
  args: [],
  env: {},
  jvmArguments: [],
  programArguments: [],
  profiles: [],
  mavenSkipTests: null,
  javaHomePath: "",
  mavenExecutablePath: "",
  mavenJavaHomePath: "",
  toolchains: { java: "project-jdk", maven: "project-maven" },
  debugAdapter: "jdwp",
  source: "generated",
  disabled: false,
};

const runInstance = { sessionId: configuration.id, executionId: "debug-execution" };

function dependencies(events: string[]): MavenModuleDebugDependencies {
  return {
    prewarmJavaWorkspace: mock(async () => {
      events.push("java-ready");
      return { kind: "ready" };
    }),
    allocateDebugPort: mock(async () => {
      events.push("port-allocated");
      return 5005;
    }),
    initializeRunEvents: mock(async () => {
      events.push("run-events-ready");
    }),
    startRunConfiguration: mock(async (_workspaceId, _configurationId, port) => {
      events.push(`run:${port}`);
      return runInstance;
    }),
    waitForDebugPort: mock(async (port) => {
      events.push(`port-ready:${port}`);
    }),
    startJavaDebugServer: mock(async () => {
      events.push("adapter-ready");
      return 4711;
    }),
    initializeDebuggerEvents: mock(async () => {
      events.push("events-ready");
    }),
    startAdapterSession: mock(
      async (_configuration, targetPort, adapterPort, _breakpoints, workspacePath, onStarted) => {
        events.push(`adapter:${adapterPort}->${targetPort}`);
        const session = {
          id: "debug-session",
          command: `tcp://127.0.0.1:${adapterPort}`,
          args: [],
          cwd: workspacePath,
        };
        onStarted(session);
        return session;
      },
    ),
    startDebuggerSession: mock(() => events.push("debug-session-started")),
    registerSessionCleanup: mock((_sessionId, cleanup) => {
      events.push("cleanup-registered");
      void cleanup;
    }),
    stopAdapterSession: mock(async () => {
      events.push("adapter-stopped");
    }),
    stopRunSession: mock(async () => {
      events.push("run-stopped");
    }),
    breakpoints: () => [],
    hasActiveDebugSession: () => false,
    isCurrentWorkspace: () => true,
  };
}

test("starts Maven with JDWP before attaching the Java Debug Server", async () => {
  const events: string[] = [];
  const deps = dependencies(events);

  await expect(
    startMavenModuleDebug(
      { workspaceId: "workspace", root: "D:/work" },
      configuration,
      "D:/work/backend/src/main/java/App.java",
      deps,
    ),
  ).resolves.toEqual({
    kind: "started",
    sessionId: "debug-session",
    runSessionId: configuration.id,
  });

  expect(events).toEqual([
    "java-ready",
    "port-allocated",
    "run-events-ready",
    "run:5005",
    "port-ready:5005",
    "adapter-ready",
    "events-ready",
    "adapter:4711->5005",
    "cleanup-registered",
    "debug-session-started",
  ]);
});

test("stops the Maven process when JDWP never becomes ready", async () => {
  const events: string[] = [];
  const deps = dependencies(events);
  deps.waitForDebugPort = mock(async () => {
    throw new Error("JDWP timeout");
  });

  await expect(
    startMavenModuleDebug(
      { workspaceId: "workspace", root: "D:/work" },
      configuration,
      "D:/work/backend/src/main/java/App.java",
      deps,
    ),
  ).rejects.toThrow("JDWP timeout");

  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", runInstance);
  expect(deps.startAdapterSession).not.toHaveBeenCalled();
});

test("drops a stale workspace launch and reaps the process", async () => {
  const events: string[] = [];
  const deps = dependencies(events);
  let currentChecks = 0;
  deps.isCurrentWorkspace = () => {
    currentChecks += 1;
    return currentChecks < 4;
  };

  await expect(
    startMavenModuleDebug(
      { workspaceId: "workspace", root: "D:/work" },
      configuration,
      "D:/work/backend/src/main/java/App.java",
      deps,
    ),
  ).resolves.toEqual({ kind: "stale" });

  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", runInstance);
  expect(deps.waitForDebugPort).not.toHaveBeenCalled();
});

test("does not replace a debug session that becomes active while the adapter connects", async () => {
  const events: string[] = [];
  const deps = dependencies(events);
  let activeDebugSession = false;
  deps.hasActiveDebugSession = () => activeDebugSession;
  deps.startAdapterSession = mock(
    async (_configuration, _targetPort, _adapterPort, _breakpoints, workspacePath, onStarted) => {
      const session = {
        id: "debug-session",
        command: "tcp://127.0.0.1:4711",
        args: [],
        cwd: workspacePath,
      };
      activeDebugSession = true;
      onStarted(session);
      return session;
    },
  );

  await expect(
    startMavenModuleDebug(
      { workspaceId: "workspace", root: "D:/work" },
      configuration,
      "D:/work/backend/src/main/java/App.java",
      deps,
    ),
  ).rejects.toThrow("Stop the active debug session");

  expect(deps.stopAdapterSession).toHaveBeenCalledWith("debug-session");
  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", runInstance);
  expect(deps.registerSessionCleanup).not.toHaveBeenCalled();
  expect(deps.startDebuggerSession).not.toHaveBeenCalled();
});

for (const execution of ["service", "application"] as const) {
  for (const order of ["late-event", "stop-in-flight"] as const) {
    test(`${order}: Debug cleanup preserves a replacement ${execution} Run`, async () => {
      const processes = new Map<string, string>();
      let stopEntered = false;
      const finishStop = Promise.withResolvers<void>();
      let debugExecution: string | undefined;
      let cleanup: Promise<void> | undefined;
      const stopRunProcess = mock(async (sessionId: string, executionId?: string) => {
        if (order === "stop-in-flight" && executionId && executionId === debugExecution) {
          stopEntered = true;
          await finishStop.promise;
        }
        if (!executionId || processes.get(sessionId) === executionId) processes.delete(sessionId);
      });
      const runDependencies: RunStoreDependencies = {
        saveWorkspaceBeforeLaunch: async () => undefined,
        mavenLaunchContextForWorkspace: async () => null,
        createLaunchPlan: async () => ({
          executable: { toolchain: "project-maven" },
          arguments: [],
          workingDirectory: ".",
        }),
        resolveRunLaunch: async () => ({
          executable: "mvn.cmd",
          workingDirectory: "D:/work",
          environment: {},
        }),
        startRunProcess: async ({ sessionId, executionId }) => {
          processes.set(sessionId, executionId!);
        },
        stopRunProcess,
      };
      const selected = { ...configuration, execution };
      const store = createRunStore(`debug-cleanup-${execution}`, runDependencies);
      store.setState({ root: "D:/work", configurations: [selected] });
      const deps = dependencies([]);
      deps.startRunConfiguration = (_workspace, id, port) =>
        store.getState().actions.runConfigurationInstance(id, undefined, port);
      deps.stopRunSession = (_workspace, instance) =>
        store.getState().actions.stop(instance.sessionId, instance.executionId);
      deps.registerSessionCleanup = registerDebugSessionCleanup;
      const slot = execution === "service" ? selected.id : "primary";
      try {
        await startMavenModuleDebug(
          { workspaceId: "workspace", root: "D:/work" },
          selected,
          "D:/work/App.java",
          deps,
        );
        debugExecution = processes.get(slot);
        if (order === "stop-in-flight") {
          cleanup = releaseDebugSessionResources("debug-session");
          expect(stopEntered).toBe(true);
        }
        // Replace either before the old end event or while its native stop is pending.
        expect(await store.getState().actions.runConfiguration(selected.id)).toBe(slot);
        const replacement = processes.get(slot);
        expect(replacement).toBeDefined();
        expect(replacement).not.toBe(debugExecution);
        finishStop.resolve();
        await (cleanup ?? releaseDebugSessionResources("debug-session"));
        expect(processes.get(slot)).toBe(replacement);
        expect(stopRunProcess).toHaveBeenCalledWith(slot, debugExecution);
        expect(
          execution === "service"
            ? store.getState().sessions[0].isRunning
            : store.getState().primaryRunning,
        ).toBe(true);
      } finally {
        finishStop.resolve();
        await cleanup;
        await releaseDebugSessionResources("debug-session");
        await store.getState().actions.stop(slot);
        releaseRunSessionWorkspace(slot);
      }
      expect(processes.size).toBe(0);
    });
  }
}
