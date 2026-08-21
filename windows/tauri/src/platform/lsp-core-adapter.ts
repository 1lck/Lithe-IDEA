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
  ready: boolean;
  features: Set<string>;
  featuresKnown: boolean;
  recovered: boolean;
  pending: Map<string, { resolve: (value: unknown) => void; reject: (reason: Error) => void }>;
  completed: Map<string, RuntimeEvent>;
}

interface StoredSession {
  id: string;
  workspacePath: string;
  languageId: string;
  files: string[];
  ready?: boolean;
  features?: string[];
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
  capabilities?: string[];
}

export interface LspSessionSnapshot {
  id: string;
  workspacePath: string;
  languageId: string;
  ready: boolean;
  features: string[];
  featuresKnown: boolean;
}

const sessions = new Map<string, Session>();
const fileSessions = new Map<string, Session>();
const sessionStarts = new Map<string, Promise<Session>>();
const sessionStops = new Map<string, Promise<void>>();
const pendingFileSessions = new Map<string, string>();
const SESSION_STORAGE_KEY = "lithe:lsp-core-sessions:v1";

function normalizedPathKey(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
}

function sessionKey(workspacePath: string, languageId: string): string {
  return `${normalizedPathKey(workspacePath)}:${languageId}`;
}

function fileKey(filePath: string): string {
  return normalizedPathKey(filePath);
}

function availableSessionStorage(): Storage | null {
  try {
    return typeof sessionStorage === "undefined" ? null : sessionStorage;
  } catch {
    return null;
  }
}

function persistSessions(): void {
  const storage = availableSessionStorage();
  if (!storage) return;

  const stored: StoredSession[] = [...sessions.values()]
    .map((session) => ({
      id: session.id,
      workspacePath: session.workspacePath,
      languageId: session.languageId,
      files: [...session.files].sort(),
      ready: session.ready,
      features: [...session.features].sort(),
    }))
    .sort((left, right) =>
      sessionKey(left.workspacePath, left.languageId).localeCompare(
        sessionKey(right.workspacePath, right.languageId),
      ),
    );

  try {
    if (stored.length === 0) {
      storage.removeItem(SESSION_STORAGE_KEY);
    } else {
      storage.setItem(SESSION_STORAGE_KEY, JSON.stringify(stored));
    }
  } catch (reason) {
    frontendTrace("warn", "lsp.runtime", "Could not persist language-server sessions", {
      error: reason instanceof Error ? reason.message : String(reason),
    });
  }
}

function attachFile(session: Session, filePath: string): Session | null {
  const key = fileKey(filePath);
  const previous = fileSessions.get(key);
  if (previous && previous !== session) {
    for (const existing of previous.files) {
      if (fileKey(existing) === key) previous.files.delete(existing);
    }
  }
  for (const existing of session.files) {
    if (fileKey(existing) === key) session.files.delete(existing);
  }
  session.files.add(filePath);
  fileSessions.set(key, session);
  return previous && previous !== session ? previous : null;
}

function detachFile(session: Session, filePath: string): void {
  const key = fileKey(filePath);
  for (const existing of session.files) {
    if (fileKey(existing) === key) session.files.delete(existing);
  }
  if (fileSessions.get(key) === session) fileSessions.delete(key);
}

function removeSessionMappings(session: Session): void {
  const key = sessionKey(session.workspacePath, session.languageId);
  if (sessions.get(key) === session) sessions.delete(key);
  for (const file of session.files) {
    if (fileSessions.get(fileKey(file)) === session) fileSessions.delete(fileKey(file));
  }
}

function restorePersistedSessions(): void {
  const storage = availableSessionStorage();
  if (!storage) return;

  try {
    const value: unknown = JSON.parse(storage.getItem(SESSION_STORAGE_KEY) ?? "[]");
    if (!Array.isArray(value)) throw new Error("Stored sessions are not an array");

    for (const candidate of value) {
      const stored = candidate as Partial<StoredSession> | null;
      if (
        !stored ||
        typeof stored !== "object" ||
        typeof stored.id !== "string" ||
        typeof stored.workspacePath !== "string" ||
        typeof stored.languageId !== "string" ||
        !Array.isArray(stored.files) ||
        !stored.files.every((file: unknown) => typeof file === "string") ||
        (stored.ready !== undefined && typeof stored.ready !== "boolean") ||
        (stored.features !== undefined &&
          (!Array.isArray(stored.features) ||
            !stored.features.every((feature: unknown) => typeof feature === "string")))
      ) {
        continue;
      }

      const session: Session = {
        id: stored.id,
        workspacePath: stored.workspacePath,
        languageId: stored.languageId,
        files: new Set(),
        running: false,
        // Version-one entries created before this field existed were all ready.
        ready: stored.ready ?? true,
        features: new Set(stored.features ?? []),
        featuresKnown: stored.features !== undefined,
        recovered: true,
        pending: new Map(),
        completed: new Map(),
      };
      const key = sessionKey(session.workspacePath, session.languageId);
      const previous = sessions.get(key);
      if (previous) removeSessionMappings(previous);
      sessions.set(key, session);
      for (const file of stored.files) attachFile(session, file);
    }
    for (const session of sessions.values()) {
      if (session.files.size === 0) removeSessionMappings(session);
    }
  } catch (reason) {
    storage.removeItem(SESSION_STORAGE_KEY);
    frontendTrace("warn", "lsp.runtime", "Could not restore language-server sessions", {
      error: reason instanceof Error ? reason.message : String(reason),
    });
  }
}

