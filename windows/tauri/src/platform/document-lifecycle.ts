import { invoke } from "./tauri-core";

export type DocumentLifecycleState =
  | { status: "clean"; revision: number }
  | { status: "dirty"; revision: number; savedRevision: number }
  | {
      status: "saving";
      revision: number;
      savedRevision: number;
      saveRevision: number;
      operationId: string;
    }
  | { status: "conflict"; revision: number; savedRevision: number };

export type DocumentLifecycleEvent =
  | { type: "edited"; revision: number; matchesSavedContent: boolean }
  | { type: "saveStarted"; operationId: string }
  | { type: "saveSucceeded"; operationId: string }
  | { type: "saveFailed"; operationId: string }
  | { type: "externalChanged" }
  | { type: "reloadSucceeded"; revision: number }
  | { type: "keepEditor" }
  | { type: "loadDisk" };

export type DocumentLifecycleAction =
  | "none"
  | "writeToDisk"
  | "reloadFromDisk"
  | "showConflict"
  | "reportSaveFailure"
  | "ignoreStaleResult";

export interface DocumentLifecycleDecision {
  state: DocumentLifecycleState;
  action: DocumentLifecycleAction;
}

interface CoreEnvelope<T> {
  ok: boolean;
  data?: T;
  error?: { code?: string; message?: string; details?: string };
}

export class DocumentLifecycleCoreError extends Error {
  constructor(
    message: string,
    readonly code?: string,
    readonly details?: string,
  ) {
    super(details ? `${message}: ${details}` : message);
    this.name = "DocumentLifecycleCoreError";
  }
}

type DocumentLifecycleCoreExecutor = (request: string) => Promise<string>;

interface DocumentLifecycleDecisionOptions {
  operationId?: string;
  executeCore?: DocumentLifecycleCoreExecutor;
}

let requestSequence = 0;

/**
 * Calls the deterministic Rust reducer for persistence-boundary events. Local
 * typing uses `applyLocalDocumentEdit` so keystrokes never cross Tauri.
 */
export async function decideDocumentLifecycle(
  state: DocumentLifecycleState,
  event: DocumentLifecycleEvent,
  options?: DocumentLifecycleDecisionOptions,
): Promise<DocumentLifecycleDecision> {
  requestSequence += 1;
  const requestId = `document-lifecycle-${requestSequence}`;
  const operationId =
    options?.operationId ?? ("operationId" in event ? event.operationId : requestId);
  const request = JSON.stringify({
    id: requestId,
    operationId,
    timeoutMilliseconds: 5_000,
    command: "document.lifecycle",
    payload: { state, event },
  });
  const executeCore = options?.executeCore ?? executeDocumentLifecycleCore;
  const responseText = await executeCore(request);

  let envelope: CoreEnvelope<DocumentLifecycleDecision>;
  try {
    envelope = JSON.parse(responseText) as CoreEnvelope<DocumentLifecycleDecision>;
  } catch {
    throw new Error("Shared Core returned invalid document lifecycle JSON");
  }

  if (!envelope.ok || !envelope.data) {
    const message = envelope.error?.message ?? "Shared document lifecycle decision failed";
    throw new DocumentLifecycleCoreError(
      message,
      envelope.error?.code,
      envelope.error?.details,
    );
  }
  return envelope.data;
}

function executeDocumentLifecycleCore(request: string): Promise<string> {
  return invoke<string>("core_execute", { request });
}

/**
 * Mirrors only the high-frequency `edited` transition in the WebView. The
 * Rust reducer remains authoritative for saves, watcher events, and conflicts.
 */
export function applyLocalDocumentEdit(
  state: DocumentLifecycleState | undefined,
  revision: number,
  matchesSavedContent: boolean,
): DocumentLifecycleState {
  const current = state ?? { status: "clean", revision: Math.max(0, revision - 1) };
  if (current.status === "saving") {
    return { ...current, revision };
  }
  if (current.status === "conflict") {
    return { ...current, revision };
  }
  if (matchesSavedContent) {
    return { status: "clean", revision };
  }
  return {
    status: "dirty",
    revision,
    savedRevision: current.status === "dirty" ? current.savedRevision : current.revision,
  };
}

export function documentLifecycleIsDirty(state: DocumentLifecycleState | undefined): boolean {
  return state ? state.status !== "clean" : false;
}

/** Restores lifecycle state for sessions written before the shared contract existed. */
export function restoreDocumentLifecycle(
  state: DocumentLifecycleState | undefined,
  revision: number,
  isDirty: boolean,
): DocumentLifecycleState {
  if (state) return state;
  return isDirty
    ? { status: "dirty", revision, savedRevision: 0 }
    : { status: "clean", revision };
}
