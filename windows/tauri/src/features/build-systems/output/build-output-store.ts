import { create } from "zustand";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import type {
  BuildDiagnostic,
  BuildOperationIdentity,
  BuildOutputEventRef,
  BuildRunTerminal,
  BuildTestResults,
} from "./build-output-types";

export const BUILD_OUTPUT_STORE_KEY = "build-output";
export const MAX_OUTPUT_LINES = 4000;
/** UTF-8 bytes, including one record separator per retained row. */
export const MAX_OUTPUT_BYTES = 400_000;
/** Also bounds a live line that has never received a newline. */
export const MAX_LINE_BYTES = 2000;
export const MAX_DIAGNOSTICS = 2000;
export const MAX_TEST_CASES = 2000;
export const MAX_RESULT_BYTES = 400_000;
export const MAX_FIELD_BYTES = 2000;
export const MAX_OUTPUT_SESSIONS = 8;

export interface BuildOutputLine {
  seq: number;
  stream: "stdout" | "stderr";
  text: string;
  clipped: boolean;
}
export type BuildRunStatus = "running" | BuildRunTerminal["kind"];
export interface BuildOutputSessionState {
  identity: BuildOperationIdentity;
  status: BuildRunStatus;
  cancelling: boolean;
  cancelError: string | null;
  subscriptionError: string | null;
  lines: BuildOutputLine[];
  droppedLines: number;
  totalBytes: number;
  /** Only the last row can be extended; a stream switch closes the prior row. */
  openLine: boolean;
  nextSeq: number;
  diagnostics: BuildDiagnostic[];
  diagnosticsDropped: number;
  testResults: BuildTestResults | null;
  testsDropped: number;
  terminal: BuildRunTerminal | null;
}
export interface BuildOutputState {
  sessions: Record<string, BuildOutputSessionState>;
  actions: {
    /** Refuses a ninth concurrent run; only finished sessions can be evicted. */
    beginOperation: (sessionId: string, identity: BuildOperationIdentity) => boolean;
    appendChunk: (
      sessionId: string,
      ref: BuildOutputEventRef,
      stream: "stdout" | "stderr",
      text: string,
    ) => void;
    /** Core decoding may finish after the ordered terminal. */
    applyDiagnostics: (
      sessionId: string,
      ref: BuildOutputEventRef,
      diagnostics: BuildDiagnostic[],
    ) => void;
    applyTestResults: (
      sessionId: string,
      ref: BuildOutputEventRef,
      results: BuildTestResults,
    ) => void;
    complete: (sessionId: string, ref: BuildOutputEventRef, terminal: BuildRunTerminal) => void;
    beginStop: (sessionId: string, ref: BuildOutputEventRef) => boolean;
    stopFailed: (sessionId: string, ref: BuildOutputEventRef, message: string) => void;
    subscriptionFailed: (sessionId: string, ref: BuildOutputEventRef, message: string) => void;
    /** The coordinator calls this when its registry generation changes. */
    invalidateGeneration: (generation: number) => void;
    clear: (sessionId: string) => void;
    reset: () => void;
  };
}

const encoder = new TextEncoder();
const byteLength = (text: string) => encoder.encode(text).byteLength;

/** Read only the bounded prefix, without allocating UTF-8 for a huge chunk. */
function prefix(text: string, budget: number): { text: string; clipped: boolean } {
  let end = 0;
  let bytes = 0;
  for (const char of text) {
    const point = char.codePointAt(0)!;
    const size = point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
    if (bytes + size > budget) break;
    bytes += size;
    end += char.length;
  }
  return { text: text.slice(0, end), clipped: end < text.length };
}
function boundedText(text: string): string {
  const value = prefix(text, MAX_FIELD_BYTES - 3);
  return value.clipped ? `${value.text}…` : value.text;
}
// A clipped path could name a different file. Keep it inert instead.
const boundedPath = (path: string) =>
  byteLength(path.slice(0, MAX_FIELD_BYTES + 1)) <= MAX_FIELD_BYTES &&
  path.length <= MAX_FIELD_BYTES
    ? path
    : "";

function freshSession(identity: BuildOperationIdentity): BuildOutputSessionState {
  return {
    identity: { ...identity },
    status: "running",
    cancelling: false,
    cancelError: null,
    subscriptionError: null,
    lines: [],
    droppedLines: 0,
    totalBytes: 0,
    openLine: false,
    nextSeq: 0,
    diagnostics: [],
    diagnosticsDropped: 0,
    testResults: null,
    testsDropped: 0,
    terminal: null,
  };
}
function liveSession(state: BuildOutputState, sessionId: string, ref: BuildOutputEventRef) {
  const session = state.sessions[sessionId];
  const id = session?.identity;
  return id &&
    id.operationId === ref.operationId &&
    id.workspaceRoot === ref.workspaceRoot &&
    id.pluginId === ref.pluginId &&
    id.buildSystemId === ref.buildSystemId &&
    id.root === ref.root &&
    id.generation === ref.generation
    ? session
    : null;
}
function update(state: BuildOutputState, sessionId: string, session: BuildOutputSessionState) {
  return { sessions: { ...state.sessions, [sessionId]: session } };
}