restorePersistedSessions();

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    persistSessions();
    for (const session of sessions.values()) session.running = false;
  });
}

function coreData<T>(response: CoreResponse<T>): T {
  if (response.ok) return response.data;
  const error = new Error(response.error.message) as Error & {
    code?: string;
    details?: string;
  };
  error.code = response.error.code;
  error.details = response.error.details;
  throw error;
}

function lspAdapterError(code: string, message: string): Error & { code: string } {
  const error = new Error(message) as Error & { code: string };
  error.code = code;
  return error;
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
  if (event.type === "stateChanged" && (event.state === "failed" || event.state === "stopped")) {
    const error = new Error(`Language server entered ${event.state} state`) as Error & {
      code?: string;
    };
    error.code = event.state === "failed" ? "sessionFailed" : "sessionStopped";
    for (const pending of session.pending.values()) pending.reject(error);
    session.pending.clear();
    session.running = false;
    session.ready = false;
  }
  if (event.type === "featuresChanged") {
    session.features = new Set(event.capabilities ?? []);
    session.featuresKnown = true;
    persistSessions();
    await emit("lsp://features-changed", {
      sessionId: session.id,
      workspacePath: session.workspacePath,
      languageId: session.languageId,
      features: [...session.features].sort(),
    });
  }
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

async function poll(
  session: Session,
  timeoutMilliseconds = 30_000,
): Promise<RuntimeEvent[]> {
  const response = await core<{ events: RuntimeEvent[] }>("lsp.waitEvents", {
    sessionId: session.id,
    timeoutMilliseconds,
  });
  for (const event of response.events) await dispatchSessionEvent(session, event);
  return response.events;
}

async function runEventPump(session: Session): Promise<void> {
  while (session.running) {
    try {
      const events = await poll(session);
      if (!session.running) return;
      const terminalState = [...events]
        .reverse()
        .find(
          (event) =>
            event.type === "stateChanged" &&
            (event.state === "failed" || event.state === "stopped"),
        )?.state;
      if (terminalState) {
        const error = new Error(`Language server entered ${terminalState} state`);
        for (const pending of session.pending.values()) pending.reject(error);
        session.pending.clear();
        session.running = false;
        session.ready = false;
        removeSessionMappings(session);
        persistSessions();
        return;
      }
    } catch (reason) {
      if (!session.running) return;
      const error = reason instanceof Error ? reason : new Error(String(reason));
      for (const pending of session.pending.values()) pending.reject(error);
      session.pending.clear();
      session.running = false;
      session.ready = false;
      removeSessionMappings(session);
      persistSessions();
      const details = String((error as Error & { details?: string }).details ?? "");
      // waitEvents returns process_failed/sessionStopped after an intentional stop.
      if (details !== "sessionStopped") {
        await emit("lsp://server-crashed", {});
      }
      return;
    }
  }
}

async function waitUntilReady(session: Session): Promise<void> {
  const deadline = Date.now() + INITIALIZE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const events = await poll(session, 200);
    const state = [...events].reverse().find((event) => event.type === "stateChanged")?.state;
    if (state === "ready") {
      session.ready = true;
      persistSessions();
      return;
    }
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
  }
  const error = new Error("Language server initialization timed out") as Error & { code?: string };
  error.code = "timed_out";
  throw error;
}

async function stopAndDestroySession(session: Session): Promise<void> {
  session.running = false;
  session.ready = false;
  await core("lsp.stopServer", { sessionId: session.id });

  const deadline = Date.now() + SESSION_CLEANUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    try {
      await core("lsp.destroyServer", { sessionId: session.id });
      return;
    } catch {
      // A graceful stop is asynchronous; keep draining events until Core is terminal.
    }
    try {
      await poll(session, POLL_INTERVAL_MS);
    } catch {
      // Terminal waitEvents errors mean the session is already stopped.
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }

  await core("lsp.destroyServer", { sessionId: session.id });
}

