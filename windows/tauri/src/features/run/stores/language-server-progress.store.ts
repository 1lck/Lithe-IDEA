import { createStore } from "zustand/vanilla";
import { useStore } from "zustand";

/**
 * Language-server work the user can wait on. Core reports both kinds as log
 * events: the Java import as one aggregated snapshot per meaningful change
 * (`Java workspace import progress`), and work after readiness as the raw LSP
 * `$/progress` notification. Phase, project and task texts come from the
 * language server and are shown as diagnostics, not translated.
 */
export const JAVA_IMPORT_PROGRESS_MESSAGE = "Java workspace import progress";
export const WORK_DONE_PROGRESS_MESSAGE = "$/progress";

export interface ImportProgress {
  percent?: number;
  phase?: string;
  currentProject?: string;
  downloadArtifact?: string;
  downloadedBytes?: number;
  totalBytes?: number;
}

export interface BackgroundTask {
  token: string;
  title?: string;
  message?: string;
  percent?: number;
}

export interface LanguageServerProgress {
  sessionId: string;
  root: string;
  languageId: string;
  importProgress?: ImportProgress;
  tasks: BackgroundTask[];
}

const rootKey = (root: string) => root.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

export const languageServerProgressStore = createStore<{
  sessions: Record<string, LanguageServerProgress>;
}>(() => ({ sessions: {} }));

type JsonRecord = Record<string, unknown>;

function record(value: unknown): JsonRecord | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as JsonRecord) : null;
}

function parseDetail(detail: string | undefined): JsonRecord | null {
  if (!detail?.startsWith("{")) return null;
  try {
    return record(JSON.parse(detail));
  } catch {
    return null;
  }
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function count(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function percent(value: unknown): number | undefined {
  const number = count(value);
  return number === undefined ? undefined : Math.min(100, Math.round(number));
}

export function parseImportProgress(detail: string | undefined): ImportProgress | null {
  const value = parseDetail(detail);
  if (!value) return null;
  return {
    percent: percent(value.progressPercent),
    phase: text(value.phase),
    currentProject: text(value.currentProject),
    downloadArtifact: text(value.downloadArtifact),
    downloadedBytes: count(value.downloadedBytes),
    totalBytes: count(value.totalBytes),
  };
}

/** Applies one `$/progress` notification to the running tasks of a session. */
export function applyWorkDoneProgress(
  tasks: readonly BackgroundTask[],
  detail: string | undefined,
): readonly BackgroundTask[] {
  const params = parseDetail(detail);
  const value = record(params?.value);
  const rawToken = params?.token;
  if (!value || (typeof rawToken !== "string" && typeof rawToken !== "number")) return tasks;
  const token = String(rawToken);
  const others = tasks.filter((task) => task.token !== token);
  if (value.kind === "end") return others.length === tasks.length ? tasks : others;
  if (value.kind !== "begin" && value.kind !== "report") return tasks;
  const previous = tasks.find((task) => task.token === token);
  // A report without a begin still describes running work: its begin may
  // have arrived while Core folded notifications into the import snapshot.
  const next: BackgroundTask = {
    token,
    title: text(value.title) ?? previous?.title,
    message: text(value.message) ?? (value.kind === "begin" ? undefined : previous?.message),
    percent: percent(value.percentage) ?? (value.kind === "begin" ? undefined : previous?.percent),
  };
  return previous ? tasks.map((task) => (task.token === token ? next : task)) : [...tasks, next];
}

function updateSession(
  sessionId: string,
  root: string,
  languageId: string,
  update: (entry: LanguageServerProgress) => LanguageServerProgress,
) {
  languageServerProgressStore.setState((state) => {
    const previous = state.sessions[sessionId] ?? { sessionId, root, languageId, tasks: [] };
    const next = update(previous);
    return next === previous ? state : { sessions: { ...state.sessions, [sessionId]: next } };
  });
}

/** Records a Core log event when it carries language-server progress. */
export function recordLanguageServerProgress(
  session: { id: string; workspacePath: string; languageId: string },
  message: string | undefined,
  detail: string | undefined,
) {
  if (message === JAVA_IMPORT_PROGRESS_MESSAGE) {
    const importProgress = parseImportProgress(detail);
    if (!importProgress) return;
    updateSession(session.id, session.workspacePath, session.languageId, (entry) => ({
      ...entry,
      importProgress,
    }));
  } else if (message === WORK_DONE_PROGRESS_MESSAGE) {
    updateSession(session.id, session.workspacePath, session.languageId, (entry) => {
      const tasks = applyWorkDoneProgress(entry.tasks, detail);
      return tasks === entry.tasks ? entry : { ...entry, tasks: [...tasks] };
    });
  }
}

/** The import is over once the service is ready; tasks may keep running. */
export function finishLanguageServerImport(sessionId: string) {
  languageServerProgressStore.setState((state) => {
    const entry = state.sessions[sessionId];
    if (!entry?.importProgress) return state;
    return { sessions: { ...state.sessions, [sessionId]: { ...entry, importProgress: undefined } } };
  });
}

/** A stopped or failed session reports no further work, so nothing it began is still running. */
export function clearLanguageServerProgress(sessionId: string) {
  languageServerProgressStore.setState((state) => {
    if (!state.sessions[sessionId]) return state;
    const sessions = { ...state.sessions };
    delete sessions[sessionId];
    return { sessions };
  });
}

function sessionsForRoot(
  sessions: Record<string, LanguageServerProgress>,
  root: string,
): LanguageServerProgress[] {
  const key = rootKey(root);
  return Object.values(sessions).filter((entry) => rootKey(entry.root) === key);
}

export function getImportProgress(root: string, languageId: string): ImportProgress | undefined {
  return sessionsForRoot(languageServerProgressStore.getState().sessions, root).find(
    (entry) => entry.languageId === languageId && entry.importProgress,
  )?.importProgress;
}

const EMPTY: LanguageServerProgress[] = [];

export function useLanguageServerProgress(
  root: string | null | undefined,
): LanguageServerProgress[] {
  const sessions = useStore(languageServerProgressStore, (state) => state.sessions);
  if (!root) return EMPTY;
  return sessionsForRoot(sessions, root);
}
