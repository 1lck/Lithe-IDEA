import { getProjectPreparation } from "@/features/run/stores/project-preparation.store";
import type { JavaRunLaunchPreparation } from "@/features/run/services/java-run-launch";
import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { CompletionList } from "vscode-languageserver-protocol";

const emit = mock(async () => undefined);
const emitTo = mock(async () => undefined);
const listen = mock(async () => () => undefined);
const once = mock(async () => () => undefined);
const TauriEvent = {
  WINDOW_RESIZED: "tauri://resize",
  WINDOW_MOVED: "tauri://move",
  WINDOW_CLOSE_REQUESTED: "tauri://close-requested",
  WINDOW_DESTROYED: "tauri://destroyed",
  WINDOW_FOCUS: "tauri://focus",
  WINDOW_BLUR: "tauri://blur",
  WINDOW_SCALE_FACTOR_CHANGED: "tauri://scale-change",
  WINDOW_THEME_CHANGED: "tauri://theme-changed",
  WINDOW_CREATED: "tauri://window-created",
  WINDOW_SUSPENDED: "tauri://suspended",
  WINDOW_RESUMED: "tauri://resumed",
  WEBVIEW_CREATED: "tauri://webview-created",
  DRAG_ENTER: "tauri://drag-enter",
  DRAG_OVER: "tauri://drag-over",
  DRAG_DROP: "tauri://drag-drop",
  DRAG_LEAVE: "tauri://drag-leave",
} as const;
const frontendTrace = mock(() => undefined);
const cancelCoreOperation = mock(async () => false);
const commands: string[] = [];
let scenario:
  | "held-plugin-start"
  | "poll-failure"
  | "preparation-snapshot"
  | "capabilities"
  | "delayed-start"
  | "failure"
  | "multi-session"
  | "runtime-ready-transition"
  | "semantic-request"
  | "structured-log"
  | "virtual-document" = "failure";
let pluginStartGate: Promise<void> | undefined;
let pluginStartEntered: (() => void) | undefined;
let releasePluginStart: (() => void) | undefined;
let startPayload: Record<string, unknown> | undefined;
let requestPayload: Record<string, unknown> | undefined;
const requestPayloads: Record<string, unknown>[] = [];
let pollCount = 0;
let startCount = 0;
const sessionPollCounts = new Map<string, number>();
let virtualDocumentPending = false;
let semanticRequestPending = false;
let semanticOperationId = "";
let semanticRequestResult: unknown = { locations: [] };
let semanticRequestResults: unknown[] = [];
let semanticResultGate: Promise<void> | undefined;
let releaseSemanticResult: (() => void) | undefined;
let onSemanticRequest: (() => void) | undefined;
let providerAckGate: Promise<void> | undefined;
let releaseProviderAck: (() => void) | undefined;
let providerProgress: unknown[] = [];
let onCoreCancel: (() => void) | undefined;
let semanticRefreshOnReady = false;
let eventsAroundReady: { before: unknown[]; after: unknown[] } = { before: [], after: [] };
let releaseInitialization: (() => void) | undefined;

/** A queued semantic outcome that Core reports as a structured request error. */
interface CoreRequestFailure {
  coreError: {
    code: string;
    message: string;
    stage?: string;
    javaBuildReport?: Record<string, unknown>;
  };
}

function isCoreRequestFailure(value: unknown): value is CoreRequestFailure {
  return typeof value === "object" && value !== null && "coreError" in value;
}
let releaseRuntimeReady: (() => void) | undefined;

function readyEvents(sessionId: string) {
  return [
    {
      type: "projectPreparation",
      providerId: "java",
      sessionId,
      result: { phase: "ready", status: "ready", blocksRun: false },
    },
    {
      type: "featuresChanged",
      providerId: "java",
      sessionId,
      capabilities: [
        "codeActions",
        "completion",
        "definition",
        "executeCommand",
        "hover",
        "implementation",
        "references",
        "rename",
        "typeDefinition",
      ],
    },
    {
      type: "stateChanged",
      state: "ready",
      providerId: "java",
      sessionId,
    },
  ];
}

