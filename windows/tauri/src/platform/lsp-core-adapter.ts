import { emit } from "@tauri-apps/api/event";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { frontendTrace } from "@/utils/frontend-trace";
import {
  createSessionLifecycle,
  featureSnapshot,
  isSessionReady,
  isSessionTerminal,
  LspOperationLog,
  transitionSessionLifecycle,
  type CoreLspSessionState,
  type LspAdapterSessionPhase,
  type LspFeatureSnapshot,
  type LspSessionLifecycle,
} from "./lsp-session-lifecycle";

type JsonRecord = Record<string, any>;

const INITIALIZE_TIMEOUT_MS = 30_000;
const SESSION_CLEANUP_TIMEOUT_MS = 5_000;
const POLL_INTERVAL_MS = 20;

interface PendingOperation {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

type EventPumpState =
  | { phase: "starting" }
  | { phase: "running"; completion: Promise<void> }
  | { phase: "cancelled"; completion: Promise<void> }
  | { phase: "completed" };

interface EventPumpOwner {
  // Cancellation is cooperative because an in-flight Core long poll cannot be
  // aborted by JavaScript; stopServer wakes it and the owner then releases.
  operation: LspOperationLog;
  state: EventPumpState;
}

interface Session {
  id: string;
  workspacePath: string;
  languageId: string;
  files: Set<string>;
  lifecycle: LspSessionLifecycle;
  eventPump: EventPumpOwner | null;
  featureState: { phase: "unknown" } | { phase: "known"; features: Set<string> };
  pending: Map<string, PendingOperation>;
  completed: Map<string, RuntimeEvent>;
  documentVersions: Map<string, number>;
}

interface FileAttachment {
  session: Session;
  id: string;
}

interface PendingFileAttachment {
  sessionKey: string;
  attachmentId: string;
  operation: LspOperationLog;
}

interface StoredSession {
  id: string;
  workspacePath: string;
  languageId: string;
  files: string[];
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
  state?: CoreLspSessionState;
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
  phase: LspAdapterSessionPhase;
  operationId: string;
  featureState: LspFeatureSnapshot;
}

const sessions = new Map<string, Session>();
const fileSessions = new Map<string, FileAttachment>();
const sessionStarts = new Map<string, Promise<Session>>();
const sessionStops = new Map<string, Promise<void>>();
const pendingFileSessions = new Map<string, PendingFileAttachment>();
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
      features:
        session.featureState.phase === "known"
          ? [...session.featureState.features].sort()
          : undefined,
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

function attachFile(session: Session, filePath: string, attachmentId: string): Session | null {
  const key = fileKey(filePath);
  const previous = fileSessions.get(key)?.session;
  if (previous && previous !== session) {
    for (const existing of previous.files) {
      if (fileKey(existing) === key) previous.files.delete(existing);
    }
  }
  for (const existing of session.files) {
    if (fileKey(existing) === key) session.files.delete(existing);
  }
  session.files.add(filePath);
  fileSessions.set(key, { session, id: attachmentId });
  return previous && previous !== session ? previous : null;
}

function detachFile(session: Session, filePath: string, attachmentId?: string): boolean {
  const key = fileKey(filePath);
  const attachment = fileSessions.get(key);
  if (
    !attachment ||
    attachment.session !== session ||
    (attachmentId !== undefined && attachment.id !== attachmentId)
  ) {
    return false;
  }
  for (const existing of session.files) {
    if (fileKey(existing) === key) session.files.delete(existing);
  }
  fileSessions.delete(key);
  return true;
}

function removeSessionMappings(session: Session): void {
  const key = sessionKey(session.workspacePath, session.languageId);
  if (sessions.get(key) === session) sessions.delete(key);
  for (const file of session.files) {
    if (fileSessions.get(fileKey(file))?.session === session) fileSessions.delete(fileKey(file));
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
        // Persisted entries are projections of Core state. They must be
        // validated before any new document can attach after a reload.
        lifecycle: createSessionLifecycle("recovering"),
        eventPump: null,
        featureState:
          stored.features === undefined
            ? { phase: "unknown" }
            : { phase: "known", features: new Set(stored.features) },
        pending: new Map(),
        completed: new Map(),
        documentVersions: new Map(),
      };
      const key = sessionKey(session.workspacePath, session.languageId);
      const previous = sessions.get(key);
      if (previous) removeSessionMappings(previous);
      sessions.set(key, session);
      for (const file of stored.files) attachFile(session, file, crypto.randomUUID());
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
    for (const session of sessions.values()) {
      cancelEventPump(session, "module-disposed");
      transitionSessionLifecycle(session.lifecycle, "recovering");
    }
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

async function core<T>(
  command: string,
  payload: JsonRecord,
  operationId: string = crypto.randomUUID(),
): Promise<T> {
  return coreData(
    await executeCore<T>({
      id: operationId,
      operationId,
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
  if (event.type === "stateChanged" && event.state) {
    // Core events are consumptive. Synchronize every state transition here so
    // any poller (startup, recovery, or the long-lived pump) leaves a durable
    // readiness snapshot for the rest of the frontend.
    transitionSessionLifecycle(session.lifecycle, event.state);
    if (event.state === "failed" || event.state === "stopped") {
      const error = new Error(`Language server entered ${event.state} state`) as Error & {
        code?: string;
      };
      error.code = event.state === "failed" ? "sessionFailed" : "sessionStopped";
      rejectPendingOperations(session, error);
    }
    persistSessions();
  }
  if (event.type === "featuresChanged") {
    session.featureState = { phase: "known", features: new Set(event.capabilities ?? []) };
    persistSessions();
    await emit("lsp://features-changed", {
      sessionId: session.id,
      workspacePath: session.workspacePath,
      languageId: session.languageId,
      features: [...session.featureState.features].sort(),
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

async function poll(session: Session, timeoutMilliseconds = 30_000): Promise<RuntimeEvent[]> {
  const response = await core<{ events: RuntimeEvent[] }>("lsp.waitEvents", {
    sessionId: session.id,
    timeoutMilliseconds,
  });
  for (const event of response.events) await dispatchSessionEvent(session, event);
  return response.events;
}

function rejectPendingOperations(session: Session, error: Error): void {
  const pending = [...session.pending.values()];
  session.pending.clear();
  for (const operation of pending) operation.reject(error);
}

function startEventPump(session: Session): void {
  if (
    session.eventPump?.state.phase === "starting" ||
    session.eventPump?.state.phase === "running"
  ) {
    return;
  }

  const owner: EventPumpOwner = {
    operation: new LspOperationLog("eventPump", crypto.randomUUID(), {
      sessionId: session.id,
      workspacePath: session.workspacePath,
      languageId: session.languageId,
    }),
    state: { phase: "starting" },
  };
  session.eventPump = owner;
  const completion = Promise.resolve().then(() => runEventPump(session, owner));
  owner.state = { phase: "running", completion };
}

function cancelEventPump(session: Session, reason: string): void {
  const owner = session.eventPump;
  if (!owner || owner.state.phase !== "running") return;
  owner.state = { phase: "cancelled", completion: owner.state.completion };
  owner.operation.cancelled(reason);
}

async function runEventPump(session: Session, owner: EventPumpOwner): Promise<void> {
  try {
    while (
      session.eventPump === owner &&
      owner.state.phase === "running" &&
      !isSessionTerminal(session.lifecycle)
    ) {
      const events = await poll(session);
      if (session.eventPump !== owner || owner.state.phase !== "running") return;
      const terminalState = [...events]
        .reverse()
        .find(
          (event) =>
            event.type === "stateChanged" &&
            (event.state === "failed" || event.state === "stopped"),
        )?.state;
      if (terminalState) {
        removeSessionMappings(session);
        persistSessions();
        if (terminalState === "failed") {
          owner.operation.failed(new Error("Language server entered failed state"), {
            sessionState: terminalState,
          });
        } else {
          owner.operation.succeeded({ sessionState: terminalState });
        }
        return;
      }
    }
  } catch (reason) {
    if (owner.state.phase === "cancelled" || session.eventPump !== owner) return;
    const error = reason instanceof Error ? reason : new Error(String(reason));
    rejectPendingOperations(session, error);
    transitionSessionLifecycle(session.lifecycle, "failed");
    removeSessionMappings(session);
    persistSessions();
    owner.operation.failed(error);
    const details = String((error as Error & { details?: string }).details ?? "");
    // waitEvents returns process_failed/sessionStopped after an intentional stop.
    if (details !== "sessionStopped") {
      await emit("lsp://server-crashed", {});
    }
  } finally {
    if (session.eventPump === owner) {
      owner.state = { phase: "completed" };
      session.eventPump = null;
    }
  }
}

async function waitUntilReady(session: Session): Promise<void> {
  const deadline = Date.now() + INITIALIZE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const events = await poll(session, 200);
    if (isSessionReady(session.lifecycle)) return;
    const state = [...events].reverse().find((event) => event.type === "stateChanged")?.state;
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

async function stopAndDestroySession(
  session: Session,
  operationId: string,
): Promise<"stopped" | "timedOut"> {
  cancelEventPump(session, "session-stop-requested");
  transitionSessionLifecycle(session.lifecycle, "stopping", operationId);
  await core("lsp.stopServer", { sessionId: session.id }, operationId);

  const deadline = Date.now() + SESSION_CLEANUP_TIMEOUT_MS;
  let lastDestroyError: unknown;
  let lastPollError: unknown;
  while (Date.now() < deadline) {
    try {
      await core("lsp.destroyServer", { sessionId: session.id }, operationId);
      transitionSessionLifecycle(session.lifecycle, "stopped", operationId);
      return "stopped";
    } catch (reason) {
      lastDestroyError = reason;
    }
    try {
      await poll(session, POLL_INTERVAL_MS);
    } catch (reason) {
      lastPollError = reason;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }

  frontendTrace("warn", "lsp.lifecycle", "sessionCleanup:deadline", {
    operationId,
    sessionId: session.id,
    lastDestroyError:
      lastDestroyError instanceof Error ? lastDestroyError.message : String(lastDestroyError ?? ""),
    lastPollError:
      lastPollError instanceof Error ? lastPollError.message : String(lastPollError ?? ""),
  });
  await core("lsp.destroyServer", { sessionId: session.id }, operationId);
  transitionSessionLifecycle(session.lifecycle, "stopped", operationId);
  return "timedOut";
}

async function cleanupFailedStart(
  key: string,
  session: Session,
  operationId: string,
): Promise<void> {
  if (sessions.get(key) === session) sessions.delete(key);
  removeSessionMappings(session);
  persistSessions();
  try {
    await stopAndDestroySession(session, operationId);
  } catch (reason) {
    frontendTrace("warn", "lsp.runtime", "Language-server cleanup failed", {
      operationId,
      sessionId: session.id,
      error: reason instanceof Error ? reason.message : String(reason),
    });
  }
}

function sessionForFile(filePath: string, attachmentId?: string): Session {
  const attachment = fileSessions.get(fileKey(filePath));
  if (!attachment || (attachmentId !== undefined && attachment.id !== attachmentId)) {
    throw lspAdapterError("no_session", `No language-server session owns this file: ${filePath}`);
  }
  return attachment.session;
}

async function recoverSession(session: Session): Promise<Session | null> {
  const operation = new LspOperationLog("sessionRecovery", session.lifecycle.operationId, {
    sessionId: session.id,
    workspacePath: session.workspacePath,
    languageId: session.languageId,
  });
  try {
    const events = await poll(session, 200);
    const state = [...events].reverse().find((event) => event.type === "stateChanged")?.state;
    if (state === "failed" || state === "stopped" || state === "stopping") {
      try {
        if (state === "stopping") {
          await stopAndDestroySession(session, operation.operationId);
        } else {
          await core("lsp.destroyServer", { sessionId: session.id }, operation.operationId);
        }
      } catch (reason) {
        frontendTrace("warn", "lsp.runtime", "Could not destroy stale language-server session", {
          operationId: operation.operationId,
          sessionId: session.id,
          error: reason instanceof Error ? reason.message : String(reason),
        });
      }
      removeSessionMappings(session);
      persistSessions();
      operation.cancelled(`session-${state}`);
      return null;
    }

    if (state) transitionSessionLifecycle(session.lifecycle, state, operation.operationId);
    if (!isSessionReady(session.lifecycle)) await waitUntilReady(session);

    if (session.featureState.phase === "unknown") {
      await stopAndDestroySession(session, operation.operationId);
      removeSessionMappings(session);
      persistSessions();
      operation.cancelled("capabilities-not-recoverable");
      return null;
    }

    transitionSessionLifecycle(session.lifecycle, "ready", operation.operationId);
    persistSessions();
    startEventPump(session);
    operation.succeeded();
    return session;
  } catch (reason) {
    removeSessionMappings(session);
    persistSessions();
    operation.failed(reason);
    frontendTrace("warn", "lsp.runtime", "Could not recover language-server session", {
      operationId: operation.operationId,
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
  const operationId = crypto.randomUUID();
  const operation = new LspOperationLog("sessionStart", operationId, {
    workspacePath,
    languageId,
    providerId,
  });
  const environment = {
    ...args.tools?.lsp?.env,
    ...args.environment,
  };
  let started: { sessionId: string; state?: CoreLspSessionState };
  try {
    started = await core<{ sessionId: string; state?: CoreLspSessionState }>(
      "lsp.startServer",
      {
        providerId,
        executablePath: args.serverPath,
        arguments: args.serverArgs ?? [],
        environment,
        rootUri: fileUri(workspacePath),
        workingDirectory: workspacePath,
        initializationOptions: args.initializationOptions ?? null,
        runtimeExecutablePath: args.runtimeExecutablePath ?? null,
        jdtlsLaunchResources: args.jdtlsLaunchResources ?? null,
        cacheDirectory: args.cacheDirectory ?? null,
        workspaceFingerprint: args.workspaceFingerprint ?? null,
        initializeTimeoutMilliseconds: INITIALIZE_TIMEOUT_MS,
      },
      operationId,
    );
  } catch (reason) {
    operation.failed(reason, { stage: "processStart" });
    throw reason;
  }
  const session: Session = {
    id: started.sessionId,
    workspacePath,
    languageId,
    files: new Set(),
    lifecycle: createSessionLifecycle(started.state ?? "initializing", operationId),
    eventPump: null,
    featureState: { phase: "unknown" },
    pending: new Map(),
    completed: new Map(),
    documentVersions: new Map(),
  };
  sessions.set(key, session);
  persistSessions();
  try {
    await waitUntilReady(session);
  } catch (reason) {
    if ((reason as Error & { code?: string })?.code === "timed_out") {
      operation.timedOut({ stage: "initialize", sessionId: session.id });
    } else {
      operation.failed(reason, { stage: "initialize", sessionId: session.id });
    }
    await cleanupFailedStart(key, session, operationId);
    throw reason;
  }
  transitionSessionLifecycle(session.lifecycle, "ready", operationId);
  persistSessions();
  startEventPump(session);
  operation.succeeded({ sessionId: session.id });
  return session;
}

async function waitForProjectedReadiness(
  session: Session,
): Promise<"ready" | "terminal" | "timedOut"> {
  const operation = new LspOperationLog("sessionReadinessWait", crypto.randomUUID(), {
    sessionId: session.id,
    workspacePath: session.workspacePath,
    languageId: session.languageId,
  });
  const deadline = Date.now() + INITIALIZE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (isSessionReady(session.lifecycle)) {
      operation.succeeded();
      return "ready";
    }
    if (isSessionTerminal(session.lifecycle)) {
      operation.failed(new Error(`Language server entered ${session.lifecycle.phase} state`));
      return "terminal";
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
  operation.timedOut({ sessionState: session.lifecycle.phase });
  return "timedOut";
}

async function resolveSession(args: JsonRecord, key: string): Promise<Session> {
  const stopping = sessionStops.get(key);
  if (stopping) await stopping;

  const existing = sessions.get(key);
  if (existing && isSessionReady(existing.lifecycle)) return existing;

  if (existing?.lifecycle.phase === "recovering") {
    const recovered = await recoverSession(existing);
    if (recovered) return recovered;
  } else if (existing) {
    if (existing.eventPump && (await waitForProjectedReadiness(existing)) === "ready") {
      return existing;
    }
    await stopSession(existing);
  }

  return createSession(args, key);
}

async function start(args: JsonRecord): Promise<void> {
  const workspacePath = String(args.workspacePath ?? "");
  const languageId = String(args.languageId ?? "plaintext");
  const key = sessionKey(workspacePath, languageId);
  const filePath = args.filePath ? String(args.filePath) : null;
  const pendingFileKey = filePath ? fileKey(filePath) : null;
  const attachmentId = filePath ? String(args.attachmentId ?? crypto.randomUUID()) : null;
  let attachmentOperation: LspOperationLog | null = null;
  if (pendingFileKey && attachmentId) {
    const previous = pendingFileSessions.get(pendingFileKey);
    previous?.operation.cancelled("superseded-by-newer-attachment", {
      replacementOperationId: attachmentId,
    });
    attachmentOperation = new LspOperationLog("fileAttachment", attachmentId, {
      filePath,
      workspacePath,
      languageId,
    });
    pendingFileSessions.set(pendingFileKey, {
      sessionKey: key,
      attachmentId,
      operation: attachmentOperation,
    });
  }
  let session = sessions.get(key);

  try {
    if (!session || !isSessionReady(session.lifecycle)) {
      let startPromise = sessionStarts.get(key);
      if (!startPromise) {
        startPromise = resolveSession(args, key).finally(() => sessionStarts.delete(key));
        sessionStarts.set(key, startPromise);
      }
      session = await startPromise;
    }

    if (
      filePath &&
      attachmentId &&
      pendingFileSessions.get(fileKey(filePath))?.attachmentId === attachmentId
    ) {
      const displaced = attachFile(session, filePath, attachmentId);
      persistSessions();
      if (displaced && displaced.files.size === 0) await stopSession(displaced);
      attachmentOperation?.succeeded({ sessionId: session.id });
    } else if (filePath && attachmentId) {
      attachmentOperation?.cancelled("superseded-before-attachment");
    }
  } catch (reason) {
    const isCurrent =
      pendingFileKey &&
      attachmentId &&
      pendingFileSessions.get(pendingFileKey)?.attachmentId === attachmentId;
    if (isCurrent) {
      attachmentOperation?.failed(reason);
    } else {
      attachmentOperation?.cancelled("superseded-before-failure");
    }
    throw reason;
  } finally {
    if (
      pendingFileKey &&
      attachmentId &&
      pendingFileSessions.get(pendingFileKey)?.attachmentId === attachmentId
    ) {
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
    const operation = new LspOperationLog("sessionStop", crypto.randomUUID(), {
      sessionId: session.id,
      workspacePath: session.workspacePath,
      languageId: session.languageId,
    });
    stopPromise = stopAndDestroySession(session, operation.operationId)
      .then((outcome) => {
        if (outcome === "timedOut") {
          operation.timedOut({ stage: "cleanup" });
        } else {
          operation.succeeded();
        }
      })
      .catch((reason) => {
        operation.failed(reason);
        throw reason;
      })
      .finally(() => {
        if (sessionStops.get(key) === stopPromise) sessionStops.delete(key);
      });
    sessionStops.set(key, stopPromise);
  }
  await stopPromise;
}

async function sessionForStoppingFile(
  filePath: string,
  attachmentId?: string,
): Promise<Session | null> {
  const key = fileKey(filePath);
  const pendingAttachment = pendingFileSessions.get(key);
  const shouldWaitForPending =
    pendingAttachment &&
    (attachmentId === undefined || pendingAttachment.attachmentId === attachmentId);
  const pendingStart = shouldWaitForPending
    ? sessionStarts.get(pendingAttachment.sessionKey)
    : null;
  if (pendingStart) {
    try {
      await pendingStart;
    } catch (reason) {
      frontendTrace("info", "lsp.lifecycle", "fileStop:pendingStartFailed", {
        operationId: pendingAttachment?.attachmentId,
        filePath,
        error: reason instanceof Error ? reason.message : String(reason),
      });
      return null;
    }
  }
  const attachment = fileSessions.get(key);
  if (!attachment || (attachmentId !== undefined && attachment.id !== attachmentId)) return null;
  return attachment.session;
}

async function requestOperation(
  session: Session,
  payload: JsonRecord,
  command = "lsp.request",
): Promise<unknown> {
  const started = await core<{ operationId: string }>(command, payload);
  const operation = new LspOperationLog("semanticRequest", started.operationId, {
    sessionId: session.id,
    method: command,
    documentUri: payload.uri,
  });
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      session.pending.delete(started.operationId);
      operation.timedOut();
      void core(
        "lsp.cancelOperation",
        {
          sessionId: session.id,
          operationId: started.operationId,
        },
        started.operationId,
      ).catch((reason) => {
        frontendTrace("warn", "lsp.lifecycle", "semanticRequest:cancelFailed", {
          operationId: started.operationId,
          sessionId: session.id,
          error: reason instanceof Error ? reason.message : String(reason),
        });
      });
      reject(new Error("LSP request timed out"));
    }, 30_000);
    session.pending.set(started.operationId, {
      resolve: (value) => {
        clearTimeout(timeout);
        operation.succeeded();
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timeout);
        if ((error as Error & { code?: string }).code === "cancelled") {
          operation.cancelled(error.message);
        } else {
          operation.failed(error);
        }
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
        utf16Column: lens.range?.start?.utf16Column ?? 0,
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

async function synchronizeDocument(
  operationName: "documentOpen" | "documentChange" | "documentSave",
  session: Session,
  filePath: string,
  payload: JsonRecord,
): Promise<void> {
  const operation = new LspOperationLog(operationName, crypto.randomUUID(), {
    sessionId: session.id,
    filePath,
    languageId: session.languageId,
  });
  try {
    const sync = await core<{ documentVersion: number; changed: boolean }>(
      "lsp.syncDocument",
      payload,
      operation.operationId,
    );
    session.documentVersions.set(fileUri(filePath), sync.documentVersion);
    operation.succeeded({
      documentVersion: sync.documentVersion,
      changed: sync.changed,
    });
  } catch (reason) {
    operation.failed(reason);
    throw reason;
  }
}

async function closeDocument(session: Session, filePath: string): Promise<void> {
  const operation = new LspOperationLog("documentClose", crypto.randomUUID(), {
    sessionId: session.id,
    filePath,
    languageId: session.languageId,
  });
  try {
    await core(
      "lsp.closeDocument",
      { sessionId: session.id, uri: fileUri(filePath) },
      operation.operationId,
    );
    session.documentVersions.delete(fileUri(filePath));
    operation.succeeded();
  } catch (reason) {
    operation.failed(reason);
    throw reason;
  }
}

export function getLspSessionSnapshot(args: {
  filePath: string;
  sessionFilePath?: string;
}): LspSessionSnapshot | null {
  const attachment = fileSessions.get(fileKey(args.sessionFilePath ?? args.filePath));
  if (!attachment) return null;
  return snapshotForSession(attachment.session);
}

export function getLspWorkspaceSessionSnapshot(args: {
  workspacePath: string;
  languageId: string;
}): LspSessionSnapshot | null {
  const session = sessions.get(sessionKey(args.workspacePath, args.languageId));
  return session ? snapshotForSession(session) : null;
}

function snapshotForSession(session: Session): LspSessionSnapshot {
  return {
    id: session.id,
    workspacePath: session.workspacePath,
    languageId: session.languageId,
    phase: session.lifecycle.phase,
    operationId: session.lifecycle.operationId,
    featureState:
      session.featureState.phase === "known"
        ? featureSnapshot(session.featureState.features)
        : featureSnapshot(),
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
    const operation = new LspOperationLog("fileDetach", crypto.randomUUID(), {
      filePath: args.filePath,
    });
    const attachmentId =
      typeof args.attachmentId === "string" && args.attachmentId.length > 0
        ? args.attachmentId
        : undefined;
    try {
      const session = await sessionForStoppingFile(args.filePath, attachmentId);
      if (!session) {
        operation.cancelled("attachment-not-owned");
        return undefined as T;
      }
      if (!detachFile(session, args.filePath, attachmentId)) {
        operation.cancelled("stale-attachment");
        return undefined as T;
      }
      // Keep workspace-scoped language servers (e.g. JDTLS) alive as long as
      // the workspace is open. Stopping them per-file forces a slow cold-start
      // the next time any Java file in the workspace is accessed.
      if (session.files.size === 0 && session.languageId !== "java") {
        await stopSession(session);
      } else {
        persistSessions();
      }
      operation.succeeded({ sessionId: session.id });
      return undefined as T;
    } catch (reason) {
      operation.failed(reason);
      throw reason;
    }
  }
  if (command === "lsp_document_open") {
    const session = sessionForFile(args.filePath, args.attachmentId);
    await synchronizeDocument("documentOpen", session, args.filePath, {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      text: args.content ?? "",
    });
    return undefined as T;
  }
  if (command === "lsp_document_change") {
    const session = sessionForFile(args.filePath, args.attachmentId);
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
    await synchronizeDocument("documentChange", session, args.filePath, {
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
    const session = sessionForFile(args.filePath, args.attachmentId);
    await synchronizeDocument("documentSave", session, args.filePath, {
      sessionId: session.id,
      uri: fileUri(args.filePath),
      languageId: args.languageId ?? session.languageId,
      text: args.content ?? "",
    });
    return undefined as T;
  }
  if (command === "lsp_document_close") {
    const session = sessionForFile(args.filePath, args.attachmentId);
    await closeDocument(session, args.filePath);
    return undefined as T;
  }
  if (command === "lsp_workspace_files_changed") {
    const workspacePath = String(args.workspacePath ?? "");
    const languageId = String(args.languageId ?? "java");
    const session = sessions.get(sessionKey(workspacePath, languageId));
    if (!session || isSessionTerminal(session.lifecycle)) return undefined as T;
    const operation = new LspOperationLog("workspaceFilesChanged", crypto.randomUUID(), {
      sessionId: session.id,
      workspacePath,
      languageId,
    });
    try {
      const changes = Array.isArray(args.changes)
        ? args.changes.map((change: JsonRecord) => ({
            uri: fileUri(String(change.path ?? "")),
            kind: change.kind,
          }))
        : [];
      await core(
        "lsp.workspaceFilesChanged",
        { sessionId: session.id, changes },
        operation.operationId,
      );
      operation.succeeded({ changeCount: changes.length });
      return undefined as T;
    } catch (reason) {
      operation.failed(reason);
      throw reason;
    }
  }
  if (command === "java_navigation_markers") {
    const session = sessionForFile(args.sessionFilePath ?? args.filePath);
    const uri = typeof args.documentUri === "string" ? args.documentUri : fileUri(args.filePath);
    return (await requestOperation(
      session,
      {
        sessionId: session.id,
        uri,
        documentVersion: session.documentVersions.get(uri),
      },
      "java.navigationMarkers",
    )) as T;
  }
  if (command === "java_resolve_navigation") {
    const session = sessionForFile(args.sessionFilePath ?? args.filePath);
    const uri = typeof args.documentUri === "string" ? args.documentUri : fileUri(args.filePath);
    const result = await requestOperation(
      session,
      {
        sessionId: session.id,
        uri,
        line: args.line,
        utf16Column: args.character ?? 0,
        direction: args.direction,
        relation: args.relation,
        documentVersion: session.documentVersions.get(uri),
      },
      "java.resolveNavigation",
    );
    // Custom Java operations bypass unwrapResult, so normalize Core's UTF-16
    // position fields here before exposing standard LSP locations to the UI.
    return normalizeCoreValue(result) as T;
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
