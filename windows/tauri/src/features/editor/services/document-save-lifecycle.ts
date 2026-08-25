import {
  applyLocalDocumentEdit,
  decideDocumentLifecycle,
  DocumentLifecycleCoreError,
  type DocumentLifecycleDecision,
  type DocumentLifecycleState,
} from "@/platform/document-lifecycle";
import { frontendTrace } from "@/utils/frontend-trace";

export interface DocumentSaveContext {
  bufferId: string;
  path: string;
  operationId: string;
}

interface DocumentSaveLifecycleDependencies {
  decide?: typeof decideDocumentLifecycle;
}

/** Starts one save only when the shared state machine grants write ownership. */
export async function beginDocumentSave(
  state: DocumentLifecycleState,
  context: DocumentSaveContext,
  dependencies: DocumentSaveLifecycleDependencies = {},
): Promise<DocumentLifecycleDecision | null> {
  trace("info", "save:start", context, { revision: state.revision, status: state.status });
  let decision: DocumentLifecycleDecision;
  try {
    decision = await (dependencies.decide ?? decideDocumentLifecycle)(
      state,
      { type: "saveStarted", operationId: context.operationId },
      { operationId: context.operationId },
    );
  } catch (error) {
    traceDocumentSaveFailure(context, error);
    throw error;
  }
  if (decision.action !== "writeToDisk") {
    trace("info", "save:cancelled", context, { reason: decision.action });
    return null;
  }
  return decision;
}

/** Reduces a matching save completion and rejects stale operation results. */
export async function completeDocumentSave(
  state: DocumentLifecycleState,
  context: DocumentSaveContext,
  dependencies: DocumentSaveLifecycleDependencies = {},
): Promise<DocumentLifecycleDecision> {
  const decision = await (dependencies.decide ?? decideDocumentLifecycle)(
    state,
    { type: "saveSucceeded", operationId: context.operationId },
    { operationId: context.operationId },
  );
  trace("info", "save:success", context, {
    action: decision.action,
    revision: decision.state.revision,
    status: decision.state.status,
  });
  return decision;
}

/** Restores dirty ownership after a matching write failure. */
export async function failDocumentSave(
  state: DocumentLifecycleState,
  context: DocumentSaveContext,
  error: unknown,
  dependencies: DocumentSaveLifecycleDependencies = {},
): Promise<DocumentLifecycleDecision> {
  const decision = await (dependencies.decide ?? decideDocumentLifecycle)(
    state,
    { type: "saveFailed", operationId: context.operationId },
    { operationId: context.operationId },
  );
  trace("error", "save:failed", context, {
    action: decision.action,
    error: error instanceof Error ? error.message : String(error),
  });
  return decision;
}

/** Applies a granted save only while the same dirty snapshot lineage is current. */
export function mergeGrantedDocumentSave(
  decision: DocumentLifecycleDecision,
  latest: DocumentLifecycleState,
): DocumentLifecycleState | null {
  if (decision.action !== "writeToDisk" || decision.state.status !== "saving") return null;
  const granted = decision.state;

  if (
    latest.status === "saving" &&
    latest.operationId === granted.operationId &&
    latest.saveRevision === granted.saveRevision
  ) {
    return latest;
  }
  if (
    latest.status !== "dirty" ||
    latest.savedRevision !== granted.savedRevision ||
    latest.revision < granted.saveRevision
  ) {
    return null;
  }
  return { ...granted, revision: latest.revision };
}

/** Merges a Core terminal decision with edits made while its response was in flight. */
export function mergeTerminalDocumentSave(
  decision: DocumentLifecycleDecision,
  latest: DocumentLifecycleState,
  context: DocumentSaveContext,
  matchesSavedContent: boolean,
): DocumentLifecycleState | null {
  if (
    decision.action === "ignoreStaleResult" ||
    latest.status !== "saving" ||
    latest.operationId !== context.operationId ||
    latest.revision < decision.state.revision
  ) {
    return null;
  }
  if (latest.revision === decision.state.revision) return decision.state;
  return applyLocalDocumentEdit(decision.state, latest.revision, matchesSavedContent);
}

export function traceDocumentSaveFailure(context: DocumentSaveContext, error: unknown) {
  if (error instanceof DocumentLifecycleCoreError && error.code === "timed_out") {
    trace("warn", "save:timeout", context, { error: error.message });
    return;
  }
  if (error instanceof DocumentLifecycleCoreError && error.code === "cancelled") {
    trace("info", "save:cancelled", context, { reason: error.message });
    return;
  }
  trace("error", "save:failed", context, {
    error: error instanceof Error ? error.message : String(error),
  });
}

export function traceDocumentSaveCancellation(context: DocumentSaveContext, reason: string) {
  trace("info", "save:cancelled", context, { reason });
}

function trace(
  level: "info" | "warn" | "error",
  message: string,
  context: DocumentSaveContext,
  payload: Record<string, unknown>,
) {
  frontendTrace(level, "document.lifecycle", message, {
    operationID: context.operationId,
    bufferId: context.bufferId,
    path: context.path,
    ...payload,
  });
}
