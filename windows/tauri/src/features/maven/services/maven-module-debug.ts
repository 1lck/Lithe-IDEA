import {
  allocateJvmDebugPort,
  waitForJvmDebugPort,
} from "@/features/debugger/api/debug-adapter-host-api";
import { initializeDebuggerEventBridge } from "@/features/debugger/services/debug-adapter-events";
import {
  startConnectedDebugLaunchSession,
  stopDebugAdapterSession,
} from "@/features/debugger/services/debug-adapter-service";
import { registerDebugSessionCleanup } from "@/features/debugger/services/debug-session-resources";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import type {
  DebugAdapterSessionInfo,
  DebugBreakpoint,
  DebugSession,
} from "@/features/debugger/types/debugger.types";
import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { useRunStore } from "@/features/run/stores/run.store";
import type { RunConfiguration, RunProcessInstance } from "@/features/run/types/run.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { frontendTrace } from "@/utils/frontend-trace";

const JVM_DEBUG_START_TIMEOUT_MILLISECONDS = 30_000;

type JavaWorkspaceOutcome = { kind: string };

export interface MavenModuleDebugDependencies {
  prewarmJavaWorkspace(
    scope: WorkspaceLaunchScope,
    representativeJavaFile: string,
  ): Promise<JavaWorkspaceOutcome>;
  allocateDebugPort(): Promise<number>;
  initializeRunEvents(): Promise<void>;
  startRunConfiguration(
    workspaceId: string,
    configurationId: string,
    debugPort: number,
  ): Promise<RunProcessInstance | null>;
  waitForDebugPort(port: number, timeoutMilliseconds: number): Promise<void>;
  startJavaDebugServer(workspacePath: string): Promise<number>;
  initializeDebuggerEvents(): Promise<void>;
  startAdapterSession(
    configuration: RunConfiguration,
    targetPort: number,
    adapterPort: number,
    breakpoints: DebugBreakpoint[],
    workspacePath: string,
    onSessionStarted: (session: DebugAdapterSessionInfo) => void,
  ): Promise<DebugAdapterSessionInfo>;
  startDebuggerSession(session: DebugSession): void;
  registerSessionCleanup(sessionId: string, cleanup: () => Promise<void>): void;
  stopAdapterSession(sessionId: string): Promise<void>;
  stopRunSession(workspaceId: string, instance: RunProcessInstance): Promise<void>;
  breakpoints(): DebugBreakpoint[];
  hasActiveDebugSession(): boolean;
  isCurrentWorkspace(scope: WorkspaceLaunchScope): boolean;
}

const defaultDependencies: MavenModuleDebugDependencies = {
  prewarmJavaWorkspace: (scope, representativeJavaFile) =>
    getJavaWorkspaceLanguageServerOwner().prewarm(scope, representativeJavaFile),
  allocateDebugPort: allocateJvmDebugPort,
  initializeRunEvents: ensureRunProcessListeners,
  startRunConfiguration: (workspaceId, configurationId, debugPort) =>
    useRunStore
      .getStore(workspaceId)
      .getState()
      .actions.runConfigurationInstance(configurationId, undefined, debugPort),
  waitForDebugPort: waitForJvmDebugPort,
  startJavaDebugServer: (workspacePath) =>
    invokeLsp<number>("java_start_debug_session", { workspacePath }),
  initializeDebuggerEvents: initializeDebuggerEventBridge,
  startAdapterSession: (
    configuration,
    targetPort,
    adapterPort,
    breakpoints,
    workspacePath,
    onSessionStarted,
  ) =>
    startConnectedDebugLaunchSession(
      {
        id: configuration.id,
        name: configuration.name,
        runtime: "custom",
        type: "java",
        request: "attach",
        cwd: workspacePath,
        launchArguments: { hostName: "127.0.0.1", port: targetPort },
        source: configuration.source === "generated" ? "generated" : "workspace",
      },
      adapterPort,
      breakpoints,
      workspacePath,
      onSessionStarted,
    ),
  startDebuggerSession: (session) => useDebuggerStore.getState().actions.startSession(session),
  registerSessionCleanup: registerDebugSessionCleanup,
  stopAdapterSession: stopDebugAdapterSession,
  stopRunSession: (workspaceId, instance) =>
    useRunStore
      .getStore(workspaceId)
      .getState()
      .actions.stop(instance.sessionId, instance.executionId),
  breakpoints: () => useDebuggerStore.getState().breakpoints,
  hasActiveDebugSession: () => {
    const status = useDebuggerStore.getState().activeSession?.status;
    return status === "running" || status === "paused";
  },
  isCurrentWorkspace: (scope) =>
    workspaceRuntimeRegistry.getActiveWorkspaceId() === scope.workspaceId &&
    useRunStore.getStore(scope.workspaceId).getState().root === scope.root,
};

