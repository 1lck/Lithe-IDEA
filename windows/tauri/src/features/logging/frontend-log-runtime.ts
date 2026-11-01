import { invoke } from "@/platform/tauri-core";
import { listen } from "@tauri-apps/api/event";
import { getLogSettings, type LogSettingsSnapshot } from "./log-api";
import { startFpsLogging, type FpsLogEvent } from "./fps-monitor";

export type FrontendLogLevel = "debug" | "info" | "warn" | "error";

interface FrontendLogInput {
  level: FrontendLogLevel;
  scope: string;
  message: string;
  payload?: Record<string, unknown> | null;
}

const FORWARD_FAILURE_THRESHOLD = 3;
const FORWARD_BREAKER_COOLDOWN_MS = 5_000;
const SERIALIZED_ARGUMENT_LIMIT = 1_024;
const SERIALIZED_TOTAL_LIMIT = 3_000;
const SERIALIZED_MAX_DEPTH = 3;
const ERROR_STACK_FRAMES = 8;

/** Logs waiting for the next batch; beyond this, new logs are dropped and counted. */
const MAX_QUEUED_LOGS = 256;
/** Longest a queued log waits for the window to become idle before it is sent anyway. */
const FLUSH_IDLE_TIMEOUT_MS = 1_000;
let installed = false;
let diagnosticEnabled = false;
let serializing = false;
let consecutiveFailures = 0;
let suppressedFailures = 0;
let breakerOpenUntil = 0;
let queue: Array<{ input: FrontendLogInput; resolve: (forwarded: boolean) => void }> = [];
let flushScheduled = false;
let batchInFlight = false;
let stopFpsLogging: (() => void) | null = null;
let initializationPromise: Promise<LogSettingsSnapshot | null> | null = null;
let workspaceRoots: string[] = [];
const diagnosticListeners = new Set<(enabled: boolean) => void>();

const PATH_FIELD_NAMES = new Set([
  "path",
  "file_path",
  "root_folder_path",
  "root",
  "tab_path",
  "workspace",
  "workspace_folders",
  "workspace_root",
  "working_directory",
  "repository",
  "repo_path",
]);

const originalConsole = {
  warn: console.warn.bind(console),
  error: console.error.bind(console),
};

function snakeCaseKey(value: string) {
  return value
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^a-zA-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
}

function normalizePath(value: string) {
  return value.replace(/\\/g, "/").replace(/\/+$/, "");
}

function sanitizeStructuredPath(value: string) {
  const normalized = normalizePath(value);
  const normalizedLower = normalized.toLowerCase();
  const root = workspaceRoots.find((candidate) => {
    const rootLower = candidate.toLowerCase();
    return normalizedLower === rootLower || normalizedLower.startsWith(`${rootLower}/`);
  });
  if (root) {
    const relative = normalized.slice(root.length).replace(/^\/+/, "");
    return relative ? `<workspace>/${relative}` : "<workspace>";
  }
  return normalized.split("/").filter(Boolean).pop() ?? "<redacted_path>";
}

export function setFrontendLogWorkspaceRoots(roots: string[]) {
  workspaceRoots = [...new Set(roots.map(normalizePath).filter(Boolean))].sort(
    (left, right) => right.length - left.length,
  );
}

export function sanitizeFrontendLogPayload(payload?: Record<string, unknown>) {
  if (!payload) return null;
  return Object.fromEntries(
    Object.entries(payload).map(([key, value]) => {
      if (PATH_FIELD_NAMES.has(snakeCaseKey(key))) {
        if (typeof value === "string") return [key, sanitizeStructuredPath(value)];
        if (Array.isArray(value)) {
          return [
            key,
            value.map((entry) =>
              typeof entry === "string" ? sanitizeStructuredPath(entry) : entry,
            ),
          ];
        }
      }
      return [key, value];
    }),
  );
}

function truncate(value: string, limit: number) {
  if (value.length <= limit) return value;
  return `${value.slice(0, Math.max(0, limit - 18))}…[truncated]`;
}