const executeCore = mock(
  async (request: { id: string; command: string; payload?: Record<string, unknown> }) => {
    commands.push(request.command);
    if (request.command === "lsp.startServer") {
      startCount += 1;
      startPayload = request.payload;
      if (scenario === "held-plugin-start") {
        pluginStartEntered?.();
        await pluginStartGate;
      }
      const sessionId =
        scenario === "failure"
          ? "failed-java-session"
          : scenario === "multi-session"
            ? `java-session-${startCount}`
            : "java-session";
      return {
        id: request.id,
        ok: true as const,
        data: { sessionId },
      };
    }
    if (request.command === "lsp.waitEvents") {
      pollCount += 1;
      const sessionId = String(request.payload?.sessionId ?? "java-session");
      const sessionPollCount = (sessionPollCounts.get(sessionId) ?? 0) + 1;
      sessionPollCounts.set(sessionId, sessionPollCount);
      // Core's waitEvents command is a blocking long poll. Yield a task here
      // so empty mock responses cannot create a tight microtask-only pump.
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      if (scenario === "poll-failure") {
        throw new Error("Core event transport unavailable");
      }
      if (scenario === "delayed-start") {
        if (pollCount === 1) {
          await new Promise<void>((resolve) => {
            releaseInitialization = resolve;
          });
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "stateChanged",
                  state: "ready",
                  providerId: "java",
                  sessionId,
                },
              ],
            },
          };
        }
        return { id: request.id, ok: true as const, data: { events: [] } };
      }
      if (scenario === "preparation-snapshot") {
        return {
          id: request.id,
          ok: true as const,
          data: {
            events:
              sessionPollCount === 1
                ? readyEvents(sessionId).filter((event) => event.type !== "projectPreparation")
                : [],
            projectPreparation: { phase: "configuring", status: "loading", blocksRun: true },
          },
        };
      }
      if (scenario === "capabilities" || scenario === "multi-session") {
        return {
          id: request.id,
          ok: true as const,
          data: { events: sessionPollCount === 1 ? readyEvents(sessionId) : [] },
        };
      }
      if (scenario === "structured-log") {
        return {
          id: request.id,
          ok: true as const,
          data: {
            events:
              sessionPollCount === 1
                ? [
                    {
                      type: "log",
                      level: "info",
                      message: "Java workspace import progress",
                      detail: JSON.stringify({
                        stage: "serviceReady",
                        currentProject: "module-a",
                        downloadedBytes: 1024,
                      }),
                      providerId: "java",
                      sessionId,
                    },
                    {
                      type: "log",
                      level: "error",
                      message: "Maven profile project update completed",
                      mavenProfileProject: {
                        projectUri: "file:///C:/work/module-a",
                        status: "failed",
                        errorDetails: "profile resolution failed",
                      },
                      mavenProfileTask: "partiallySucceeded",
                      providerId: "java",
                      sessionId,
                    },
                    ...readyEvents(sessionId),
                  ]
                : [],
          },
        };
      }
      if (scenario === "runtime-ready-transition") {
        if (sessionPollCount === 1) {
          return {
            id: request.id,
            ok: true as const,
            data: { events: readyEvents(sessionId) },
          };
        }
        if (sessionPollCount === 2) {
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "stateChanged",
                  state: "initializing",
                  providerId: "java",
                  sessionId,
                },
              ],
            },
          };
        }
        if (sessionPollCount === 3) {
          await new Promise<void>((resolve) => {
            releaseRuntimeReady = resolve;
          });
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "stateChanged",
                  state: "ready",
                  providerId: "java",
                  sessionId,
                },
              ],
            },
          };
        }
        return { id: request.id, ok: true as const, data: { events: [] } };
      }
      if (scenario === "semantic-request") {
        if (sessionPollCount === 1) {
          return {
            id: request.id,
            ok: true as const,
            data: { events: [
              ...eventsAroundReady.before,
              ...readyEvents(sessionId),
              ...(semanticRefreshOnReady ? [{ type: "semanticTokensRefresh", sessionId }] : []),
              ...eventsAroundReady.after,
            ] },
          };
        }
        if (semanticRequestPending) {
          semanticRequestPending = false;
          await semanticResultGate;
          const outcome =
            semanticRequestResults.length > 0
              ? semanticRequestResults.shift()
              : semanticRequestResult;
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                ...providerProgress.splice(0).map(result => ({ type: "requestProgress", sessionId, operationId: semanticOperationId, result })),
                {
                  type: "requestCompleted",
                  providerId: "java",
                  sessionId,
                  operationId: semanticOperationId,
                  ...(isCoreRequestFailure(outcome)
                    ? { error: outcome.coreError }
                    : { result: outcome }),
                },
              ],
            },
          };
        }
        return { id: request.id, ok: true as const, data: { events: [] } };
      }
      if (scenario === "virtual-document") {
        if (pollCount === 1) {
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "stateChanged",
                  state: "ready",
                  providerId: "java",
                  sessionId,
                },
              ],
            },
          };
        }
        if (virtualDocumentPending) {
          virtualDocumentPending = false;
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "requestCompleted",
                  providerId: "java",
                  sessionId,
                  operationId: "virtualDocument-operation",
                  result: { text: "public final class String {}" },
                },
              ],
            },
          };
        }
        return { id: request.id, ok: true as const, data: { events: [] } };
      }
      return {
        id: request.id,
        ok: true as const,
        data: {
          events:
            pollCount === 1
              ? [
                  {
                    type: "log",
                    level: "warning",
                    message: "Language-server stderr",
                    detail: "JDTLS failed before initialization",
                    providerId: "java",
                    sessionId: "failed-java-session",
                  },
                  {
                    type: "stateChanged",
                    state: "failed",
                    providerId: "java",
                    sessionId: "failed-java-session",
                    error: {
                      code: "serverExited",
                      stage: "process",
                      message: "Language-server process exited.",
                      underlyingMessage: "JVM startup failed",
                      processExitCode: 13,
                    },
                  },
                ]
              : [],
        },
      };
    }
    if (request.command === "lsp.request" || request.command === "lsp.buildRequest" || request.command === "java.resolveNavigation" || request.command === "java.prepareLaunch") {
      requestPayload = request.payload;
      requestPayloads.push(request.payload ?? {});
      const operation = String(request.payload?.operation ?? request.command);
      const operationId = request.command === "lsp.buildRequest" ? String(request.payload?.operationId) : `${operation}-operation`;
      if (scenario === "semantic-request") {
        semanticRequestPending = true;
        semanticOperationId = operationId;
        onSemanticRequest?.();
      } else {
        virtualDocumentPending = true;
      }
      if (request.command === "lsp.buildRequest") await providerAckGate;
      return {
        id: request.id,
        ok: true as const,
        data: { operationId },
      };
    }
    if (request.command === "lsp.updateMavenConfiguration") {
      requestPayload = request.payload;
      return {
        id: request.id,
        ok: true as const,
        data: { settingsChanged: true, projectsReloaded: false, profilesUpdating: false },
      };
    }
    if (request.command === "lsp.cancelOperation") onCoreCancel?.();
    if (request.command === "lsp.saveDocument") {
      requestPayload = request.payload;
      return { id: request.id, ok: true as const, data: { sent: true } };
    }
    return { id: request.id, ok: true as const, data: null };
  },
);

mock.module("@tauri-apps/api/event", () => ({ emit, emitTo, listen, once, TauriEvent }));
mock.module("@/core/lithe-core-client", () => ({ cancelCoreOperation, executeCore }));
mock.module("@/utils/frontend-trace", () => ({ frontendTrace }));

const {
  getLspSessionSnapshot,
  getLspWorkspaceSessionSnapshot,
  ownsLspSession,
  invokeLsp,
  startCoreBuildProvider,
  stopCoreBuildProvider,
  requestCoreBuildProvider,
  LSP_EXPLICITLY_UNAVAILABLE_COMMANDS,
  LSP_OPERATION_BY_COMMAND,
} = await import("./lsp-core-adapter");

function installSessionStorage() {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  const values = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };
  Object.defineProperty(globalThis, "sessionStorage", { configurable: true, value: storage });
  return {
    values,
    restore() {
      if (previous) {
        Object.defineProperty(globalThis, "sessionStorage", previous);
      } else {
        delete (globalThis as { sessionStorage?: Storage }).sessionStorage;
      }
    },
  };
}

