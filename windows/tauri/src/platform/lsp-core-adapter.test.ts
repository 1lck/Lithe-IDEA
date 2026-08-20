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
let scenario: "failure" | "virtual-document" = "failure";
let startPayload: Record<string, unknown> | undefined;
let requestPayload: Record<string, unknown> | undefined;
let pollCount = 0;
let virtualDocumentPending = false;

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
});