function serializeUnknown(value: unknown, depth: number, seen: WeakSet<object>): string {
  try {
    if (value instanceof Error) {
      const stack = value.stack
        ?.split(/\r?\n/)
        .slice(0, ERROR_STACK_FRAMES + 1)
        .join("\\n");
      return truncate(
        `${value.name}: ${value.message}${stack ? ` ${stack}` : ""}`,
        SERIALIZED_ARGUMENT_LIMIT,
      );
    }
    if (typeof value === "string") return truncate(value, SERIALIZED_ARGUMENT_LIMIT);
    if (
      value === null ||
      value === undefined ||
      typeof value === "number" ||
      typeof value === "boolean"
    ) {
      return String(value);
    }
    if (typeof value === "bigint") return `${value}n`;
    if (typeof value === "symbol" || typeof value === "function") return String(value);
    if (depth >= SERIALIZED_MAX_DEPTH) return "[max-depth]";
    if (typeof value === "object") {
      if (seen.has(value)) return "[circular]";
      seen.add(value);
      if (typeof Element !== "undefined" && value instanceof Element) {
        return `<${value.tagName.toLowerCase()}>`;
      }
      if (Array.isArray(value)) {
        return `[${value
          .slice(0, 24)
          .map((entry) => serializeUnknown(entry, depth + 1, seen))
          .join(",")}]`;
      }
      const entries = Object.entries(value as Record<string, unknown>)
        .slice(0, 20)
        .map(([key, entry]) => `${key}:${serializeUnknown(entry, depth + 1, seen)}`);
      return `{${entries.join(",")}}`;
    }
  } catch {
    return "[unserializable]";
  }
  return "[unserializable]";
}

export function serializeConsoleArguments(values: unknown[]) {
  try {
    const seen = new WeakSet<object>();
    return truncate(
      values.map((value) => serializeUnknown(value, 0, seen)).join(" "),
      SERIALIZED_TOTAL_LIMIT,
    );
  } catch {
    return "[unserializable]";
  }
}

function invokeBatch(entries: FrontendLogInput[]) {
  return invoke<void>("frontend_trace_batch", {
    entries: entries.map((entry) => ({
      level: entry.level,
      scope: entry.scope,
      message: entry.message,
      payload: entry.payload ?? null,
    })),
  });
}

function scheduleWhenIdle(run: () => void) {
  if (typeof requestIdleCallback === "function") {
    requestIdleCallback(run, { timeout: FLUSH_IDLE_TIMEOUT_MS });
  } else {
    setTimeout(run, 0);
  }
}

let sendBatch = invokeBatch;
let scheduleBatch = scheduleWhenIdle;

/** Replaces the IPC transport and flush scheduling; returns a function restoring both. */
export function setFrontendLogTransportForTests(
  transport: typeof invokeBatch,
  schedule: (run: () => void) => void,
) {
  sendBatch = transport;
  scheduleBatch = schedule;
  return () => {
    sendBatch = invokeBatch;
    scheduleBatch = scheduleWhenIdle;
    queue = [];
    flushScheduled = false;
    batchInFlight = false;
    consecutiveFailures = 0;
    suppressedFailures = 0;
    breakerOpenUntil = 0;
  };
}

function scheduleFlush() {
  if (flushScheduled || batchInFlight) return;
  flushScheduled = true;
  scheduleBatch(() => {
    flushScheduled = false;
    flushFrontendLogs();
  });
}

/**
 * Sends every queued log in one IPC call. Logs are queued instead of sent one
 * by one because each call serializes its payload on the UI thread: language
 * servers log every request, and sending those individually added several
 * milliseconds to each file open.
 */
