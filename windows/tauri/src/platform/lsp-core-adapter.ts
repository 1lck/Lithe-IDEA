import { emit } from "@tauri-apps/api/event";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { frontendTrace } from "@/utils/frontend-trace";

type JsonRecord = Record<string, any>;

const INITIALIZE_TIMEOUT_MS = 30_000;
const SESSION_CLEANUP_TIMEOUT_MS = 5_000;
const POLL_INTERVAL_MS = 20;

interface Session {
  id: string;
  workspacePath: string;
  languageId: string;
  files: Set<string>;
  running: boolean;
  pending: Map<string, { resolve: (value: unknown) => void; reject: (reason: Error) => void }>;
  completed: Map<string, RuntimeEvent>;
}

interface RuntimeError {
  code?: string;
  providerId?: string;
  sessionId?: string;
  stage?: string;
  method?: string;
  documentUri?: string;
  message?: string;
  underlyingMessage?: string;
  processExitCode?: number;
}

interface RuntimeEvent {
  type: string;
  providerId?: string;
  sessionId?: string;
  state?: string;
  operationId?: string;
  uri?: string;
  version?: number;
  diagnostics?: unknown[];
  result?: unknown;
  error?: RuntimeError;
  level?: string;
  message?: string;
  detail?: string;
}

const sessions = new Map<string, Session>();
const fileSessions = new Map<string, Session>();

function coreData<T>(response: CoreResponse<T>): T {
  if (response.ok) return response.data;
  const error = new Error(response.error.message) as Error & { code?: string };
  error.code = response.error.code;
  throw error;
}

async function core<T>(command: string, payload: JsonRecord): Promise<T> {
  return coreData(
    await executeCore<T>({
      id: crypto.randomUUID(),
      command,
      payload,
    }),
  );
}

function fileUri(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  const prefixed = /^[A-Za-z]:\//.test(normalized) ? `/${normalized}` : normalized;
  return encodeURI(`file://${prefixed.startsWith("/") ? "" : "/"}${prefixed}`);
}

function normalizeCoreValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalizeCoreValue);
  if (!value || typeof value !== "object") return value;
  const source = value as JsonRecord;
  const normalized: JsonRecord = {};
  for (const [key, child] of Object.entries(source)) {
    normalized[key === "utf16Column" ? "character" : key] = normalizeCoreValue(child);
  }
  return normalized;
}

async function dispatchRuntimeEvent(event: RuntimeEvent): Promise<void> {
  if (event.type === "log") {
    const level = event.level === "error" ? "error" : event.level === "warning" ? "warn" : "info";
    frontendTrace(level, "lsp.runtime", event.message ?? "Language-server log", {
      detail: event.detail ?? null,
      providerId: event.providerId,
      sessionId: event.sessionId,
    });
  }
  if (event.type === "diagnostics" && event.uri) {
    await emit("lsp://diagnostics", {
      uri: event.uri,
      version: event.version,
      diagnostics: normalizeCoreValue(event.diagnostics ?? []),
    });
  }
  if (event.type === "stateChanged" && event.state === "failed") {
    await emit("lsp://server-crashed", {});
  }
}

async function dispatchSessionEvent(session: Session, event: RuntimeEvent): Promise<void> {
  await dispatchRuntimeEvent(event);
  if (event.type !== "requestCompleted" || !event.operationId) return;
  const pending = session.pending.get(event.operationId);
  if (!pending) {
    session.completed.set(event.operationId, event);
    return;
  }
  session.pending.delete(event.operationId);
  if (event.error) {
    const error = new Error(event.error.message ?? "LSP request failed") as Error & {
      code?: string;
    };
    error.code = event.error.code;
    pending.reject(error);
  } else {
    pending.resolve(event.result);
  }
}

async function poll(session: Session): Promise<RuntimeEvent[]> {
  const response = await core<{ events: RuntimeEvent[] }>("lsp.pollEvents", {
    sessionId: session.id,
  });
  for (const event of response.events) await dispatchSessionEvent(session, event);
  return response.events;
}

