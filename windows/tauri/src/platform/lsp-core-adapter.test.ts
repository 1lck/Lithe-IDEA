import { beforeEach, describe, expect, mock, test } from "bun:test";

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
let scenario: "delayed-start" | "failure" | "virtual-document" = "failure";
let startPayload: Record<string, unknown> | undefined;
let requestPayload: Record<string, unknown> | undefined;
let pollCount = 0;
let virtualDocumentPending = false;
let releaseInitialization: (() => void) | undefined;

const executeCore = mock(
  async (request: { id: string; command: string; payload?: Record<string, unknown> }) => {
    commands.push(request.command);
    if (request.command === "lsp.startServer") {
      startPayload = request.payload;
      return {
        id: request.id,
        ok: true as const,
        data: {
          sessionId: scenario === "failure" ? "failed-java-session" : "java-session",
        },
      };
    }
    if (request.command === "lsp.pollEvents") {
      pollCount += 1;
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
                  sessionId: "java-session",
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
                  sessionId: "java-session",
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
                  sessionId: "java-session",
                  operationId: "virtual-document-operation",
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
    if (request.command === "lsp.request") {
      requestPayload = request.payload;
      virtualDocumentPending = true;
      return {
        id: request.id,
        ok: true as const,
        data: { operationId: "virtual-document-operation" },
      };
    }
    return { id: request.id, ok: true as const, data: null };
  },
);

mock.module("@tauri-apps/api/event", () => ({ emit, emitTo, listen, once, TauriEvent }));
mock.module("@/core/lithe-core-client", () => ({ executeCore }));
mock.module("@/utils/frontend-trace", () => ({ frontendTrace }));

const { invokeLsp } = await import("./lsp-core-adapter");

describe("Rust Core LSP adapter failures", () => {
  beforeEach(() => {
    scenario = "failure";
    commands.length = 0;
    startPayload = undefined;
    requestPayload = undefined;
    pollCount = 0;
    virtualDocumentPending = false;
    releaseInitialization = undefined;
    emit.mockClear();
    frontendTrace.mockClear();
    executeCore.mockClear();
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
    expect(frontendTrace).toHaveBeenCalledWith(
      "warn",
      "lsp.runtime",
      "Language-server stderr",
      expect.objectContaining({ detail: "JDTLS failed before initialization" }),
    );
    expect(emit).toHaveBeenCalledWith("lsp://server-crashed", {});
    expect(commands).toEqual([
      "lsp.startServer",
      "lsp.pollEvents",
      "lsp.stopServer",
      "lsp.destroyServer",
    ]);
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
    expect(commands.filter((command) => command === "lsp.stopServer")).toHaveLength(1);
    expect(commands.filter((command) => command === "lsp.destroyServer")).toHaveLength(1);
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
        await Promise.resolve();
      }

      expect(releaseInitialization).toBeDefined();
      expect(JSON.parse(values.get("lithe:lsp-core-sessions:v1") ?? "[]")).toEqual([
        expect.objectContaining({ id: "java-session", ready: false }),
      ]);

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
      expect(JSON.parse(values.get("lithe:lsp-core-sessions:v1") ?? "[]")).toEqual([
        expect.objectContaining({ files: ["C:\\work\\Main.java"], ready: true }),
      ]);

      await invokeLsp("lsp_stop_for_file", { filePath: "C:/work/Main.java" });
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
