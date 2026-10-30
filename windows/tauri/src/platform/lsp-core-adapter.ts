import { assertPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import {
  getProjectPreparation,
  failProjectPreparation,
  beginProjectPreparation,
  updateProjectPreparation,
  clearProjectPreparation,
  type ProjectPreparation,
} from "@/features/run/stores/project-preparation.store";
import {
  clearLanguageServerProgress,
  finishLanguageServerImport,
  recordLanguageServerProgress,
} from "@/features/run/stores/language-server-progress.store";
import { emit } from "@tauri-apps/api/event";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { type JavaBuildReport } from "@/platform/java-launch-readiness";
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
// Core owns request deadlines and reports them as structured `requestTimeout`
// errors. The local timer only guards against a Core that stops answering, so
// it fires after Core's deadline instead of racing it.
const LSP_REQUEST_TIMEOUT_MS = 30_000;
// A Java project build includes waiting for JDT project configuration and for
// an earlier build; large Maven projects need minutes on a cold build.
const JAVA_BUILD_TIMEOUT_MS = 10 * 60_000;
const CORE_DEADLINE_GRACE_MS = 5_000;
const SESSION_CLEANUP_TIMEOUT_MS = 5_000;
const POLL_INTERVAL_MS = 20;

interface PendingOperation {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  progress?: (value: unknown) => void;
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
  /** Provider identity used to stop all sessions owned by a plugin. */
  providerId: string;
  pluginId?: string;
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
  providerId?: string;
  pluginId?: string;
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
  javaBuildReport?: JavaBuildReport;
}

interface RuntimeEvent {
  type: string;
  method?: string;
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
  mavenProfileProject?: {
    projectUri: string;
    status: string;
    errorDetails?: string;
  };
  mavenProfileTask?: string;
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
const startOwners = new Map<string, string>();
const providerGenerations = new Map<string, number>();
const workspaceGenerations = new Map<string, number>();
const buildProviderStops = new Map<string, Promise<void>>();
const sessionStops = new Map<string, Promise<void>>();
const stoppingSessionIds = new Set<string>();
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
      providerId: session.providerId,
      pluginId: session.pluginId,
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
        (stored.providerId !== undefined && typeof stored.providerId !== "string") ||
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
        providerId: stored.providerId ?? stored.languageId,
        pluginId: stored.pluginId,
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
      if (session.languageId === "java") beginProjectPreparation(session.workspacePath, session.id);
      for (const file of stored.files) attachFile(session, file, crypto.randomUUID());
    }
    for (const session of sessions.values()) {
      if (session.files.size === 0) {
        if (session.languageId === "java") clearProjectPreparation(session.workspacePath, session.id);
        removeSessionMappings(session);
      }
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

async function dispatchRuntimeEvent(event: RuntimeEvent, workspacePath?: string): Promise<void> {
  if (event.type === "log") {
    const level = event.level === "error" ? "error" : event.level === "warning" ? "warn" : "info";
    const structuredDetail = parseStructuredRuntimeDetail(event.detail);
    frontendTrace(level, "lsp.runtime", event.message ?? "Language-server log", {
      ...(structuredDetail ?? { detail: event.detail ?? null }),
      providerId: event.providerId,
      sessionId: event.sessionId,
    });
    if (event.message === "Java language service protocol initialized") {
      await emit("lsp://language-lifecycle", {
        providerId: event.providerId,
        sessionId: event.sessionId,
        workspacePath,
        phase: "serverConnected",
      });
      await emit("lsp://language-lifecycle", {
        providerId: event.providerId,
        sessionId: event.sessionId,
        workspacePath,
        phase: "projectImporting",
      });
    }
    if (event.mavenProfileProject) {
      await emit("lsp://maven-profile-project", {
        providerId: event.providerId,
        sessionId: event.sessionId,
        workspacePath,
        ...event.mavenProfileProject,
      });
    }
    if (event.mavenProfileTask) {
      await emit("lsp://maven-profile-task", {
        providerId: event.providerId,
        sessionId: event.sessionId,
        workspacePath,
        status: event.mavenProfileTask,
      });
    }
  }
  if (event.type === "stateChanged" && event.state === "failed") {
    await emit("lsp://server-crashed", {});
  }
}

function parseStructuredRuntimeDetail(detail: string | undefined): JsonRecord | null {
  if (!detail?.startsWith("{")) return null;
  try {
    const parsed = JSON.parse(detail);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as JsonRecord)
      : null;
  } catch {
    return null;
  }
}

function isInitializationTimeout(reason: unknown): boolean {
  const code = (reason as Error & { code?: string } | null)?.code;
  return code === "timed_out" || code === "initializeTimeout" || code === "serviceReadyTimeout";
}

async function dispatchSessionEvent(session: Session, event: RuntimeEvent): Promise<void> {
  if (event.type === "requestProgress" && event.operationId) {
    session.pending.get(event.operationId)?.progress?.(event.result);
    return;
  }
  if (event.type === "projectPreparation" && event.result && session.languageId === "java") {
    updateProjectPreparation(session.workspacePath, session.id, event.result as ProjectPreparation);
  }
  if (event.type === "stateChanged" && event.state === "failed" && session.languageId === "java") {
    failProjectPreparation(session.workspacePath, session.id);
  }
  if (event.type === "log") {
    recordLanguageServerProgress(session, event.message, event.detail);
  }
  if (event.type === "stateChanged" && event.state === "ready") {
    finishLanguageServerImport(session.id);
  }
  // A new process (including a recovery under the same session) never ends
  // the work of the previous one, so its tasks are dropped with it.
  if (
    event.type === "stateChanged" &&
    (event.state === "processStarting" || event.state === "failed" || event.state === "stopped")
  ) {
    clearLanguageServerProgress(session.id);
  }

  await dispatchRuntimeEvent(event, session.workspacePath);
  if (event.type === "stateChanged" && event.state) {
    const phase = event.state === "processStarting"
      ? "starting"
      : event.state === "initializing"
        ? event.providerId === "java" ? "projectImporting" : "starting"
        : event.state === "ready" ? "serviceReady" : event.state;
    await emit("lsp://language-lifecycle", {
      providerId: event.providerId,
      sessionId: event.sessionId,
      workspacePath: session.workspacePath,
      phase,
    });
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
  if (event.type === "semanticTokensRefresh") {
    await emit("lsp://semantic-tokens-refresh", {
      sessionId: session.id,
      workspacePath: session.workspacePath,
    });
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
    // Build operations register before submission. A cancelled/completed
    // operation must never retain a late reply or revive a progress stream.
    if (event.method?.startsWith("lithe/build/") || session.languageId.startsWith("buildProvider:")) return;
    session.completed.set(event.operationId, event);
    return;
  }
  session.pending.delete(event.operationId);
  if (event.error) {
    const error = new Error(event.error.message ?? "LSP request failed") as Error & {
      code?: string;
      javaBuildReport?: JavaBuildReport;
    };
    error.code = event.error.code;
    // Evidence behind a blocked Java launch travels with the failure so the
    // Run panel can explain it and offer the matching recovery.
    error.javaBuildReport = event.error.javaBuildReport;
    pending.reject(error);
  } else {
    pending.resolve(event.result);
  }
}

export interface CoreBuildProviderTarget {
  workspacePath: string;
  pluginId: string;
  buildSystemId: string;
}

function buildProviderSessionKey(target: CoreBuildProviderTarget): string {
  return `buildProvider:${target.pluginId}:${target.buildSystemId}`;
}

/** Starts a document-free backend through the same Core process/event runtime
 * as language servers. Native launch resolution remains the platform's job. */
export async function startCoreBuildProvider(target: CoreBuildProviderTarget, launch: {
  serverPath: string;
  serverArgs: string[];
  environment: Record<string, string>;
  initializationOptions?: unknown;
}): Promise<void> {
  const key = sessionKey(target.workspacePath, buildProviderSessionKey(target));
  if (buildProviderStops.has(key)) throw lspAdapterError("cancelled", "Build Provider is stopping.");
  await start({ ...launch, workspacePath: target.workspacePath, pluginId: target.pluginId,
    providerId: target.pluginId, languageId: buildProviderSessionKey(target) });
}

/** Stops only this plugin/build-system/workspace, including a late start. */
export async function stopCoreBuildProvider(target: CoreBuildProviderTarget): Promise<void> {
  const key = sessionKey(target.workspacePath, buildProviderSessionKey(target));
  let stopping = buildProviderStops.get(key);
  if (!stopping) {
    const pending = sessionStarts.get(key);
    stopping = (async () => {
      const current = sessions.get(key);
      if (current) await stopSession(current);
      if (pending) await pending.catch(() => undefined);
      const late = sessions.get(key);
      if (late) await stopSession(late);
    })().finally(() => { if (buildProviderStops.get(key) === stopping) buildProviderStops.delete(key); });
    buildProviderStops.set(key, stopping);
  }
  await stopping;
}

/** Submits an already planned public Build request. The host ID is registered
 * before IPC so progress/completion arriving before its acknowledgement is safe.
 * Cancellation affects this operation only, preserving other workspace users. */
export async function requestCoreBuildProvider<T>(target: CoreBuildProviderTarget, request: {
  method: string;
  params: unknown;
  timeoutMilliseconds: number;
  signal?: AbortSignal;
  onProgress?: (value: unknown) => void;
}): Promise<T> {
  assertPluginActive(target.pluginId);
  request.signal?.throwIfAborted();
  if (!Number.isSafeInteger(request.timeoutMilliseconds) || request.timeoutMilliseconds < 1 || request.timeoutMilliseconds > 3_600_000) {
    throw lspAdapterError("invalid_request", "Invalid Build Provider deadline.");
  }
  const session = sessionForWorkspace(target.workspacePath, buildProviderSessionKey(target));
  if (buildProviderStops.has(sessionKey(target.workspacePath, session.languageId))) {
    throw lspAdapterError("cancelled", "Build Provider is stopping.");
  }
  if (session.pluginId !== target.pluginId) throw lspAdapterError("invalid_request", "Build Provider ownership changed.");
  const operationId = crypto.randomUUID();
  return new Promise<T>((resolve, reject) => {
    let submitted = false, cancelled = false;
    const cancel = () => core("lsp.cancelOperation", { sessionId: session.id, operationId }, operationId)
      .catch(reason => frontendTrace("warn", "build.lifecycle", "request:cancelFailed", {
        sessionId: session.id, operationId, error: String(reason),
      }));
    const cleanup = () => {
      session.pending.delete(operationId);
      clearTimeout(timer);
      request.signal?.removeEventListener("abort", abort);
    };
    const fail = (error: Error) => { cleanup(); reject(error); };
    const abort = () => {
      cancelled = true;
      if (submitted) void cancel();
      fail(lspAdapterError("cancelled", "Build Provider request was cancelled."));
    };
    const timer = setTimeout(() => {
      cancelled = true;
      if (submitted) void cancel();
      fail(lspAdapterError("timed_out", "Build Provider request timed out."));
    }, request.timeoutMilliseconds + CORE_DEADLINE_GRACE_MS);
    session.pending.set(operationId, {
      resolve: value => {
        if (!value || typeof value !== "object" || !("value" in value)) {
          fail(lspAdapterError("invalid_response", "Core returned an invalid Build response envelope."));
          return;
        }
        cleanup(); resolve((value as { value: T }).value);
      },
      reject: fail,
      progress: value => {
        try { request.onProgress?.(value); }
        catch (error) {
          cancelled = true;
          if (submitted) void cancel();
          fail(error instanceof Error ? error : new Error(String(error)));
        }
      },
    });
    request.signal?.addEventListener("abort", abort, { once: true });
    void core<{ operationId: string }>("lsp.buildRequest", {
      sessionId: session.id, operationId, method: request.method, params: request.params,
      timeoutMilliseconds: request.timeoutMilliseconds,
    }, operationId).then(async result => {
      submitted = true;
      if (cancelled) { await cancel(); return; }
      if (result.operationId !== operationId) {
        await cancel();
        fail(lspAdapterError("invalid_response", "Core returned a different Build operation identity."));
      }
    }).catch(error => fail(error instanceof Error ? error : new Error(String(error))));
  });
}

/** One `textDocument/publishDiagnostics` payload as the editor receives it. */
export interface LspDiagnosticsPublication {
  uri: string;
  version?: number;
  diagnostics: unknown;
}

/** Payload of `lsp://diagnostics`: every document whose diagnostics changed in one Core drain. */
export interface LspDiagnosticsBatch {
  publications: LspDiagnosticsPublication[];
}

async function poll(session: Session, timeoutMilliseconds = 30_000): Promise<RuntimeEvent[]> {
  const response = await core<{ events: RuntimeEvent[]; projectPreparation?: ProjectPreparation }>("lsp.waitEvents", {
    sessionId: session.id,
    timeoutMilliseconds,
  });
  // A publication replaces the document's previous diagnostics, so a drain
  // only needs the newest one per URI. Delivering them as one event keeps a
  // workspace import, which publishes for thousands of files, from costing an
  // IPC round trip and a store update per file while requests wait behind them.
  const diagnostics = new Map<string, RuntimeEvent>();
  const flushDiagnostics = async () => {
    if (diagnostics.size === 0) return;
    const publications = [...diagnostics].map(([uri, event]) => ({
      uri,
      version: event.version,
      diagnostics: normalizeCoreValue(event.diagnostics ?? []),
    }));
    diagnostics.clear();
    await emit("lsp://diagnostics", { publications } satisfies LspDiagnosticsBatch);
  };
  for (const event of response.events) {
    if (event.type === "diagnostics") {
      if (event.uri) diagnostics.set(event.uri, event);
      continue;
    }
    // Diagnostics published before a lifecycle change reach the editor first,
    // as they did when each one was forwarded on its own.
    if (event.type === "stateChanged") await flushDiagnostics();
    await dispatchSessionEvent(session, event);
  }
  await flushDiagnostics();
  if (session.languageId === "java" && response.projectPreparation) {
    updateProjectPreparation(session.workspacePath, session.id, response.projectPreparation);
  }
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
    if (session.languageId === "java") failProjectPreparation(session.workspacePath, session.id);
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
  while (true) {
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
  if (session.languageId === "java") failProjectPreparation(session.workspacePath, session.id);
  await stopSession(session, true);
}

function sessionForFile(filePath: string, attachmentId?: string): Session {
  const attachment = fileSessions.get(fileKey(filePath));
  if (!attachment || (attachmentId !== undefined && attachment.id !== attachmentId)) {
    throw lspAdapterError("no_session", `No language-server session owns this file: ${filePath}`);
  }
  return attachment.session;
}

function sessionForWorkspace(workspacePath: string, languageId: string): Session {
  const session = sessions.get(sessionKey(workspacePath, languageId));
  if (!session || !isSessionReady(session.lifecycle)) {
    throw lspAdapterError(
      "no_session",
      `No ready ${languageId} language-server session owns this workspace: ${workspacePath}`,
    );
  }
  return session;
}

function parseDebugServerPort(value: unknown): number {
  const port =
    typeof value === "number"
      ? value
      : typeof value === "string" && /^\d+$/.test(value.trim())
        ? Number(value.trim())
        : Number.NaN;
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw lspAdapterError(
      "invalid_response",
      "The Java language service returned an invalid debug-server port.",
    );
  }
  return port;
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
    if (session.languageId === "java") failProjectPreparation(session.workspacePath, session.id);
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

async function createSession(args: JsonRecord, key: string, generation: number, workspaceGeneration: number): Promise<Session> {
  const workspacePath = String(args.workspacePath ?? "");
  const languageId = String(args.languageId ?? "plaintext");
  const providerId = String(args.providerId ?? languageId);
  const workspaceKey = normalizedPathKey(workspacePath);
  const assertCurrent = () => {
    if (args.pluginId) assertPluginActive(args.pluginId);
    if ((providerGenerations.get(providerId) ?? 0) !== generation) {
      throw new Error("Language server start was cancelled by its provider.");
    }
    if ((workspaceGenerations.get(workspaceKey) ?? 0) !== workspaceGeneration) {
      throw lspAdapterError("cancelled", "Workspace changed while its backend was starting.");
    }
  };
  assertCurrent();
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
        pluginId: args.pluginId ?? null,
        executablePath: args.serverPath,
        arguments: args.serverArgs ?? [],
        environment,
        rootUri: fileUri(workspacePath),
        workingDirectory: workspacePath,
        initializationOptions: args.initializationOptions ?? null,
        workspaceConfiguration: args.workspaceConfiguration ?? null,
        runtimeExecutablePath: args.runtimeExecutablePath ?? null,
        jdtlsLaunchResources: args.jdtlsLaunchResources ?? null,
        cacheDirectory: args.cacheDirectory ?? null,
        workspaceFingerprint: args.workspaceFingerprint ?? null,
        mavenContext: args.mavenContext ?? null,
        javaRuntimes: args.javaRuntimes ?? [],
        javaGradle: args.javaGradle ?? null,
        initializeTimeoutMilliseconds: INITIALIZE_TIMEOUT_MS,
        requestTimeoutMilliseconds: LSP_REQUEST_TIMEOUT_MS,
        javaBuildTimeoutMilliseconds: JAVA_BUILD_TIMEOUT_MS,
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
    providerId,
    pluginId: args.pluginId,
    files: new Set(),
    lifecycle: createSessionLifecycle(started.state ?? "initializing", operationId),
    eventPump: null,
    featureState: { phase: "unknown" },
    pending: new Map(),
    completed: new Map(),
    documentVersions: new Map(),
  };
  try {
    assertCurrent();
  } catch (reason) {
    await stopSession(session);
    throw reason;
  }
  sessions.set(key, session);
  if (session.languageId === "java") beginProjectPreparation(session.workspacePath, session.id);
  persistSessions();
  try {
    await waitUntilReady(session);
    assertCurrent();
  } catch (reason) {
    if (isInitializationTimeout(reason)) {
      const code = (reason as Error & { code?: string }).code;
      operation.timedOut({
        stage: code === "serviceReadyTimeout" ? "serviceReady" : "initialize",
        sessionId: session.id,
      });
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
): Promise<"ready" | "terminal"> {
  const operation = new LspOperationLog("sessionReadinessWait", crypto.randomUUID(), {
    sessionId: session.id,
    workspacePath: session.workspacePath,
    languageId: session.languageId,
  });
  while (true) {
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
}

async function resolveSession(args: JsonRecord, key: string, generation: number, workspaceGeneration: number): Promise<Session> {
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

  return createSession(args, key, generation, workspaceGeneration);
}

async function start(args: JsonRecord): Promise<void> {
  if (args.pluginId) assertPluginActive(args.pluginId);
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
        const providerId = String(args.providerId ?? languageId);
        const generation = providerGenerations.get(providerId) ?? 0;
        startOwners.set(key, providerId);
        const workspaceGeneration = workspaceGenerations.get(normalizedPathKey(workspacePath)) ?? 0;
        startPromise = resolveSession(args, key, generation, workspaceGeneration).then(async (resolved) => {
          if ((providerGenerations.get(providerId) ?? 0) !== generation) {
            await stopSession(resolved);
            throw new Error("Language server start was cancelled by its provider.");
          }
          if ((workspaceGenerations.get(normalizedPathKey(workspacePath)) ?? 0) !== workspaceGeneration) {
            await stopSession(resolved);
            throw lspAdapterError("cancelled", "Workspace changed while its backend was starting.");
          }
          return resolved;
        }).finally(() => {
          sessionStarts.delete(key);
          startOwners.delete(key);
        });
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

async function stopSession(session: Session, preservePreparation = false): Promise<void> {
  if (session.languageId === "java" && !preservePreparation) clearProjectPreparation(session.workspacePath, session.id);
  clearLanguageServerProgress(session.id);
  const key = sessionKey(session.workspacePath, session.languageId);
  stoppingSessionIds.add(session.id);
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
          throw new Error("Language server cleanup timed out.");
        } else {
          operation.succeeded();
        }
      })
      .catch((reason) => {
        operation.failed(reason);
        sessions.set(key, session);
        persistSessions();
        throw reason;
      })
      .finally(() => {
        stoppingSessionIds.delete(session.id);
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
  coreTimeoutMilliseconds = LSP_REQUEST_TIMEOUT_MS,
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
    }, coreTimeoutMilliseconds + CORE_DEADLINE_GRACE_MS);
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

/** A class JDT confirmed the JVM can launch, as normalized by Core. */
export interface JavaEntrypoint {
  sourcePath: string;
  mainClass: string;
  projectName?: string;
}

/** Core's `javaEntrypoints` answer (schema version 1). */
export interface JavaEntrypoints {
  schemaVersion: 1;
  entries: JavaEntrypoint[];
  diagnostics: Array<{ code: string; mainClass?: string; detail?: string }>;
}

export interface JavaTestRange {
  startLine: number;
  startUtf16Column: number;
  endLine: number;
  endUtf16Column: number;
}

/** One launchable `main` method JDT reported for a source file. */
export interface JavaMainMethod {
  mainClass: string;
  projectName?: string;
  /** Zero-based UTF-16 range of the method name. */
  range: JavaTestRange;
}

/** Core's normalized `javaMainMethods` answer (schema version 1). */
export interface JavaMainMethods {
  schemaVersion: 1;
  methods: JavaMainMethod[];
  diagnostics: Array<{ code: string; mainClass?: string }>;
}

/** One test class or method semantically identified by Java Test/JDT. */
export interface JavaTestItem {
  id: string;
  label: string;
  fullName: string;
  projectName: string;
  testKind: number;
  testLevel: number;
  jdtHandler?: string;
  sortText?: string;
  range?: JavaTestRange;
  children: JavaTestItem[];
}

/** Core's normalized `javaTestItems` answer (schema version 1). */
export interface JavaTestItems {
  schemaVersion: 1;
  items: JavaTestItem[];
  diagnostics: Array<{ code: string; detail?: string }>;
}

async function requestJavaEntrypoints(session: Session): Promise<JavaEntrypoints> {
  const value = normalizeCoreValue(
    await requestOperation(session, { sessionId: session.id, operation: "javaEntrypoints" }),
  ) as Partial<JavaEntrypoints> | null;
  if (value?.schemaVersion !== 1 || !Array.isArray(value.entries)) {
    throw lspAdapterError(
      "invalid_response",
      "The Java language service returned an invalid entry-point list.",
    );
  }
  return {
    schemaVersion: 1,
    entries: value.entries,
    diagnostics: Array.isArray(value.diagnostics) ? value.diagnostics : [],
  };
}

async function requestJavaTestItems(session: Session, filePath: string): Promise<JavaTestItems> {
  const value = normalizeCoreValue(
    await requestOperation(session, {
      sessionId: session.id,
      operation: "javaTestItems",
      uri: fileUri(filePath),
    }),
  ) as Partial<JavaTestItems> | null;
  if (value?.schemaVersion !== 1 || !Array.isArray(value.items)) {
    throw lspAdapterError(
      "invalid_response",
      "The Java language service returned an invalid test-item list.",
    );
  }
  return {
    schemaVersion: 1,
    items: value.items,
    diagnostics: Array.isArray(value.diagnostics) ? value.diagnostics : [],
  };
}

async function requestJavaMainMethods(
  session: Session,
  filePath: string,
): Promise<JavaMainMethods> {
  const value = normalizeCoreValue(
    await requestOperation(session, {
      sessionId: session.id,
      operation: "javaMainMethods",
      uri: fileUri(filePath),
    }),
  ) as Partial<JavaMainMethods> | null;
  if (value?.schemaVersion !== 1 || !Array.isArray(value.methods)) {
    throw lspAdapterError(
      "invalid_response",
      "The Java language service returned an invalid main-method list.",
    );
  }
  return {
    schemaVersion: 1,
    methods: value.methods,
    diagnostics: Array.isArray(value.diagnostics) ? value.diagnostics : [],
  };
}

/** Workspace-relative comparison key for an absolute path, or null outside it. */
function workspaceRelativeKey(workspacePath: string, filePath: string): string | null {
  const root = normalizedPathKey(workspacePath).replace(/\/+$/, "");
  const file = normalizedPathKey(filePath);
  return file.startsWith(`${root}/`) ? file.slice(root.length + 1) : null;
}

/** Comparison key for a workspace-relative path, folded like its workspace. */
function relativePathKey(workspacePath: string, relativePath: string): string {
  const normalized = relativePath.replace(/\\/g, "/");
  // Same rule as `normalizedPathKey`: drive and UNC workspaces fold case.
  return /^(?:[A-Za-z]:\/|\/\/)/.test(workspacePath.replace(/\\/g, "/"))
    ? normalized.toLowerCase()
    : normalized;
}

export const LSP_OPERATION_BY_COMMAND = {
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
} as const;

export const LSP_EXPLICITLY_UNAVAILABLE_COMMANDS = [
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
  if (command === "lsp_get_completions") payload.completionContext = args.completionContext;
  if (command === "lsp_rename") payload.newName = args.newName;
  if (command === "lsp_resolve_completion") payload.completionItem = args.completionItem;
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
      return { items: normalized.items ?? [], isIncomplete: normalized.isIncomplete === true };
    case "lsp_resolve_completion":
      return normalized.item ?? null;
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
  const key = fileKey(args.sessionFilePath ?? args.filePath);
  const attachment = fileSessions.get(key);
  const session = sessionForFile(args.sessionFilePath ?? args.filePath);
  const result = await requestOperation(session, semanticPayload(command, args, session));
  // A stopped/replaced attachment must not repaint the new session's document.
  if (fileSessions.get(key) !== attachment) {
    if (command === "lsp_get_semantic_tokens") return null;
    if (command === "lsp_get_completions") return { items: [], isIncomplete: false };
  }
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

export function ownsLspSession(sessionId: string): boolean {
  return stoppingSessionIds.has(sessionId) || [...sessions.values()].some((session) => session.id === sessionId);
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

/**
 * Pushes a declarative plugin's expanded `workspaceConfiguration` to the
 * running language server for this workspace and language (`effect:`
 * `immediate` settings). Returns whether a live session received it.
 */
export async function pushDeclarativeWorkspaceConfiguration(args: {
  workspacePath: string;
  languageId: string;
  configuration: unknown;
  pluginId: string;
}): Promise<boolean> {
  const session = sessions.get(sessionKey(args.workspacePath, args.languageId));
  if (!session || session.pluginId !== args.pluginId || !isSessionReady(session.lifecycle)) return false;
  assertPluginActive(args.pluginId);
  await core(
    "lsp.updateWorkspaceConfiguration",
    { sessionId: session.id, configuration: args.configuration },
    crypto.randomUUID(),
  );
  return true;
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
  if (command === "lsp_stop_for_provider") {
    const providerId = typeof args.providerId === "string" ? args.providerId : "";
    if (!providerId) return undefined as T;
    providerGenerations.set(providerId, (providerGenerations.get(providerId) ?? 0) + 1);
    const pending = [...sessionStarts.entries()]
      .filter(([key]) => startOwners.get(key) === providerId)
      .map(([, promise]) => promise);
    const matches = [...sessions.values()].filter((session) => session.providerId === providerId);
    await Promise.all(matches.map((session) => stopSession(session)));
    // A late Core response still owns a process. Its cancelled start cleans it
    // up before this barrier acknowledges that package files can be changed.
    await Promise.allSettled(pending);
    if ([...sessions.values()].some((session) => session.providerId === providerId)) {
      throw new Error("Plugin language server cleanup failed; package files must be preserved.");
    }
    return undefined as T;
  }
  if (command === "lsp_stop") {
    const workspaceKey = normalizedPathKey(args.workspacePath);
    workspaceGenerations.set(workspaceKey, (workspaceGenerations.get(workspaceKey) ?? 0) + 1);
    const pending = [...sessionStarts.entries()].filter(([key]) => key.startsWith(`${workspaceKey}:`)).map(([, promise]) => promise);
    const preparation = getProjectPreparation(args.workspacePath);
    if (preparation) clearProjectPreparation(args.workspacePath, preparation.sessionId);
    const matches = [...sessions.values()].filter(
      (session) =>
        normalizedPathKey(session.workspacePath) === normalizedPathKey(args.workspacePath),
    );
    await Promise.all(matches.map((session) => stopSession(session)));
    await Promise.allSettled(pending);
    const remaining = [...sessions.values()].filter(session => normalizedPathKey(session.workspacePath) === workspaceKey);
    await Promise.all(remaining.map(session => stopSession(session)));
    return undefined as T;
  }
  if (command === "lsp_retry_maven_profiles") {
    const requestedSessionId = typeof args.sessionId === "string" ? args.sessionId : undefined;
    const session = requestedSessionId
      ? [...sessions.values()].find(
          (candidate) => candidate.id === requestedSessionId && candidate.languageId === "java",
        )
      : [...sessions.values()].find(
          (candidate) =>
            candidate.languageId === "java" &&
            normalizedPathKey(candidate.workspacePath) === normalizedPathKey(args.workspacePath),
        );
    if (!session) throw new Error("No active Java language session for this workspace.");
    await core("lsp.retryMavenProfiles", { sessionId: session.id }, crypto.randomUUID());
    return undefined as T;
  }
  if (command === "lsp_update_maven_configuration") {
    // A running Java session takes Maven changes through JDT LS's own update
    // path. Without one there is nothing to update: the next start reads the
    // workspace's current Maven context.
    const session = [...sessions.values()].find(
      (candidate) =>
        candidate.languageId === "java" &&
        !isSessionTerminal(candidate.lifecycle) &&
        candidate.lifecycle.phase !== "stopping" &&
        candidate.lifecycle.phase !== "recovering" &&
        normalizedPathKey(candidate.workspacePath) === normalizedPathKey(args.workspacePath),
    );
    if (!session) return { kind: "noSession" } as T;
    const result = await core<JsonRecord>(
      "lsp.updateMavenConfiguration",
      {
        sessionId: session.id,
        mavenContext: args.mavenContext,
        reloadProjects: args.reloadProjects === true,
      },
      crypto.randomUUID(),
    );
    return { kind: "updated", ...result } as T;
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
    await core("lsp.saveDocument", {
      sessionId: session.id,
      uri: fileUri(args.filePath),
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
  if (command === "java_start_debug_session") {
    const session = sessionForWorkspace(String(args.workspacePath ?? ""), "java");
    const result = normalizeCoreValue(
      await requestOperation(session, {
        sessionId: session.id,
        operation: "executeCommand",
        command: {
          title: "Start Java Debug Server",
          command: "vscode.java.startDebugSession",
          arguments: [],
        },
      }),
    ) as JsonRecord;
    return parseDebugServerPort(result?.value) as T;
  }
  if (command === "java_entrypoints") {
    return (await requestJavaEntrypoints(
      sessionForWorkspace(String(args.workspacePath ?? ""), "java"),
    )) as T;
  }
  if (command === "java_test_items") {
    return (await requestJavaTestItems(
      sessionForWorkspace(String(args.workspacePath ?? ""), "java"),
      String(args.filePath ?? ""),
    )) as T;
  }
  if (command === "java_main_methods") {
    return (await requestJavaMainMethods(
      sessionForWorkspace(String(args.workspacePath ?? ""), "java"),
      String(args.filePath ?? ""),
    )) as T;
  }
  if (command === "java_build_service_update") {
    const session = sessionForWorkspace(String(args.workspacePath ?? ""), "java");
    const target = args.target as {
      mainClass: string;
      projectName?: string;
      modulePaths: string[];
      classPaths: string[];
    };
    const execute = async (
      command: string,
      arguments_: unknown[],
      timeout = LSP_REQUEST_TIMEOUT_MS,
    ) => {
      const result = normalizeCoreValue(
        await requestOperation(
          session,
          {
            sessionId: session.id,
            operation: "executeCommand",
            command: { title: "Update Java service", command, arguments: arguments_ },
          },
          "lsp.request",
          timeout,
        ),
      ) as JsonRecord;
      return result?.value;
    };
    // Omit scope so Java Debug Server detects test roots and test dependencies.
    const paths = await execute("vscode.java.resolveClasspath", [
      target.mainClass,
      target.projectName ?? "",
    ]);
    if (JSON.stringify(paths) !== JSON.stringify([target.modulePaths, target.classPaths])) {
      throw new Error("Runtime paths changed. Restart the service to use the new dependencies.");
    }
    const status = await execute(
      "vscode.java.buildWorkspace",
      [
        JSON.stringify({
          mainClass: target.mainClass,
          projectName: target.projectName,
          filePath: args.sourcePath,
          isFullBuild: false,
        }),
      ],
      JAVA_BUILD_TIMEOUT_MS,
    );
    if (Number(status) !== 1) throw new Error("Java compilation did not complete successfully.");
    return undefined as T;
  }
  if (command === "java_prepare_run_launch") {
    const workspacePath = String(args.workspacePath ?? "");
    const session = sessionForWorkspace(workspacePath, "java");
    // Core owns selection, the serialized build, and classpath resolution as
    // one operation. The host deadline covers all three bounded Core phases.
    return (await requestOperation(
      session,
      {
        sessionId: session.id,
        sourcePath: String(args.sourcePath ?? ""),
        mainClass: String(args.mainClass ?? ""),
      },
      "java.prepareLaunch",
      JAVA_BUILD_TIMEOUT_MS + 2 * LSP_REQUEST_TIMEOUT_MS,
    )) as T;
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
