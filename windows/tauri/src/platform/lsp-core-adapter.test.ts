import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { readFileSync } from "node:fs";

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
const commands: string[] = [];
let scenario:
  | "capabilities"
  | "delayed-start"
  | "failure"
  | "multi-session"
  | "runtime-ready-transition"
  | "semantic-request"
  | "virtual-document" = "failure";
let startPayload: Record<string, unknown> | undefined;
let requestPayload: Record<string, unknown> | undefined;
let pollCount = 0;
let startCount = 0;
const sessionPollCounts = new Map<string, number>();
let virtualDocumentPending = false;
let semanticRequestPending = false;
let semanticOperationId = "";
let semanticRequestResult: unknown = { locations: [] };
let releaseInitialization: (() => void) | undefined;
let releaseRuntimeReady: (() => void) | undefined;

function readyEvents(sessionId: string) {
  return [
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
      if (scenario === "capabilities" || scenario === "multi-session") {
        return {
          id: request.id,
          ok: true as const,
          data: { events: sessionPollCount === 1 ? readyEvents(sessionId) : [] },
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
            data: { events: readyEvents(sessionId) },
          };
        }
        if (semanticRequestPending) {
          semanticRequestPending = false;
          return {
            id: request.id,
            ok: true as const,
            data: {
              events: [
                {
                  type: "requestCompleted",
                  providerId: "java",
                  sessionId,
                  operationId: semanticOperationId,
                  result: semanticRequestResult,
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
    if (request.command === "lsp.request" || request.command === "java.resolveNavigation") {
      requestPayload = request.payload;
      const operation = String(request.payload?.operation ?? request.command);
      const operationId = `${operation}-operation`;
      if (scenario === "semantic-request") {
        semanticRequestPending = true;
        semanticOperationId = operationId;
      } else {
        virtualDocumentPending = true;
      }
      return {
        id: request.id,
        ok: true as const,
        data: { operationId },
      };
    }
    return { id: request.id, ok: true as const, data: null };
  },
);

mock.module("@tauri-apps/api/event", () => ({ emit, emitTo, listen, once, TauriEvent }));
mock.module("@/core/lithe-core-client", () => ({ executeCore }));
mock.module("@/utils/frontend-trace", () => ({ frontendTrace }));

const {
  getLspSessionSnapshot,
  getLspWorkspaceSessionSnapshot,
  invokeLsp,
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
    pollCount = 0;
    startCount = 0;
    sessionPollCounts.clear();
    virtualDocumentPending = false;
    semanticRequestPending = false;
    semanticOperationId = "";
    semanticRequestResult = { locations: [] };
    releaseInitialization = undefined;
    releaseRuntimeReady = undefined;
    emit.mockClear();
    frontendTrace.mockClear();
    executeCore.mockClear();
  });

  afterEach(async () => {
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
    expect(startPayload?.runtimeExecutablePath).toBe("C:/Lithe/jdk/bin/java.exe");
    expect(startPayload?.jdtlsLaunchResources).toEqual({
      launcherJarPath: "C:/Lithe/jdtls/plugins/equinox.jar",
      configurationDirectory: "C:/Lithe/jdtls/config_win",
      lombokAgentPath: "C:/Lithe/jdtls/lombok/lombok.jar",
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
      const persisted = JSON.parse(
        testStorage.values.get("lithe:lsp-core-sessions:v1") ?? "[]",
      );
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

    await invokeLsp("lsp_stop", { workspacePath: "C:/work" });
    expect(
      getLspWorkspaceSessionSnapshot({ workspacePath: "C:/work", languageId: "java" }),
    ).toBeNull();
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
      lsp_get_hover: "hover",
      lsp_get_definition: "definition",
      lsp_get_implementation: "implementation",
      lsp_get_type_definition: "typeDefinition",
      lsp_get_references: "references",
      lsp_rename: "rename",
      lsp_format_document: "formatting",
      lsp_get_code_actions: "codeActions",
      lsp_get_inlay_hints: "inlayHints",
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
      const persistedWhileStarting = JSON.parse(
        values.get("lithe:lsp-core-sessions:v1") ?? "[]",
      );
      expect(persistedWhileStarting).toEqual([
        expect.objectContaining({ id: "java-session" }),
      ]);
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
      expect(persistedReady).toEqual([
        expect.objectContaining({ files: ["C:\\work\\Main.java"] }),
      ]);
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
});