/** Keep stream fragments in arrival order, including unterminated output. */
function append(session: BuildOutputSessionState, stream: BuildOutputLine["stream"], text: string) {
  const next = { ...session, lines: [...session.lines] };
  let offset = 0;
  while (offset < text.length) {
    const newline = text.indexOf("\n", offset);
    const end = newline < 0 ? text.length : newline;
    const last = next.lines[next.lines.length - 1];
    const extendsLast = next.openLine && last?.stream === stream;
    const previous = extendsLast ? last : undefined;
    const raw = (previous?.text ?? "") + text.slice(offset, end);
    const value = previous?.clipped
      ? { text: previous.text, clipped: true }
      : prefix(newline >= 0 && raw.endsWith("\r") ? raw.slice(0, -1) : raw, MAX_LINE_BYTES);
    const line = { seq: previous?.seq ?? next.nextSeq++, stream, ...value };
    if (previous) {
      next.lines[next.lines.length - 1] = line;
      next.totalBytes -= byteLength(previous.text) + 1;
    } else next.lines.push(line);
    next.totalBytes += byteLength(line.text) + 1;
    next.openLine = newline < 0;
    while (next.lines.length > MAX_OUTPUT_LINES || next.totalBytes > MAX_OUTPUT_BYTES) {
      const evicted = next.lines.shift()!;
      next.totalBytes -= byteLength(evicted.text) + 1;
      next.droppedLines += 1;
    }
    offset = newline < 0 ? text.length : newline + 1;
  }
  return next;
}

/** Presentation-only bounds; Core remains the sole decoder and summary owner. */
function boundedRows<T>(rows: T[], limit: number, project: (row: T) => T) {
  const kept: T[] = [];
  let bytes = 0;
  for (let index = 0; index < Math.min(rows.length, limit); index += 1) {
    const row = project(rows[index]!);
    const size = byteLength(JSON.stringify(row)) + 1;
    if (bytes + size > MAX_RESULT_BYTES) break;
    bytes += size;
    kept.push(row);
  }
  return { kept, dropped: rows.length - kept.length };
}

const createBuildOutputStore = () =>
  create<BuildOutputState>()((set) => ({
    sessions: {},
    actions: {
      beginOperation: (sessionId, identity) => {
        // Identity strings are retained verbatim for matching, never clipped.
        if (
          Object.values(identity).some(
            (value) => typeof value === "string" && value.length > 8192,
          ) ||
          byteLength(JSON.stringify(identity)) > 16_384 ||
          !Number.isSafeInteger(identity.generation)
        )
          return false;
        let accepted = false;
        set((state) => {
          const sessions = { ...state.sessions };
          if (!sessions[sessionId] && Object.keys(sessions).length >= MAX_OUTPUT_SESSIONS) {
            const finished = Object.keys(sessions).find((id) => sessions[id]!.status !== "running");
            if (!finished) return state;
            delete sessions[finished];
          }
          sessions[sessionId] = freshSession(identity);
          accepted = true;
          return { sessions };
        });
        return accepted;
      },
      appendChunk: (sessionId, ref, stream, text) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          return !session || session.status !== "running" || !text
            ? state
            : update(state, sessionId, append(session, stream, text));
        }),
      applyDiagnostics: (sessionId, ref, diagnostics) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          if (!session || session.status === "failedToStart") return state;
          const { kept, dropped } = boundedRows(diagnostics, MAX_DIAGNOSTICS, (row) => ({
            ...row,
            path: boundedPath(row.path),
            message: boundedText(row.message),
          }));
          return update(state, sessionId, {
            ...session,
            diagnostics: kept,
            diagnosticsDropped: dropped,
          });
        }),
      applyTestResults: (sessionId, ref, results) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          if (!session || session.status === "failedToStart") return state;
          const { kept, dropped } = boundedRows(results.tests, MAX_TEST_CASES, (row) => ({
            ...row,
            suite: boundedText(row.suite),
            case: boundedText(row.case),
            message: row.message == null ? row.message : boundedText(row.message),
            path: row.path == null ? row.path : boundedPath(row.path),
          }));
          return update(state, sessionId, {
            ...session,
            testsDropped: dropped,
            testResults: { tests: kept, summary: { ...results.summary }, success: results.success },
          });
        }),
      complete: (sessionId, ref, terminal) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          if (!session || session.status !== "running") return state;
          return update(state, sessionId, {
            ...session,
            status: terminal.kind,
            terminal: {
              ...terminal,
              message: terminal.message == null ? terminal.message : boundedText(terminal.message),
            },
            cancelling: false,
            cancelError: null,
            openLine: false,
          });
        }),
      beginStop: (sessionId, ref) => {
        let accepted = false;
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          if (!session || session.status !== "running" || session.cancelling) return state;
          accepted = true;
          return update(state, sessionId, { ...session, cancelling: true, cancelError: null });
        });
        return accepted;
      },
      stopFailed: (sessionId, ref, message) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          return !session || session.status !== "running" || !session.cancelling
            ? state
            : update(state, sessionId, {
                ...session,
                cancelling: false,
                cancelError: boundedText(message),
              });
        }),
      subscriptionFailed: (sessionId, ref, message) =>
        set((state) => {
          const session = liveSession(state, sessionId, ref);
          return !session
            ? state
            : update(state, sessionId, { ...session, subscriptionError: boundedText(message) });
        }),
      invalidateGeneration: (generation) =>
        set((state) => ({
          sessions: Object.fromEntries(
            Object.entries(state.sessions).filter(
              ([, session]) => session.identity.generation === generation,
            ),
          ),
        })),
      clear: (sessionId) =>
        set((state) => {
          const sessions = { ...state.sessions };
          delete sessions[sessionId];
          return { sessions };
        }),
      reset: () => set({ sessions: {} }),
    },
  }));
export const useBuildOutputStore = createWorkspaceScopedStore(
  BUILD_OUTPUT_STORE_KEY,
  createBuildOutputStore,
);