describe("Rust Core LSP adapter failures", () => {
  beforeEach(() => {
    scenario = "failure";
    commands.length = 0;
    startPayload = undefined;
    requestPayload = undefined;
    requestPayloads.length = 0;
    pollCount = 0;
    startCount = 0;
    sessionPollCounts.clear();
    virtualDocumentPending = false;
    semanticRequestPending = false;
    semanticOperationId = "";
    semanticRequestResult = { locations: [] };
    semanticRequestResults = [];
    semanticResultGate = undefined;
    releaseSemanticResult = undefined;
    onSemanticRequest = undefined;
    providerAckGate = undefined;
    releaseProviderAck = undefined;
    providerProgress = [];
    onCoreCancel = undefined;
    semanticRefreshOnReady = false;
    eventsAroundReady = { before: [], after: [] };
    releaseInitialization = undefined;
    releaseRuntimeReady = undefined;
    emit.mockClear();
    frontendTrace.mockClear();
    executeCore.mockClear();
  });

  afterEach(async () => {
    releaseSemanticResult?.();
    releaseProviderAck?.();
    releaseInitialization?.();
    releaseRuntimeReady?.();
    await invokeLsp("lsp_stop", { workspacePath: "C:/work/project" });
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  });

  test("logs Core output, preserves failure details, and destroys the session", async () => {
    let failure: (Error & { code?: string; details?: string }) | null = null;
    try {
      await invokeLsp("lsp_start_for_file", {
        workspacePath: "C:/work",
        filePath: "C:/work/Main.java",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
        runtimeExecutablePath: "C:/Lithe/jdk/bin/java.exe",
        jdtlsLaunchResources: {
          launcherJarPath: "C:/Lithe/jdtls/plugins/equinox.jar",
          configurationDirectory: "C:/Lithe/jdtls/config_win",
          lombokAgentPath: "C:/Lithe/jdtls/lombok/lombok.jar",
          javaDebugBundlePath:
            "C:/Lithe/jdtls/java-debug/com.microsoft.java.debug.plugin-0.53.1.jar",
        },
      });
    } catch (error) {
      failure = error as Error & { code?: string; details?: string };
    }

    expect(failure).not.toBeNull();
    expect(failure?.message).toBe(
      "Language-server process exited. JVM startup failed; exit code 13",
    );
    expect(failure?.code).toBe("serverExited");
    expect(failure?.details).toBe("JVM startup failed; exit code 13");
    expect(startPayload?.initializeTimeoutMilliseconds).toBe(30_000);
    // Core owns both deadlines; Java builds get the long project-build bound.
    expect(startPayload?.requestTimeoutMilliseconds).toBe(30_000);
    expect(startPayload?.javaBuildTimeoutMilliseconds).toBe(600_000);
    expect(startPayload?.runtimeExecutablePath).toBe("C:/Lithe/jdk/bin/java.exe");
    expect(startPayload?.jdtlsLaunchResources).toEqual({
      launcherJarPath: "C:/Lithe/jdtls/plugins/equinox.jar",
      configurationDirectory: "C:/Lithe/jdtls/config_win",
      lombokAgentPath: "C:/Lithe/jdtls/lombok/lombok.jar",
      javaDebugBundlePath: "C:/Lithe/jdtls/java-debug/com.microsoft.java.debug.plugin-0.53.1.jar",
    });
    expect(frontendTrace).toHaveBeenCalledWith(
      "warn",
      "lsp.runtime",
      "Language-server stderr",
      expect.objectContaining({ detail: "JDTLS failed before initialization" }),
    );
    expect(emit).toHaveBeenCalledWith("lsp://server-crashed", {});
    expect(commands).toEqual([
      "lsp.startServer",
      "lsp.waitEvents",
      "lsp.stopServer",
      "lsp.destroyServer",
    ]);
  });

  test("stores negotiated features and exposes them in the owning session snapshot", async () => {
    scenario = "capabilities";
    const testStorage = installSessionStorage();
    const filePath = "C:/work/Main.java";

    try {
      await invokeLsp("lsp_start_for_file", {
        workspacePath: "C:/work",
        filePath,
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });

      expect(getLspSessionSnapshot({ filePath })).toEqual({
        id: "java-session",
        workspacePath: "C:/work",
        languageId: "java",
        phase: "ready",
        operationId: expect.any(String),
        featureState: {
          phase: "known",
          features: [
            "codeActions",
            "completion",
            "definition",
            "executeCommand",
            "hover",
            "implementation",
            "references",
            "rename",
            "typeDefinition",
          ],
        },
      });
      const persisted = JSON.parse(testStorage.values.get("lithe:lsp-core-sessions:v1") ?? "[]");
      expect(persisted).toEqual([
        expect.objectContaining({
          features: expect.arrayContaining(["definition", "references", "executeCommand"]),
        }),
      ]);
      expect(persisted[0]).not.toHaveProperty("ready");
      expect(emit).toHaveBeenCalledWith(
        "lsp://features-changed",
        expect.objectContaining({ sessionId: "java-session", languageId: "java" }),
      );

      await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    } finally {
      testStorage.restore();
    }
  });

  test("projects structured Java import diagnostics as searchable log fields", async () => {
    scenario = "structured-log";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath: "C:/work/Main.java",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    expect(frontendTrace).toHaveBeenCalledWith(
      "info",
      "lsp.runtime",
      "Java workspace import progress",
      expect.objectContaining({
        stage: "serviceReady",
        currentProject: "module-a",
        downloadedBytes: 1024,
      }),
    );
    expect(emit).toHaveBeenCalledWith("lsp://maven-profile-project", {
      providerId: "java",
      sessionId: "java-session",
      workspacePath: "C:/work",
      projectUri: "file:///C:/work/module-a",
      status: "failed",
      errorDetails: "profile resolution failed",
    });
    expect(emit).toHaveBeenCalledWith("lsp://maven-profile-task", {
      providerId: "java",
      sessionId: "java-session",
      workspacePath: "C:/work",
      status: "partiallySucceeded",
    });
  });

  test("starts and exposes a workspace-owned Java session before a file attaches", async () => {
    scenario = "capabilities";

    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    expect(
      getLspWorkspaceSessionSnapshot({ workspacePath: "C:\\work", languageId: "java" }),
    ).toEqual(expect.objectContaining({ id: "java-session", phase: "ready" }));
    expect(getLspSessionSnapshot({ filePath: "C:/work/Main.java" })).toBeNull();
    expect(ownsLspSession("java-session")).toBe(true);
    expect(ownsLspSession("other-window-session")).toBe(false);

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(
      getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "java" }),
    ).toBeNull();
    expect(ownsLspSession("java-session")).toBe(false);
  });

  test("forwards the Gradle import context to the core start request", async () => {
    scenario = "capabilities";

    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
      javaGradle: { wrapperPresent: true },
    });

    expect(startPayload?.javaGradle).toEqual({ wrapperPresent: true });

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("omits the Gradle import context when the launch carries none", async () => {
    scenario = "capabilities";

    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    expect(startPayload?.javaGradle).toBeNull();

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("sends Maven configuration changes to the running Java session of the workspace", async () => {
    scenario = "capabilities";
    const mavenContext = { version: 1, reactorPath: ".", settingsPath: "C:/maven/settings.xml" };

    const beforeStart = await invokeLsp("lsp_update_maven_configuration", {
      workspacePath: "C:/work",
      mavenContext,
      reloadProjects: true,
    });
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    const running = await invokeLsp("lsp_update_maven_configuration", {
      workspacePath: "C:\\work",
      mavenContext,
      reloadProjects: true,
    });

    // Without a session the next start reads the current context; Core is not asked.
    expect(beforeStart).toEqual({ kind: "noSession" });
    expect(running).toEqual({
      kind: "updated",
      settingsChanged: true,
      projectsReloaded: false,
      profilesUpdating: false,
    });
    expect(requestPayload).toEqual({ sessionId: "java-session", mavenContext, reloadProjects: true });
    expect(commands.filter((command) => command === "lsp.updateMavenConfiguration")).toHaveLength(1);
  });

  test("startup poll failure retires preparation and explicit stop clears the failed snapshot", async () => {
    scenario = "poll-failure";
    await expect(
      invokeLsp("lsp_start", {
        workspacePath: "C:/work",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      }),
    ).rejects.toThrow("Core event transport unavailable");
    expect(getProjectPreparation("C:/work")?.status).toBe("failed");
    expect(
      getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "java" }),
    ).toBeNull();
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(getProjectPreparation("C:/work")).toBeUndefined();
  });

  test("restores preparation from the current snapshot without a preparation event", async () => {
    scenario = "preparation-snapshot";
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    expect(getProjectPreparation("C:/work")).toEqual({
      sessionId: "java-session",
      phase: "configuring",
      status: "loading",
      blocksRun: true,
    });
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(getProjectPreparation("C:/work")).toBeUndefined();
  });

  test("starts the Java Debug Server through the ready workspace session", async () => {
    scenario = "semantic-request";
    semanticRequestResult = { value: "5005" };
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const port = await invokeLsp<number>("java_start_debug_session", {
      workspacePath: "C:\\work",
    });

    expect(port).toBe(5005);
    expect(requestPayload).toEqual({
      sessionId: "java-session",
      operation: "executeCommand",
      command: {
        title: "Start Java Debug Server",
        command: "vscode.java.startDebugSession",
        arguments: [],
      },
    });
  });

  test.each(["src/main/java", "src/test/java", "custom/test-sources"])(
    "delegates Java launch preparation for %s to one Core operation", async (sourceRoot) => {
      scenario = "semantic-request";
      const prepared: JavaRunLaunchPreparation = {
        kind: "ready",
        target: {
          mainClass: "service/example.Main", projectName: "service",
          modulePaths: ["C:/work/modules"],
          classPaths: ["C:/work/custom-output", "C:/repo/dependency.jar"],
        },
      };
      semanticRequestResults = [prepared];
      await invokeLsp("lsp_start", {
        workspacePath: "C:/work", languageId: "java", providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      const sourcePath = "C:/work/service/" + sourceRoot + "/example/Main.java";
      const result = await invokeLsp<JavaRunLaunchPreparation>("java_prepare_run_launch", {
        workspacePath: "C:/work", sourcePath, mainClass: "example.Main",
      });
      expect(result).toEqual(prepared);
      expect(requestPayloads).toEqual([{
        sessionId: "java-session", sourcePath, mainClass: "example.Main",
      }]);
      expect(semanticOperationId).toBe("java.prepareLaunch-operation");
    },
  );

  test("service update validates original paths before building the original target", async () => {
    scenario = "semantic-request";
    const target = {
      mainClass: "example.Main",
      projectName: "service",
      modulePaths: [],
      classPaths: ["C:/work/classes"],
    };
    semanticRequestResults = [{ value: [[], target.classPaths] }, { value: 1 }];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    await invokeLsp("java_build_service_update", {
      workspacePath: "C:/work",
      sourcePath: "C:/work/src/Main.java",
      target,
    });
    expect(
      requestPayloads.slice(-2).map((payload) => (payload.command as { command: string }).command),
    ).toEqual(["vscode.java.resolveClasspath", "vscode.java.buildWorkspace"]);
    expect(requestPayloads[requestPayloads.length - 2]?.command).toMatchObject({
      arguments: ["example.Main", "service"],
    });
    const build = requestPayloads[requestPayloads.length - 1]!.command as { arguments: string[] };
    expect(JSON.parse(build.arguments[0])).toEqual({
      mainClass: "example.Main",
      projectName: "service",
      filePath: "C:/work/src/Main.java",
      isFullBuild: false,
    });
  });

  test("service update refuses changed runtime paths before compiling", async () => {
    scenario = "semantic-request";
    semanticRequestResults = [{ value: [[], ["C:/work/new-classes"]] }];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    await expect(
      invokeLsp("java_build_service_update", {
        workspacePath: "C:/work",
        sourcePath: "C:/work/src/Main.java",
        target: { mainClass: "example.Main", modulePaths: [], classPaths: ["C:/work/classes"] },
      }),
    ).rejects.toThrow("Runtime paths changed");
    expect(
      (requestPayloads[requestPayloads.length - 1]!.command as { command: string }).command,
    ).toBe("vscode.java.resolveClasspath");
  });

  test("reports a malformed entry-point answer instead of an empty list", async () => {
    scenario = "semantic-request";
    semanticRequestResults = [{ entries: "not-a-list" }];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    await expect(invokeLsp("java_entrypoints", { workspacePath: "C:/work" })).rejects.toThrow(
      "invalid entry-point list",
    );
    expect(requestPayloads[requestPayloads.length - 1]).toEqual({
      sessionId: "java-session",
      operation: "javaEntrypoints",
    });
  });

  test("requests typed Java test items for the selected source file", async () => {
    scenario = "semantic-request";
    const expected = {
      schemaVersion: 1,
      items: [{
        id: "method",
        label: "composed()",
        fullName: "demo.OddlyNamedSpec#composed()",
        projectName: "app",
        testKind: 0,
        testLevel: 6,
        children: [],
      }],
      diagnostics: [],
    };
    semanticRequestResults = [expected];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const result = await invokeLsp("java_test_items", {
      workspacePath: "C:/work",
      filePath: "C:/work/src/test/java/demo/OddlyNamedSpec.java",
    });

    expect(result).toEqual(expected);
    expect(requestPayloads[requestPayloads.length - 1]).toEqual({
      sessionId: "java-session",
      operation: "javaTestItems",
      uri: "file:///C:/work/src/test/java/demo/OddlyNamedSpec.java",
    });
  });

  test("requests JDT main methods for the selected source file", async () => {
    scenario = "semantic-request";
    const expected = {
      schemaVersion: 1,
      methods: [{
        mainClass: "demo.App",
        projectName: "app",
        range: { startLine: 3, startUtf16Column: 23, endLine: 3, endUtf16Column: 27 },
      }],
      diagnostics: [],
    };
    semanticRequestResults = [expected];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const result = await invokeLsp("java_main_methods", {
      workspacePath: "C:/work",
      filePath: "C:/work/src/main/java/demo/App.java",
    });

    expect(result).toEqual(expected);
    expect(requestPayloads[requestPayloads.length - 1]).toEqual({
      sessionId: "java-session",
      operation: "javaMainMethods",
      uri: "file:///C:/work/src/main/java/demo/App.java",
    });
  });

  test("reports a malformed main-method answer instead of an empty list", async () => {
    scenario = "semantic-request";
    semanticRequestResults = [{ schemaVersion: 1, methods: "not-a-list" }];
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    await expect(
      invokeLsp("java_main_methods", {
        workspacePath: "C:/work",
        filePath: "C:/work/src/main/java/demo/App.java",
      }),
    ).rejects.toThrow("invalid main-method list");
  });

  test.each(["javaBuildFailed", "javaBuildCompilationErrors"] as const)(
    "preserves the prepared target and %s evidence without rebuilding", async (code) => {
      scenario = "semantic-request";
      const prepared: JavaRunLaunchPreparation = {
        kind: "buildFailed",
        target: { mainClass: "example.Main", projectName: "service", modulePaths: [],
          classPaths: ["C:/work/service/output"] },
        failure: { code, message: "Upstream build failure", report: {
          markerScope: "launchTarget", builderFailedEarlier: true,
          elapsedMilliseconds: 8, recovery: "rebuildJavaIndex",
        } },
      };
      semanticRequestResults = [prepared];
      await invokeLsp("lsp_start", {
        workspacePath: "C:/work", languageId: "java", providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      const result = await invokeLsp<JavaRunLaunchPreparation>("java_prepare_run_launch", {
        workspacePath: "C:/work", sourcePath: "C:/work/service/Main.java", mainClass: "example.Main",
      });
      expect(result).toEqual(prepared);
      expect(requestPayloads).toHaveLength(1);
    },
  );

  test.each(["javaBuildCancelled", "requestTimeout", "requestCancelled"])(
    "propagates %s without converting it to a continuable build verdict", async (code) => {
      scenario = "semantic-request";
      semanticRequestResults = [{ coreError: { code, stage: "javaBuild", message: "Preparation stopped" } }];
      await invokeLsp("lsp_start", {
        workspacePath: "C:/work", languageId: "java", providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      await expect(invokeLsp("java_prepare_run_launch", {
        workspacePath: "C:/work", sourcePath: "C:/work/service/Main.java", mainClass: "example.Main",
      })).rejects.toMatchObject({ code });
      expect(requestPayloads).toHaveLength(1);
    },
  );

  test("rejects an invalid Java Debug Server port", async () => {
    scenario = "semantic-request";
    semanticRequestResult = { value: true };
    await invokeLsp("lsp_start", {
      workspacePath: "C:/work",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    await expect(
      invokeLsp("java_start_debug_session", { workspacePath: "C:/work" }),
    ).rejects.toThrow("invalid debug-server port");
  });

  test("projects readiness changes consumed by the long-lived event pump", async () => {
    scenario = "runtime-ready-transition";
    const testStorage = installSessionStorage();
    const filePath = "C:/work/Main.java";

    try {
      await invokeLsp("lsp_start_for_file", {
        workspacePath: "C:/work",
        filePath,
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      for (
        let attempt = 0;
        attempt < 20 && getLspSessionSnapshot({ filePath })?.phase === "ready";
        attempt += 1
      ) {
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }

      expect(getLspSessionSnapshot({ filePath })?.phase).toBe("initializing");
      const persistedWhileInitializing = JSON.parse(
        testStorage.values.get("lithe:lsp-core-sessions:v1") ?? "[]",
      );
      expect(persistedWhileInitializing[0]).not.toHaveProperty("ready");

      for (let attempt = 0; attempt < 20 && !releaseRuntimeReady; attempt += 1) {
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      expect(releaseRuntimeReady).toBeDefined();
      releaseRuntimeReady?.();
      for (
        let attempt = 0;
        attempt < 20 && getLspSessionSnapshot({ filePath })?.phase !== "ready";
        attempt += 1
      ) {
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      expect(getLspSessionSnapshot({ filePath })?.phase).toBe("ready");
    } finally {
      testStorage.restore();
    }
  });

  test("routes virtual references through the physical source session without rewriting the URI", async () => {
    scenario = "semantic-request";
    const filePath = "C:/work/Main.java";
    const virtualUri = "jdt://contents/java.base/java/lang/String.class?=demo";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const references = await invokeLsp("lsp_get_references", {
      filePath: virtualUri,
      sessionFilePath: filePath,
      documentUri: virtualUri,
      line: 12,
      character: 7,
    });

    expect(references).toEqual([]);
    expect(requestPayload).toEqual({
      sessionId: "java-session",
      operation: "references",
      uri: virtualUri,
      position: { line: 12, utf16Column: 7 },
    });
    expect(requestPayload?.uri).not.toStartWith("file:");

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("resolves an incomplete class completion so import edits can be applied", async () => {
    scenario = "semantic-request";
    const filePath = "C:/work/index.php";
    const completionItem = {
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      data: { fqn: "Carbon\\Carbon" },
    };
    semanticRequestResult = {
      item: {
        ...completionItem,
        detail: "class Carbon\\Carbon",
        additionalTextEdits: [
          {
            range: {
              start: { line: 1, utf16Column: 0 },
              end: { line: 1, utf16Column: 0 },
            },
            newText: "use Carbon\\Carbon;\n",
          },
        ],
      },
    };
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "php",
      providerId: "php",
      serverPath: "C:/Lithe/intelephense.cmd",
    });

    const resolved = await invokeLsp("lsp_resolve_completion", {
      filePath,
      completionItem,
    });

    expect(resolved).toEqual({
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      data: { fqn: "Carbon\\Carbon" },
      detail: "class Carbon\\Carbon",
      additionalTextEdits: [
        {
          range: {
            start: { line: 1, character: 0 },
            end: { line: 1, character: 0 },
          },
          newText: "use Carbon\\Carbon;\n",
        },
      ],
    });
    expect(requestPayload).toEqual({
      sessionId: "java-session",
      operation: "resolveCompletion",
      uri: "file:///C:/work/index.php",
      completionItem,
    });

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("normalizes Core Java navigation locations to standard LSP positions", async () => {
    scenario = "semantic-request";
    const filePath = "C:/work/Main.java";
    semanticRequestResult = {
      locations: [
        {
          uri: "file:///C:/work/Service.java",
          filePath: "C:/work/Service.java",
          range: {
            start: { line: 9, utf16Column: 16 },
            end: { line: 9, utf16Column: 23 },
          },
        },
      ],
    };
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const result = await invokeLsp("java_resolve_navigation", {
      filePath,
      line: 3,
      character: 9,
      direction: "down",
      relation: "interface",
    });

    expect(result).toEqual({
      locations: [
        {
          uri: "file:///C:/work/Service.java",
          filePath: "C:/work/Service.java",
          range: {
            start: { line: 9, character: 16 },
            end: { line: 9, character: 23 },
          },
        },
      ],
    });
    expect(requestPayload).toEqual({
      sessionId: "java-session",
      uri: "file:///C:/work/Main.java",
      line: 3,
      utf16Column: 9,
      direction: "down",
      relation: "interface",
      documentVersion: undefined,
    });

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("moves one normalized file to the new workspace session and stops the empty owner", async () => {
    scenario = "multi-session";
    const filePath = "C:/work/project/src/Main.java";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    expect(getLspSessionSnapshot({ filePath })?.id).toBe("java-session-1");

    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:\\work\\project",
      filePath: "C:\\work\\project\\src\\Main.java",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    expect(getLspSessionSnapshot({ filePath })).toEqual(
      expect.objectContaining({
        id: "java-session-2",
        workspacePath: "C:\\work\\project",
      }),
    );
    expect(commands.filter((command) => command === "lsp.startServer")).toHaveLength(2);
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(1);
    expect(commands.filter((command) => command === "lsp.destroyServer")).toHaveLength(1);

    const parentFilePath = "C:/work/src/Other.java";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath: parentFilePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });
    expect(getLspSessionSnapshot({ filePath: parentFilePath })).toEqual(
      expect.objectContaining({
        id: "java-session-3",
        workspacePath: "C:/work",
      }),
    );
    expect(commands.filter((command) => command === "lsp.startServer")).toHaveLength(3);

    await invokeLsp("lsp_stop_for_file", { filePath });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(1);
    await invokeLsp("lsp_stop", { workspacePath: "C:/work/project" });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(2);
    await invokeLsp("lsp_stop_for_file", { filePath: parentFilePath });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(2);
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(3);
  });

  test("preserves completion-list refresh metadata and trigger context", async () => {
    scenario = "semantic-request";
    const fixture = JSON.parse(readFileSync(new URL("../../../../shared/fixtures/lsp/completion-refresh-v1.json", import.meta.url), "utf8"));
    const filePath = "C:/work/Main.java";
    await invokeLsp("lsp_start_for_file", { workspacePath: "C:/work", filePath, languageId: "java", serverPath: "java-lsp" });
    for (const entry of fixture.cases) {
      const expected: CompletionList = { items: [], isIncomplete: entry.isIncomplete };
      semanticRequestResult = expected;
      expect(await invokeLsp<CompletionList>("lsp_get_completions", {
        filePath, line: 0, character: 1, completionContext: entry.context,
      })).toEqual(expected);
      expect(requestPayload).toEqual(expect.objectContaining({ completionContext: entry.context }));
    }
  });

  test("routes semantic tokens through Core and preserves its negotiated legend and null results", async () => {
    scenario = "semantic-request";
    const fixture = JSON.parse(readFileSync(new URL("../../../../shared/fixtures/lsp/semantic-tokens-v1.json", import.meta.url), "utf8"));
    semanticRequestResult = fixture.expectedResult;
    const filePath = "C:/work/Main.java";
    await invokeLsp("lsp_start_for_file", { workspacePath: "C:/work", filePath, languageId: "java", serverPath: "java-lsp" });
    expect(await invokeLsp("lsp_get_semantic_tokens", { filePath })).toEqual(fixture.expectedResult);
    expect(requestPayload).toEqual({ sessionId: "java-session", operation: "semanticTokens", uri: "file:///C:/work/Main.java" });
    semanticRequestResult = null;
    expect(await invokeLsp("lsp_get_semantic_tokens", { filePath })).toBeNull();
    semanticRequestResult = { coreError: { code: "cancelled", message: "Document changed" } };
    await expect(invokeLsp("lsp_get_semantic_tokens", { filePath })).rejects.toMatchObject({ code: "cancelled" });
  });

  test("forwards Core semantic token refresh notifications", async () => {
    scenario = "semantic-request";
    semanticRefreshOnReady = true;
    await invokeLsp("lsp_start_for_file", { workspacePath: "C:/work", filePath: "C:/work/Main.java", languageId: "java", serverPath: "java-lsp" });
    expect(emit).toHaveBeenCalledWith("lsp://semantic-tokens-refresh", { sessionId: "java-session", workspacePath: "C:/work" });
  });

  test("forwards one Core drain of diagnostics as one batch with the newest set per document", async () => {
    scenario = "semantic-request";
    const published = (uri: string, version: number, message: string) => ({
      type: "diagnostics",
      sessionId: "java-session",
      uri,
      version,
      diagnostics: [{ range: { start: { line: 0, utf16Column: 2 } }, message }],
    });
    eventsAroundReady = {
      before: [published("file:///C:/work/Early.java", 1, "early")],
      after: [
        published("file:///C:/work/Main.java", 1, "first"),
        published("file:///C:/work/Other.java", 1, "other"),
        published("file:///C:/work/Main.java", 2, "second"),
      ],
    };
    await invokeLsp("lsp_start_for_file", { workspacePath: "C:/work", filePath: "C:/work/Main.java", languageId: "java", serverPath: "java-lsp" });

    const forwarded = (emit.mock.calls as unknown as [string, unknown][]).filter(([event]) =>
      event === "lsp://diagnostics" || event === "lsp://language-lifecycle");
    // Diagnostics that arrived before the session became ready stay ahead of
    // that lifecycle event; the rest of the drain follows as a single batch.
    expect(forwarded.map(([event]) => event)).toEqual([
      "lsp://diagnostics",
      "lsp://language-lifecycle",
      "lsp://diagnostics",
    ]);
    expect(forwarded[0][1]).toEqual({
      publications: [{ uri: "file:///C:/work/Early.java", version: 1, diagnostics: [{ range: { start: { line: 0, character: 2 } }, message: "early" }] }],
    });
    expect(forwarded[2][1]).toEqual({
      publications: [
        { uri: "file:///C:/work/Main.java", version: 2, diagnostics: [{ range: { start: { line: 0, character: 2 } }, message: "second" }] },
        { uri: "file:///C:/work/Other.java", version: 1, diagnostics: [{ range: { start: { line: 0, character: 2 } }, message: "other" }] },
      ],
    });
  });

  test("discards semantic colors from a replaced file attachment", async () => {
    scenario = "semantic-request";
    semanticRequestResult = { tokenTypes: ["class"], tokenModifiers: [], tokens: [] };
    const filePath = "C:/work/Main.java";
    const start = { workspacePath: "C:/work", filePath, languageId: "java", serverPath: "java-lsp" };
    await invokeLsp("lsp_start_for_file", { ...start, attachmentId: "old" });
    semanticResultGate = new Promise<void>((resolve) => { releaseSemanticResult = resolve; });
    const requested = new Promise<void>((resolve) => { onSemanticRequest = resolve; });
    const result = invokeLsp("lsp_get_semantic_tokens", { filePath });
    try {
      await requested;
      await invokeLsp("lsp_start_for_file", { ...start, attachmentId: "replacement" });
      releaseSemanticResult!();
      expect(await result).toBeNull();
    } finally {
      releaseSemanticResult!();
      await result.catch(() => undefined);
    }
  });

  test("discards completions from a replaced file attachment", async () => {
    scenario = "semantic-request";
    semanticRequestResult = { items: [{ label: "old" }], isIncomplete: true };
    const filePath = "C:/work/Main.java";
    const start = { workspacePath: "C:/work", filePath, languageId: "java", serverPath: "java-lsp" };
    await invokeLsp("lsp_start_for_file", { ...start, attachmentId: "old" });
    semanticResultGate = new Promise<void>((resolve) => { releaseSemanticResult = resolve; });
    const requested = new Promise<void>((resolve) => { onSemanticRequest = resolve; });
    const result = invokeLsp("lsp_get_completions", { filePath });
    try {
      await requested;
      await invokeLsp("lsp_start_for_file", { ...start, attachmentId: "replacement" });
      releaseSemanticResult!();
      expect(await result).toEqual({ items: [], isIncomplete: false });
    } finally {
      releaseSemanticResult!();
      await result.catch(() => undefined);
    }
  });

  test("returns a structured capability error for explicitly unavailable commands", async () => {
    await expect(
      invokeLsp("lsp_prepare_rename", {
        filePath: "C:/work/Main.java",
        line: 0,
        character: 0,
      }),
    ).rejects.toMatchObject({
      code: "unsupported_capability",
      message: "LSP operation is not available through the shared Core: lsp_prepare_rename",
    });
  });

  test("maps or explicitly rejects every LspClient adapter command", () => {
    expect(LSP_OPERATION_BY_COMMAND).toEqual({
      lsp_get_completions: "completion",
      lsp_resolve_completion: "resolveCompletion",
      lsp_get_hover: "hover",
      lsp_get_definition: "definition",
      lsp_get_implementation: "implementation",
      lsp_get_type_definition: "typeDefinition",
      lsp_get_references: "references",
      lsp_rename: "rename",
      lsp_format_document: "formatting",
      lsp_get_code_actions: "codeActions",
      lsp_get_inlay_hints: "inlayHints",
      lsp_get_semantic_tokens: "semanticTokens",
      lsp_get_code_lens: "codeLens",
      lsp_get_virtual_document: "virtualDocument",
    });

    const explicitlyHandled = new Set([
      ...Object.keys(LSP_OPERATION_BY_COMMAND),
      ...LSP_EXPLICITLY_UNAVAILABLE_COMMANDS,
      "lsp_apply_code_action",
      "lsp_document_change",
      "lsp_document_close",
      "lsp_document_open",
      "lsp_document_save",
      "lsp_start",
      "lsp_start_for_file",
      "lsp_stop",
      "lsp_stop_for_file",
      "lsp_workspace_files_changed",
      "lsp_retry_maven_profiles",
      "lsp_update_maven_configuration",
    ]);
    const clientSource = readFileSync(
      new URL("../features/editor/lsp/lsp-client.ts", import.meta.url),
      "utf8",
    );
    const clientCommands = new Set(
      [...clientSource.matchAll(/["'](lsp_[a-z_]+)["']/g)].map((match) => match[1]),
    );

    expect([...clientCommands].filter((command) => !explicitlyHandled.has(command))).toEqual([]);
  });

  test("resolves a provider virtual document without fabricating a file URI", async () => {
    scenario = "virtual-document";
    const filePath = "C:/work/Main.java";
    const virtualUri = "jdt://contents/java.base/java/lang/String.class?=demo";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
    });

    const text = await invokeLsp<string | null>("lsp_get_virtual_document", {
      filePath,
      virtualUri,
    });

    expect(text).toBe("public final class String {}");
    expect(requestPayload).toEqual({
      sessionId: "java-session",
      operation: "virtualDocument",
      virtualUri,
    });
    expect(requestPayload).not.toHaveProperty("uri");

    await invokeLsp("lsp_stop_for_file", { filePath });
    expect(commands).not.toContain("lsp.stopServer");
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(commands).toContain("lsp.stopServer");
    expect(commands).toContain("lsp.destroyServer");
  });

  test("reports a disk save without turning it into an editor change", async () => {
    scenario = "capabilities";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work", filePath: "C:/work/Main.java", languageId: "java",
      providerId: "java", serverPath: "C:/Lithe/jdtls.bat",
    });
    const fixture = JSON.parse(readFileSync(new URL("../../../../shared/fixtures/lsp/document-save-v1.json", import.meta.url), "utf8"));
    const example = fixture.cases.find((item: { id: string }) => item.id === "save-without-text");
    await invokeLsp("lsp_document_save", { filePath: "C:/work/Main.java", content: example.savedText });
    expect(commands).toContain("lsp.saveDocument");
    expect(commands).not.toContain("lsp.syncDocument");
    expect(requestPayload).toEqual({ sessionId: "java-session", uri: "file:///C:/work/Main.java", text: example.savedText });
  });

  test("shares an in-flight server start across files and normalizes Windows paths", async () => {
    scenario = "virtual-document";

    await Promise.all([
      invokeLsp("lsp_start_for_file", {
        workspacePath: "C:\\work",
        filePath: "C:\\work\\Main.java",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      }),
      invokeLsp("lsp_start_for_file", {
        workspacePath: "C:/work",
        filePath: "C:/work/Other.java",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      }),
    ]);

    expect(commands.filter((command) => command === "lsp.startServer")).toHaveLength(1);

    await invokeLsp("lsp_stop_for_file", { filePath: "C:/work/Main.java" });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(0);

    await invokeLsp("lsp_stop_for_file", { filePath: "C:\\work\\Other.java" });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(0);
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(1);
    expect(commands.filter((command) => command === "lsp.destroyServer")).toHaveLength(1);
  });

  test("ignores a stale file stop after the same path is attached again", async () => {
    scenario = "capabilities";
    const filePath = "C:/work/Main.java";

    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath,
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
      attachmentId: "attachment-old",
    });
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work",
      filePath: "C:\\work\\Main.java",
      languageId: "java",
      providerId: "java",
      serverPath: "C:/Lithe/jdtls.bat",
      attachmentId: "attachment-new",
    });

    await invokeLsp("lsp_stop_for_file", {
      filePath,
      attachmentId: "attachment-old",
    });

    expect(getLspSessionSnapshot({ filePath })).toEqual(
      expect.objectContaining({ id: "java-session", phase: "ready" }),
    );
    expect(commands.filter((command) => command === "lsp.startServer")).toHaveLength(1);
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(0);

    await invokeLsp("lsp_stop_for_file", {
      filePath,
      attachmentId: "attachment-new",
    });
    expect(getLspSessionSnapshot({ filePath })).toBeNull();
    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
  });

  test("keeps initializing sessions recoverable and makes an in-flight file stop deterministic", async () => {
    scenario = "delayed-start";
    const previousStorage = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
    const values = new Map<string, string>();
    const storage: Storage = {
      get length() {
        return values.size;
      },
      clear: () => values.clear(),
      getItem: (key) => values.get(key) ?? null,
      key: (index) => [...values.keys()][index] ?? null,
      removeItem: (key) => values.delete(key),
      setItem: (key, value) => values.set(key, value),
    };
    Object.defineProperty(globalThis, "sessionStorage", { configurable: true, value: storage });

    try {
      const firstStart = invokeLsp("lsp_start_for_file", {
        workspacePath: "C:\\work",
        filePath: "C:\\work\\Main.java",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      for (let attempt = 0; attempt < 10 && !releaseInitialization; attempt += 1) {
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }

      expect(releaseInitialization).toBeDefined();
      const persistedWhileStarting = JSON.parse(values.get("lithe:lsp-core-sessions:v1") ?? "[]");
      expect(persistedWhileStarting).toEqual([expect.objectContaining({ id: "java-session" })]);
      expect(persistedWhileStarting[0]).not.toHaveProperty("ready");

      const secondStart = invokeLsp("lsp_start_for_file", {
        workspacePath: "C:/work",
        filePath: "C:/work/Other.java",
        languageId: "java",
        providerId: "java",
        serverPath: "C:/Lithe/jdtls.bat",
      });
      const stopSecond = invokeLsp("lsp_stop_for_file", { filePath: "C:\\work\\Other.java" });

      releaseInitialization?.();
      await Promise.all([firstStart, secondStart, stopSecond]);

      expect(commands.filter((command) => command === "lsp.startServer")).toHaveLength(1);
      expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(0);
      const persistedReady = JSON.parse(values.get("lithe:lsp-core-sessions:v1") ?? "[]");
      expect(persistedReady).toEqual([expect.objectContaining({ files: ["C:\\work\\Main.java"] })]);
      expect(persistedReady[0]).not.toHaveProperty("ready");

      await invokeLsp("lsp_stop_for_file", { filePath: "C:/work/Main.java" });
      expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(0);
      expect(
        getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "java" }),
      ).toEqual(expect.objectContaining({ id: "java-session", phase: "ready" }));
      expect(JSON.parse(values.get("lithe:lsp-core-sessions:v1") ?? "[]")).toEqual([
        expect.objectContaining({ files: [] }),
      ]);
      await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
      expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(1);
      expect(values.has("lithe:lsp-core-sessions:v1")).toBe(false);
    } finally {
      if (previousStorage) {
        Object.defineProperty(globalThis, "sessionStorage", previousStorage);
      } else {
        delete (globalThis as { sessionStorage?: Storage }).sessionStorage;
      }
    }
  });
  test("declarative launch forwards Core plugin identity and configuration", async () => {
    scenario = "capabilities";
    await invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work", filePath: "C:/work/Main.go", languageId: "go",
      providerId: "acme.lang", pluginId: "acme.lang", serverPath: "fixture.exe",
      workspaceConfiguration: { gopls: { enabled: true } },
    });
    expect(startPayload?.pluginId).toBe("acme.lang");
    expect(startPayload?.workspaceConfiguration).toEqual({ gopls: { enabled: true } });
  }, 5000);

  test("provider stop drains and destroys an in-flight Core start", async () => {
    const entered = new Promise<void>((resolve) => { pluginStartEntered = resolve; });
    pluginStartGate = new Promise<void>((resolve) => { releasePluginStart = resolve; });
    scenario = "held-plugin-start";
    const starting = invokeLsp("lsp_start_for_file", {
      workspacePath: "C:/work", filePath: "C:/work/Main.go", languageId: "go",
      providerId: "acme.lang", pluginId: "acme.lang", serverPath: "fixture.exe",
    });
    const outcome = starting.then(() => "started", () => "cancelled");
    let stopping: Promise<unknown> | undefined;
    try {
      await entered;
      stopping = invokeLsp("lsp_stop_for_provider", { providerId: "acme.lang" });
      scenario = "capabilities";
      releasePluginStart?.();
      await stopping;
      expect(await outcome).toBe("cancelled");
      expect(commands).toContain("lsp.stopServer");
      expect(commands).toContain("lsp.destroyServer");
      expect(getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "go" })).toBeNull();
    } finally {
      releasePluginStart?.();
      await Promise.allSettled([outcome, stopping]);
      pluginStartEntered = undefined;
      pluginStartGate = undefined;
      releasePluginStart = undefined;
    }
  }, 5000);

  const buildTarget = { workspacePath: "C:/work", pluginId: "dev.example.build", buildSystemId: "example" };
  const buildLaunch = { serverPath: "C:/tools/provider.exe", serverArgs: ["--stdio"], environment: {} };

  test("Build progress and raw results can precede submission acknowledgement without a source file", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    providerAckGate = new Promise<void>(resolve => { releaseProviderAck = resolve; });
    providerProgress = [{ output: "compiling\n" }, { output: "done\n" }];
    const value = { utf16Column: 7, projects: [] };
    semanticRequestResult = { value };
    const progress: unknown[] = [];
    try {
      expect(await requestCoreBuildProvider<typeof value>(buildTarget, {
        method: "lithe/build/model", params: {}, timeoutMilliseconds: 1000,
        onProgress: value => { progress.push(value); },
      })).toEqual(value);
      expect(progress).toEqual([{ output: "compiling\n" }, { output: "done\n" }]);
      expect(startPayload?.providerId).toBe(buildTarget.pluginId);
      expect(startPayload?.pluginId).toBe(buildTarget.pluginId);
      expect(commands).not.toContain("lsp.openDocument");
      expect(requestPayload?.timeoutMilliseconds).toBe(1000);
    } finally { releaseProviderAck?.(); }
  }, 5000);

  test("cancelling a Build request before acknowledgement cancels that late submission only", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    providerAckGate = new Promise<void>(resolve => { releaseProviderAck = resolve; });
    semanticResultGate = new Promise<void>(resolve => { releaseSemanticResult = resolve; });
    const controller = new AbortController();
    onSemanticRequest = () => controller.abort();
    const cancellationSent = new Promise<void>(resolve => { onCoreCancel = resolve; });
    try {
      await expect(requestCoreBuildProvider(buildTarget, {
        method: "lithe/build/execute", params: {}, timeoutMilliseconds: 1000, signal: controller.signal,
      })).rejects.toMatchObject({ code: "cancelled" });
      expect(commands).not.toContain("lsp.stopServer");
      releaseProviderAck?.();
      await cancellationSent;
      expect(commands).toContain("lsp.cancelOperation");
      releaseSemanticResult?.();
      expect(getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "buildProvider:dev.example.build:example" })?.phase).toBe("ready");
    } finally { releaseProviderAck?.(); releaseSemanticResult?.(); }
  }, 5000);

  test("a failing Build progress consumer cancels its request and keeps the shared backend", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    providerProgress = [{ output: "compile" }];
    semanticRequestResult = { value: {} };
    await expect(requestCoreBuildProvider(buildTarget, {
      method: "lithe/build/execute", params: {}, timeoutMilliseconds: 1000,
      onProgress: () => { throw new Error("view was revoked"); },
    })).rejects.toThrow("view was revoked");
    expect(commands).toContain("lsp.cancelOperation");
    expect(commands).not.toContain("lsp.stopServer");
  }, 5000);

  test("stopping one Build target preserves another system from the same plugin", async () => {
    scenario = "multi-session";
    const other = { ...buildTarget, buildSystemId: "another" };
    await startCoreBuildProvider(buildTarget, buildLaunch);
    await startCoreBuildProvider(other, buildLaunch);
    await stopCoreBuildProvider(buildTarget);
    expect(getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "buildProvider:dev.example.build:example" })).toBeNull();
    expect(getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "buildProvider:dev.example.build:another" })?.phase).toBe("ready");
    expect(commands.filter(command => command === "lsp.stopServer")).toHaveLength(1);
  }, 5000);

  test("Build operations reject pre-cancellation and invalid deadlines before Core submission", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    const controller = new AbortController(); controller.abort();
    await expect(requestCoreBuildProvider(buildTarget, {
      method: "lithe/build/model", params: {}, timeoutMilliseconds: 1000, signal: controller.signal,
    })).rejects.toBeDefined();
    await expect(requestCoreBuildProvider(buildTarget, {
      method: "lithe/build/model", params: {}, timeoutMilliseconds: 0,
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(commands).not.toContain("lsp.buildRequest");
  }, 5000);

  test("Build backend failures preserve their structured code and never invoke a legacy command", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    semanticRequestResult = { coreError: { code: "maven.invalidRun", message: "Target was removed" } };
    await expect(requestCoreBuildProvider(buildTarget, {
      method: "lithe/build/prepareRun", params: {}, timeoutMilliseconds: 1000,
    })).rejects.toMatchObject({ code: "maven.invalidRun", message: "Target was removed" });
    expect(commands.some(command => command.startsWith("maven."))).toBe(false);
  }, 5000);

  test("a malformed Build response envelope fails before a domain decoder receives it", async () => {
    scenario = "semantic-request";
    await startCoreBuildProvider(buildTarget, buildLaunch);
    semanticRequestResult = { projects: [] };
    await expect(requestCoreBuildProvider(buildTarget, {
      method: "lithe/build/model", params: {}, timeoutMilliseconds: 1000,
    })).rejects.toMatchObject({ code: "invalid_response" });
  }, 5000);

  test("workspace close drains a Build backend whose native start reply arrives late", async () => {
    scenario = "held-plugin-start";
    let entered!: () => void;
    const startingEntered = new Promise<void>(resolve => { entered = resolve; });
    pluginStartEntered = entered;
    pluginStartGate = new Promise<void>(resolve => { releasePluginStart = resolve; });
    const starting = startCoreBuildProvider(buildTarget, buildLaunch).then(() => "started", () => "cancelled");
    let stopping: Promise<unknown> | undefined;
    try {
      await startingEntered;
      stopping = invokeLsp("lsp_stop", { workspacePath: "c:/WORK" });
      scenario = "capabilities"; releasePluginStart?.();
      await stopping;
      expect(await starting).toBe("cancelled");
      expect(commands).toContain("lsp.stopServer");
      expect(commands).toContain("lsp.destroyServer");
      expect(getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "buildProvider:dev.example.build:example" })).toBeNull();
    } finally {
      releasePluginStart?.();
      await Promise.allSettled([starting, stopping]);
      pluginStartEntered = undefined; pluginStartGate = undefined; releasePluginStart = undefined;
    }
  }, 5000);

});