async function runEventPump(session: Session): Promise<void> {
  while (session.running) {
    try {
      await poll(session);
    } catch (reason) {
      if (!session.running) return;
      const error = reason instanceof Error ? reason : new Error(String(reason));
      for (const pending of session.pending.values()) pending.reject(error);
      session.pending.clear();
      session.running = false;
      await emit("lsp://server-crashed", {});
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
}

async function waitUntilReady(session: Session): Promise<void> {
  const deadline = Date.now() + INITIALIZE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const events = await poll(session);
    const state = [...events].reverse().find((event) => event.type === "stateChanged")?.state;
    if (state === "ready") return;
    if (state === "failed" || state === "stopped") {
      const failure = [...events]
        .reverse()
        .find((event) => event.type === "stateChanged" && event.error)?.error;
      const detail = [
        failure?.underlyingMessage,
        failure?.processExitCode != null ? `exit code ${failure.processExitCode}` : null,
      ]
        .filter(Boolean)
        .join("; ");
      const error = new Error(
        [failure?.message ?? `Language server entered ${state} state`, detail]
          .filter(Boolean)
          .join(" "),
      ) as Error & { code?: string; details?: string };
      error.code = failure?.code;
      error.details = detail || failure?.stage;
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
  const error = new Error("Language server initialization timed out") as Error & { code?: string };
  error.code = "timed_out";
  throw error;
}

async function stopAndDestroySession(session: Session): Promise<void> {
  session.running = false;
  await core("lsp.stopServer", { sessionId: session.id });

  const deadline = Date.now() + SESSION_CLEANUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    try {
      await core("lsp.destroyServer", { sessionId: session.id });
      return;
    } catch {
      // A graceful stop is asynchronous; keep draining events until Core is terminal.
    }
    await poll(session);
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }

  await core("lsp.destroyServer", { sessionId: session.id });
}

async function cleanupFailedStart(key: string, session: Session): Promise<void> {
  try {
    await stopAndDestroySession(session);
  } catch (reason) {
    frontendTrace("warn", "lsp.runtime", "Language-server cleanup failed", {
      sessionId: session.id,
      error: reason instanceof Error ? reason.message : String(reason),
    });
  }
  sessions.delete(key);
}

function sessionForFile(filePath: string): Session {
  const session = fileSessions.get(filePath);
  if (!session) throw new Error(`No LSP client for this file: ${filePath}`);
  return session;
}

async function start(args: JsonRecord): Promise<void> {
  const workspacePath = String(args.workspacePath ?? "");
  const languageId = String(args.languageId ?? "plaintext");
  const providerId = String(args.providerId ?? languageId);
  const key = `${workspacePath}:${languageId}`;
  let session = sessions.get(key);
  if (!session) {
    const environment = {
      ...args.tools?.lsp?.env,
      ...args.environment,
    };
    const started = await core<{ sessionId: string }>("lsp.startServer", {
      providerId,
      executablePath: args.serverPath,
      arguments: args.serverArgs ?? [],
      environment,
      rootUri: fileUri(workspacePath),
      workingDirectory: workspacePath,
      initializationOptions: args.initializationOptions ?? null,
      runtimeExecutablePath: args.runtimeExecutablePath ?? null,
      cacheDirectory: args.cacheDirectory ?? null,
      initializeTimeoutMilliseconds: INITIALIZE_TIMEOUT_MS,
    });
    session = {
      id: started.sessionId,
      workspacePath,
      languageId,
      files: new Set(),
      running: false,
      pending: new Map(),
      completed: new Map(),
    };
    sessions.set(key, session);
    try {
      await waitUntilReady(session);
    } catch (error) {
      await cleanupFailedStart(key, session);
      throw error;
    }
    session.running = true;
    void runEventPump(session);
  }
  if (args.filePath) {
    session.files.add(args.filePath);
    fileSessions.set(args.filePath, session);
  }
}

async function stopSession(session: Session): Promise<void> {
  await stopAndDestroySession(session);
  sessions.delete(`${session.workspacePath}:${session.languageId}`);
  for (const file of session.files) fileSessions.delete(file);
}

async function requestOperation(session: Session, payload: JsonRecord): Promise<unknown> {
  const started = await core<{ operationId: string }>("lsp.request", payload);
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      session.pending.delete(started.operationId);
      void core("lsp.cancelOperation", {
        sessionId: session.id,
        operationId: started.operationId,
      });
      reject(new Error("LSP request timed out"));
    }, 30_000);
    session.pending.set(started.operationId, {
      resolve: (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timeout);
        reject(error);
      },
    });
    const completed = session.completed.get(started.operationId);
    if (completed) {
      session.completed.delete(started.operationId);
      void dispatchSessionEvent(session, completed);
    }
  });
}

const operations: Record<string, string> = {
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
};