async function cleanupFailedStart(key: string, session: Session): Promise<void> {
  if (sessions.get(key) === session) sessions.delete(key);
  removeSessionMappings(session);
  persistSessions();
  try {
    await stopAndDestroySession(session);
  } catch (reason) {
    frontendTrace("warn", "lsp.runtime", "Language-server cleanup failed", {
      sessionId: session.id,
      error: reason instanceof Error ? reason.message : String(reason),
    });
  }
}

function sessionForFile(filePath: string): Session {
  const session = fileSessions.get(fileKey(filePath));
  if (!session) {
    throw lspAdapterError("no_session", `No language-server session owns this file: ${filePath}`);
  }
  return session;
}

async function recoverSession(session: Session): Promise<Session | null> {
  try {
    const events = await poll(session, 200);
    const state = [...events].reverse().find((event) => event.type === "stateChanged")?.state;
    if (state === "failed" || state === "stopped" || state === "stopping") {
      try {
        if (state === "stopping") {
          await stopAndDestroySession(session);
        } else {
          await core("lsp.destroyServer", { sessionId: session.id });
        }
      } catch (reason) {
        frontendTrace("warn", "lsp.runtime", "Could not destroy stale language-server session", {
          sessionId: session.id,
          error: reason instanceof Error ? reason.message : String(reason),
        });
      }
      removeSessionMappings(session);
      persistSessions();
      return null;
    }

    if (state === "ready") {
      session.ready = true;
    } else if (state) {
      session.ready = false;
    }
    if (!session.ready) await waitUntilReady(session);

    if (!session.featuresKnown) {
      await stopAndDestroySession(session);
      removeSessionMappings(session);
      persistSessions();
      return null;
    }

    session.recovered = false;
    session.running = true;
    persistSessions();
    void runEventPump(session);
    return session;
  } catch (reason) {
    removeSessionMappings(session);
    persistSessions();
    frontendTrace("warn", "lsp.runtime", "Could not recover language-server session", {
      sessionId: session.id,
      error: reason instanceof Error ? reason.message : String(reason),
    });
    return null;
  }
}

async function createSession(args: JsonRecord, key: string): Promise<Session> {
  const workspacePath = String(args.workspacePath ?? "");
  const languageId = String(args.languageId ?? "plaintext");
  const providerId = String(args.providerId ?? languageId);
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
  const session: Session = {
    id: started.sessionId,
    workspacePath,
    languageId,
    files: new Set(),
    running: false,
    ready: false,
    features: new Set(),
    featuresKnown: false,
    recovered: false,
    pending: new Map(),
    completed: new Map(),
  };
  sessions.set(key, session);
  persistSessions();
  try {
    await waitUntilReady(session);
  } catch (error) {
    await cleanupFailedStart(key, session);
    throw error;
  }
  session.running = true;
  persistSessions();
  void runEventPump(session);
  return session;
}

async function resolveSession(args: JsonRecord, key: string): Promise<Session> {
  const stopping = sessionStops.get(key);
  if (stopping) await stopping;

  const existing = sessions.get(key);
  if (existing && !existing.recovered) return existing;

  if (existing) {
    const recovered = await recoverSession(existing);
    if (recovered) return recovered;
  }

  return createSession(args, key);
}

async function start(args: JsonRecord): Promise<void> {
  const workspacePath = String(args.workspacePath ?? "");
  const languageId = String(args.languageId ?? "plaintext");
  const key = sessionKey(workspacePath, languageId);
  const filePath = args.filePath ? String(args.filePath) : null;
  const pendingFileKey = filePath ? fileKey(filePath) : null;
  if (pendingFileKey) pendingFileSessions.set(pendingFileKey, key);
  let session = sessions.get(key);

  try {
    if (!session || session.recovered || !session.ready) {
      let startPromise = sessionStarts.get(key);
      if (!startPromise) {
        startPromise = resolveSession(args, key).finally(() => sessionStarts.delete(key));
        sessionStarts.set(key, startPromise);
      }
      session = await startPromise;
    }

    if (filePath) {
      const displaced = attachFile(session, filePath);
      persistSessions();
      if (displaced && displaced.files.size === 0) await stopSession(displaced);
    }
  } finally {
    if (pendingFileKey && pendingFileSessions.get(pendingFileKey) === key) {
      pendingFileSessions.delete(pendingFileKey);
    }
  }
}

async function stopSession(session: Session): Promise<void> {
  const key = sessionKey(session.workspacePath, session.languageId);
  removeSessionMappings(session);
  persistSessions();

  let stopPromise = sessionStops.get(key);
  if (!stopPromise) {
    stopPromise = stopAndDestroySession(session).finally(() => {
      if (sessionStops.get(key) === stopPromise) sessionStops.delete(key);
    });
    sessionStops.set(key, stopPromise);
  }
  await stopPromise;
}

