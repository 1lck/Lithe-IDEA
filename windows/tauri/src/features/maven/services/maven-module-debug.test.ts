import { expect, mock, test } from "bun:test";
import type { RunConfiguration } from "@/features/run/types/run.types";
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
      return configuration.id;
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

  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", configuration.id);
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

  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", configuration.id);
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
  expect(deps.stopRunSession).toHaveBeenCalledWith("workspace", configuration.id);
  expect(deps.registerSessionCleanup).not.toHaveBeenCalled();
  expect(deps.startDebuggerSession).not.toHaveBeenCalled();
});