function semanticPayload(command: string, args: JsonRecord, session: Session): JsonRecord {
  const payload: JsonRecord = {
    sessionId: session.id,
    operation: operations[command],
  };
  if (command === "lsp_get_virtual_document") {
    payload.virtualUri = args.virtualUri;
  } else {
    payload.uri = fileUri(args.filePath);
  }
  if (typeof args.line === "number") {
    payload.position = { line: args.line, utf16Column: args.character ?? 0 };
  }
  if (command === "lsp_rename") payload.newName = args.newName;
  if (command === "lsp_get_inlay_hints") {
    payload.range = {
      start: { line: args.startLine, utf16Column: 0 },
      end: { line: args.endLine, utf16Column: 0 },
    };
  }
  if (command === "lsp_get_code_actions") {
    const diagnostic = args.diagnostic ?? {};
    payload.range = {
      start: { line: diagnostic.line ?? 0, utf16Column: diagnostic.column ?? 0 },
      end: {
        line: diagnostic.endLine ?? diagnostic.line ?? 0,
        utf16Column: diagnostic.endColumn ?? diagnostic.column ?? 0,
      },
    };
    payload.diagnostics = [
      {
        range: payload.range,
        message: diagnostic.message ?? "",
        severity: diagnostic.severity ?? null,
        source: diagnostic.source ?? null,
        code: diagnostic.code == null ? null : String(diagnostic.code),
      },
    ];
  }
  return payload;
}

function unwrapResult(command: string, result: any): unknown {
  const normalized = normalizeCoreValue(result) as JsonRecord;
  switch (command) {
    case "lsp_get_completions":
      return normalized.items ?? [];
    case "lsp_get_hover": {
      const hover = normalized.hover;
      if (!hover) return null;
      return {
        contents: hover.isMarkdown
          ? { kind: "markdown", value: hover.contents ?? "" }
          : (hover.contents ?? ""),
        range: hover.range,
      };
    }
    case "lsp_get_definition":
    case "lsp_get_implementation":
    case "lsp_get_type_definition":
    case "lsp_get_references":
      return normalized.locations ?? [];
    case "lsp_rename":
      return normalized.changes ? { changes: normalized.changes } : null;
    case "lsp_format_document":
      return normalized.edits ?? [];
    case "lsp_get_code_actions":
      return normalized.actions ?? [];
    case "lsp_get_inlay_hints":
      return (normalized.hints ?? []).map((hint: JsonRecord) => ({
        ...hint,
        line: hint.position?.line ?? 0,
        character: hint.position?.character ?? 0,
      }));
    case "lsp_get_code_lens":
      return (normalized.lenses ?? []).map((lens: JsonRecord) => ({
        line: lens.range?.start?.line ?? 0,
        title: lens.command?.title ?? "",
        command: lens.command?.command,
        arguments: lens.command?.arguments,
      }));
    case "lsp_get_virtual_document":
      return typeof normalized.text === "string" ? normalized.text : null;
    default:
      return normalized;
  }
}

async function semanticRequest(command: string, args: JsonRecord): Promise<unknown> {
  const session = sessionForFile(args.filePath);
  const result = await requestOperation(session, semanticPayload(command, args, session));
  return unwrapResult(command, result);
}

export async function invokeLsp<T>(command: string, args: JsonRecord = {}): Promise<T> {
  if (command === "lsp_start" || command === "lsp_start_for_file") {
    await start(args);
    return undefined as T;
  }
  if (command === "lsp_stop") {
    const matches = [...sessions.values()].filter(
      (session) => session.workspacePath === args.workspacePath,
    );
    await Promise.all(matches.map(stopSession));
    return undefined as T;
  }
  if (command === "lsp_stop_for_file") {
    const session = sessionForFile(args.filePath);
    session.files.delete(args.filePath);
    fileSessions.delete(args.filePath);
    if (session.files.size === 0) await stopSession(session);
    return undefined as T;
  }
  if (
    command === "lsp_document_open" ||
    command === "lsp_document_change" ||
    command === "lsp_document_save"
  ) {
    const session = sessionForFile(args.filePath);
    await core("lsp.syncDocument", {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      text: args.content,
    });
    return undefined as T;
  }
  if (command === "lsp_document_close") {
    const session = sessionForFile(args.filePath);
    await core("lsp.closeDocument", { sessionId: session.id, uri: fileUri(args.filePath) });
    return undefined as T;
  }
  if (command === "lsp_apply_code_action") {
    const session = sessionForFile(args.filePath);
    const commandPayload = args.actionPayload?.command ?? args.actionPayload;
    if (!commandPayload?.command) return { applied: true } as T;
    try {
      await requestOperation(session, {
        sessionId: session.id,
        operation: "executeCommand",
        command: commandPayload,
      });
      return { applied: true } as T;
    } catch (reason) {
      return {
        applied: false,
        reason: reason instanceof Error ? reason.message : String(reason),
      } as T;
    }
  }
  if (command in operations) return (await semanticRequest(command, args)) as T;
  throw new Error(`LSP operation is not supported by the shared Core: ${command}`);
}