async function sessionForStoppingFile(filePath: string): Promise<Session | null> {
  const key = fileKey(filePath);
  const pendingSessionKey = pendingFileSessions.get(key);
  const pendingStart = pendingSessionKey ? sessionStarts.get(pendingSessionKey) : null;
  if (pendingStart) {
    try {
      await pendingStart;
    } catch {
      return null;
    }
  }
  return fileSessions.get(key) ?? null;
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

export const LSP_OPERATION_BY_COMMAND = {
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
} as const;

export const LSP_EXPLICITLY_UNAVAILABLE_COMMANDS = [
  "lsp_get_semantic_tokens",
  "lsp_get_document_symbols",
  "lsp_get_workspace_symbols",
  "lsp_get_signature_help",
  "lsp_get_signature_trigger_characters",
  "lsp_format_range",
  "lsp_prepare_rename",
] as const;

const operations: Record<string, string> = LSP_OPERATION_BY_COMMAND;
const explicitlyUnavailableCommands = new Set<string>(LSP_EXPLICITLY_UNAVAILABLE_COMMANDS);

export function isLspSemanticCommandSupported(command: string): boolean {
  return command in operations;
}

function semanticPayload(command: string, args: JsonRecord, session: Session): JsonRecord {
  const payload: JsonRecord = {
    sessionId: session.id,
    operation: operations[command],
  };
  if (command === "lsp_get_virtual_document") {
    payload.virtualUri = args.virtualUri;
  } else {
    payload.uri = typeof args.documentUri === "string" ? args.documentUri : fileUri(args.filePath);
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
  const session = sessionForFile(args.sessionFilePath ?? args.filePath);
  const result = await requestOperation(session, semanticPayload(command, args, session));
  return unwrapResult(command, result);
}

export function getLspSessionSnapshot(args: {
  filePath: string;
  sessionFilePath?: string;
}): LspSessionSnapshot | null {
  const session = fileSessions.get(fileKey(args.sessionFilePath ?? args.filePath));
  if (!session) return null;
  return {
    id: session.id,
    workspacePath: session.workspacePath,
    languageId: session.languageId,
    ready: session.ready,
    features: [...session.features].sort(),
    featuresKnown: session.featuresKnown,
  };
}

export async function invokeLsp<T>(command: string, args: JsonRecord = {}): Promise<T> {
  if (command === "lsp_start" || command === "lsp_start_for_file") {
    await start(args);
    return undefined as T;
  }
  if (command === "lsp_stop") {
    const matches = [...sessions.values()].filter(
      (session) =>
        normalizedPathKey(session.workspacePath) === normalizedPathKey(args.workspacePath),
    );
    await Promise.all(matches.map(stopSession));
    return undefined as T;
  }
  if (command === "lsp_stop_for_file") {
    const session = await sessionForStoppingFile(args.filePath);
    if (!session) return undefined as T;
    detachFile(session, args.filePath);
    if (session.files.size === 0) {
      await stopSession(session);
    } else {
      persistSessions();
    }
    return undefined as T;
  }
  if (command === "lsp_document_open") {
    const session = sessionForFile(args.filePath);
    await core("lsp.syncDocument", {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      text: args.content ?? "",
    });
    return undefined as T;
  }
  if (command === "lsp_document_change") {
    const session = sessionForFile(args.filePath);
    const contentChanges = Array.isArray(args.contentChanges)
      ? args.contentChanges
          .map((change: JsonRecord) => {
            if (
              typeof change.startLine !== "number" ||
              typeof change.startColumn !== "number" ||
              typeof change.endLine !== "number" ||
              typeof change.endColumn !== "number"
            ) {
              return null;
            }
            return {
              range: {
                start: { line: change.startLine, utf16Column: change.startColumn },
                end: { line: change.endLine, utf16Column: change.endColumn },
              },
              text: String(change.text ?? ""),
            };
          })
          .filter(Boolean)
      : [];
    await core("lsp.syncDocument", {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      // Prefer ranged changes when present, but keep full text so Core can
      // fall back to a full-document didChange for unsafe multi-change batches.
      text: args.content ?? "",
      ...(contentChanges.length > 0 ? { contentChanges } : {}),
    });
    return undefined as T;
  }
  if (command === "lsp_document_save") {
    const session = sessionForFile(args.filePath);
    await core("lsp.syncDocument", {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      text: args.content ?? "",
    });
    return undefined as T;
  }
  if (command === "lsp_document_close") {
    const session = sessionForFile(args.filePath);
    await core("lsp.closeDocument", { sessionId: session.id, uri: fileUri(args.filePath) });
    return undefined as T;
  }
  if (command === "lsp_apply_code_action") {
    const session = sessionForFile(args.sessionFilePath ?? args.filePath);
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
  if (explicitlyUnavailableCommands.has(command)) {
    throw lspAdapterError(
      "unsupported_capability",
      `LSP operation is not available through the shared Core: ${command}`,
    );
  }
  throw lspAdapterError("invalid_request", `Unknown LSP adapter command: ${command}`);
}