function flushFrontendLogs() {
  if (batchInFlight || queue.length === 0) return;
  const batch = queue;
  queue = [];
  batchInFlight = true;
  sendBatch(batch.map((entry) => entry.input))
    .then(() => {
      const recoveredFailures = consecutiveFailures + suppressedFailures;
      consecutiveFailures = 0;
      suppressedFailures = 0;
      breakerOpenUntil = 0;
      if (recoveredFailures > 0) {
        queue.push({
          input: {
            level: "warn",
            scope: "runtime.console",
            message: "frontend log forwarding recovered",
            payload: { failures: recoveredFailures },
          },
          resolve: () => {},
        });
      }
      for (const entry of batch) entry.resolve(true);
    })
    .catch(() => {
      consecutiveFailures += 1;
      if (consecutiveFailures >= FORWARD_FAILURE_THRESHOLD) {
        breakerOpenUntil = Date.now() + FORWARD_BREAKER_COOLDOWN_MS;
      }
      for (const entry of batch) entry.resolve(false);
    })
    .finally(() => {
      batchInFlight = false;
      if (queue.length > 0) scheduleFlush();
    });
}

export function submitFrontendLog(input: FrontendLogInput): Promise<boolean> {
  if (input.level === "debug" && !diagnosticEnabled) return Promise.resolve(false);

  if (breakerOpenUntil > Date.now() || queue.length >= MAX_QUEUED_LOGS) {
    suppressedFailures += 1;
    return Promise.resolve(false);
  }
  return new Promise((resolve) => {
    queue.push({ input, resolve });
    scheduleFlush();
  });
}

function forwardConsole(level: "warn" | "error", args: unknown[]) {
  if (serializing) return;
  serializing = true;
  try {
    const message = serializeConsoleArguments(args);
    void submitFrontendLog({ level, scope: "runtime.console", message });
  } finally {
    serializing = false;
  }
}

function installConsoleProxy() {
  console.warn = (...args: unknown[]) => {
    originalConsole.warn(...args);
    forwardConsole("warn", args);
  };
  console.error = (...args: unknown[]) => {
    originalConsole.error(...args);
    forwardConsole("error", args);
  };
}

function installUnhandledErrorCapture() {
  window.addEventListener("error", (event) => {
    void submitFrontendLog({
      level: "error",
      scope: "runtime.js",
      message: event.message || "Unhandled JavaScript error",
      payload: {
        filename: event.filename?.split(/[\\/]/).pop() ?? null,
        line: event.lineno || null,
        column: event.colno || null,
        stack: event.error instanceof Error ? serializeConsoleArguments([event.error]) : null,
      },
    });
  });
  window.addEventListener("unhandledrejection", (event) => {
    void submitFrontendLog({
      level: "error",
      scope: "runtime.js.rejection",
      message: "Unhandled promise rejection",
      payload: { reason: serializeConsoleArguments([event.reason]) },
    });
  });
}

function forwardFpsEvent(event: FpsLogEvent) {
  void submitFrontendLog(event);
}

export function setFrontendDiagnosticEnabled(enabled: boolean) {
  if (diagnosticEnabled === enabled) return;
  diagnosticEnabled = enabled;
  for (const listener of diagnosticListeners) listener(enabled);
}

export function isFrontendDiagnosticEnabled() {
  return diagnosticEnabled;
}

export function subscribeFrontendDiagnosticEnabled(listener: (enabled: boolean) => void) {
  diagnosticListeners.add(listener);
  listener(diagnosticEnabled);
  return () => diagnosticListeners.delete(listener);
}

export function initializeFrontendLogging() {
  if (installed) return initializationPromise ?? Promise.resolve(null);
  installed = true;
  installConsoleProxy();
  installUnhandledErrorCapture();
  // Queued logs would otherwise be lost when the window closes or reloads.
  window.addEventListener("pagehide", flushFrontendLogs);
  stopFpsLogging = startFpsLogging(forwardFpsEvent, isFrontendDiagnosticEnabled);
  void listen<LogSettingsSnapshot>("lithe-log-runtime-fallback", (event) => {
    setFrontendDiagnosticEnabled(event.payload.diagnostic_enabled);
    window.dispatchEvent(new CustomEvent("lithe-log-runtime-fallback", { detail: event.payload }));
  }).catch(() => {});
  initializationPromise = getLogSettings()
    .then((snapshot) => {
      setFrontendDiagnosticEnabled(snapshot.diagnostic_enabled);
      return snapshot;
    })
    .catch(() => null);
  return initializationPromise;
}

export function disposeFrontendLoggingForTests() {
  stopFpsLogging?.();
  stopFpsLogging = null;
}