class StaleMavenDebugLaunch extends Error {}

function assertCurrentWorkspace(
  scope: WorkspaceLaunchScope,
  dependencies: MavenModuleDebugDependencies,
): void {
  if (!dependencies.isCurrentWorkspace(scope)) throw new StaleMavenDebugLaunch();
}

function assertNoActiveDebugSession(dependencies: MavenModuleDebugDependencies): void {
  if (dependencies.hasActiveDebugSession()) {
    throw new Error("Stop the active debug session before starting another one.");
  }
}

export type MavenModuleDebugOutcome =
  | { kind: "started"; sessionId: string; runSessionId: string }
  | { kind: "stale" };

export async function startMavenModuleDebug(
  scope: WorkspaceLaunchScope,
  configuration: RunConfiguration,
  representativeJavaFile: string,
  dependencies: MavenModuleDebugDependencies = defaultDependencies,
): Promise<MavenModuleDebugOutcome> {
  assertNoActiveDebugSession(dependencies);
  frontendTrace("info", "maven.debug", "Starting Maven module debug", {
    workspaceId: scope.workspaceId,
    configurationId: configuration.id,
    modulePath: configuration.modulePath ?? ".",
  });
  let runInstance: RunProcessInstance | null = null;
  let adapterSessionId: string | null = null;
  try {
    assertCurrentWorkspace(scope, dependencies);
    const preparation = await dependencies.prewarmJavaWorkspace(scope, representativeJavaFile);
    if (preparation.kind !== "ready") {
      throw new Error(`The Java language service is not ready (${preparation.kind}).`);
    }
    assertCurrentWorkspace(scope, dependencies);

    const targetPort = await dependencies.allocateDebugPort();
    await dependencies.initializeRunEvents();
    assertCurrentWorkspace(scope, dependencies);
    assertNoActiveDebugSession(dependencies);
    runInstance = await dependencies.startRunConfiguration(
      scope.workspaceId,
      configuration.id,
      targetPort,
    );
    if (!runInstance) {
      throw new Error(`Could not start the Run configuration ${configuration.name}.`);
    }
    assertCurrentWorkspace(scope, dependencies);
    await dependencies.waitForDebugPort(targetPort, JVM_DEBUG_START_TIMEOUT_MILLISECONDS);
    assertCurrentWorkspace(scope, dependencies);
    assertNoActiveDebugSession(dependencies);

    const adapterPort = await dependencies.startJavaDebugServer(scope.root);
    assertCurrentWorkspace(scope, dependencies);
    await dependencies.initializeDebuggerEvents();
    const ownedRunInstance = runInstance;
    const session = await dependencies.startAdapterSession(
      configuration,
      targetPort,
      adapterPort,
      dependencies.breakpoints(),
      scope.root,
      (started) => {
        adapterSessionId = started.id;
        assertCurrentWorkspace(scope, dependencies);
        assertNoActiveDebugSession(dependencies);
        dependencies.registerSessionCleanup(started.id, () =>
          dependencies.stopRunSession(scope.workspaceId, ownedRunInstance),
        );
        dependencies.startDebuggerSession({
          id: started.id,
          name: configuration.name,
          configId: configuration.id,
          command: started.command,
          cwd: started.cwd,
          startedAt: Date.now(),
          status: "running",
          adapterSession: true,
        });
      },
    );
    frontendTrace("info", "maven.debug", "Maven module debug started", {
      workspaceId: scope.workspaceId,
      configurationId: configuration.id,
      sessionId: session.id,
      runSessionId: ownedRunInstance.sessionId,
    });
    return { kind: "started", sessionId: session.id, runSessionId: ownedRunInstance.sessionId };
  } catch (error) {
    const cleanupFailures: string[] = [];
    if (adapterSessionId) {
      await dependencies.stopAdapterSession(adapterSessionId).catch((cleanupError) => {
        cleanupFailures.push(
          `adapter: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`,
        );
      });
    }
    if (runInstance) {
      await dependencies.stopRunSession(scope.workspaceId, runInstance).catch((cleanupError) => {
        cleanupFailures.push(
          `run: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`,
        );
      });
    }
    if (cleanupFailures.length > 0) {
      frontendTrace("error", "maven.debug", "Maven module debug cleanup failed", {
        workspaceId: scope.workspaceId,
        configurationId: configuration.id,
        adapterSessionId,
        runSessionId: runInstance?.sessionId,
        error: cleanupFailures.join("; "),
      });
    }
    if (error instanceof StaleMavenDebugLaunch) return { kind: "stale" };
    frontendTrace("error", "maven.debug", "Maven module debug failed", {
      workspaceId: scope.workspaceId,
      configurationId: configuration.id,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}
