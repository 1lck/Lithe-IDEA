import { readFileContent } from "@/features/file-system/controllers/file-operations";
import {
  decideDocumentLifecycle,
  type DocumentLifecycleState,
} from "@/platform/document-lifecycle";
import { frontendTrace } from "@/utils/frontend-trace";

export type ExternalBufferChangeResult = "reloaded" | "conflict" | "ignored" | "failed";

export interface DocumentBufferSnapshot {
  bufferId: string;
  path: string;
  lifecycle: DocumentLifecycleState;
}

export interface DocumentBufferOwner {
  getSnapshot: () => DocumentBufferSnapshot | null;
  applyLifecycle: (state: DocumentLifecycleState) => void;
  replaceWithDiskContent: (content: string) => void;
}

interface ExternalChangeWorkflowInput {
  owner: DocumentBufferOwner;
  operationId: string;
  dependencies?: ExternalChangeWorkflowDependencies;
}

export interface ExternalChangeWorkflowDependencies {
  decide?: typeof decideDocumentLifecycle;
  readFile?: typeof readFileContent;
  trace?: typeof trace;
}

/** Owns the external-change read and stale-result checks for one live document. */
export async function handleExternalDocumentChange({
  owner,
  operationId,
  dependencies = {},
}: ExternalChangeWorkflowInput): Promise<ExternalBufferChangeResult> {
  const initial = owner.getSnapshot();
  if (!initial) return "ignored";
  const decide = dependencies.decide ?? decideDocumentLifecycle;
  const readFile = dependencies.readFile ?? readFileContent;
  const log = dependencies.trace ?? trace;

  log("info", "external-change:start", initial, operationId, {
    status: initial.lifecycle.status,
  });

  try {
    let source = initial;
    let decision = await decide(
      source.lifecycle,
      { type: "externalChanged" },
      { operationId },
    );
    const latestAfterDecision = owner.getSnapshot();
    if (!latestAfterDecision) {
      log("info", "external-change:cancelled", source, operationId, {
        reason: "buffer-closed",
      });
      return "ignored";
    }
    if (!sameLifecycleSnapshot(latestAfterDecision, source)) {
      source = latestAfterDecision;
      decision = await decide(
        source.lifecycle,
        { type: "externalChanged" },
        { operationId },
      );
    }

    if (decision.action === "showConflict") {
      const latest = owner.getSnapshot();
      if (!latest) return "ignored";
      owner.applyLifecycle(conflictStateFor(latest.lifecycle));
      log("warn", "external-change:conflict", latest, operationId);
      return "conflict";
    }
    if (decision.action !== "reloadFromDisk") {
      log("info", "external-change:ignored", source, operationId, {
        action: decision.action,
      });
      return "ignored";
    }

    const diskContent = await readFile(source.path);
    const latestBeforeReload = owner.getSnapshot();
    if (!latestBeforeReload) {
      log("info", "external-change:cancelled", source, operationId, {
        reason: "buffer-closed-during-read",
      });
      return "ignored";
    }
    if (!sameLifecycleSnapshot(latestBeforeReload, source)) {
      const conflictDecision = await decide(
        latestBeforeReload.lifecycle,
        { type: "externalChanged" },
        { operationId },
      );
      if (conflictDecision.action === "showConflict") {
        const latestConflict = owner.getSnapshot();
        if (!latestConflict) return "ignored";
        owner.applyLifecycle(conflictStateFor(latestConflict.lifecycle));
        log("warn", "external-change:conflict", latestConflict, operationId, {
          reason: "edited-during-disk-read",
        });
        return "conflict";
      }
      return "ignored";
    }

    owner.replaceWithDiskContent(diskContent);
    log("info", "external-change:success", source, operationId, { outcome: "reloaded" });
    return "reloaded";
  } catch (error) {
    log("error", "external-change:failed", initial, operationId, {
      error: error instanceof Error ? error.message : String(error),
    });
    return "failed";
  }
}

/** Applies one explicit user choice without allowing a stale disk read to win. */
export async function resolveExternalDocumentConflict(
  owner: DocumentBufferOwner,
  resolution: "keepEditor" | "loadDisk",
  operationId: string,
  dependencies: ExternalChangeWorkflowDependencies = {},
): Promise<void> {
  const source = owner.getSnapshot();
  if (!source || source.lifecycle.status !== "conflict") return;
  const decide = dependencies.decide ?? decideDocumentLifecycle;
  const readFile = dependencies.readFile ?? readFileContent;
  const log = dependencies.trace ?? trace;

  log("info", "conflict-resolution:start", source, operationId, { resolution });
  try {
    const decision = await decide(
      source.lifecycle,
      { type: resolution },
      { operationId },
    );
    if (decision.action === "reloadFromDisk") {
      const diskContent = await readFile(source.path);
      const latest = owner.getSnapshot();
      if (!latest || !sameLifecycleSnapshot(latest, source)) {
        log("info", "conflict-resolution:cancelled", source, operationId, {
          reason: "document-changed-during-read",
        });
        return;
      }
      owner.replaceWithDiskContent(diskContent);
    } else {
      const latest = owner.getSnapshot();
      if (!latest) return;
      owner.applyLifecycle(
        sameLifecycleSnapshot(latest, source)
          ? decision.state
          : dirtyStateFor(latest.lifecycle),
      );
    }
    log("info", "conflict-resolution:success", source, operationId, { resolution });
  } catch (error) {
    log("error", "conflict-resolution:failed", source, operationId, {
      resolution,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

function sameLifecycleSnapshot(left: DocumentBufferSnapshot, right: DocumentBufferSnapshot) {
  return (
    left.bufferId === right.bufferId &&
    left.lifecycle.revision === right.lifecycle.revision &&
    left.lifecycle.status === right.lifecycle.status &&
    savedRevisionOf(left.lifecycle) === savedRevisionOf(right.lifecycle) &&
    (left.lifecycle.status === "saving" ? left.lifecycle.saveRevision : null) ===
      (right.lifecycle.status === "saving" ? right.lifecycle.saveRevision : null) &&
    (left.lifecycle.status === "saving" ? left.lifecycle.operationId : null) ===
      (right.lifecycle.status === "saving" ? right.lifecycle.operationId : null)
  );
}

function conflictStateFor(state: DocumentLifecycleState): DocumentLifecycleState {
  return { status: "conflict", revision: state.revision, savedRevision: savedRevisionOf(state) };
}

function dirtyStateFor(state: DocumentLifecycleState): DocumentLifecycleState {
  return { status: "dirty", revision: state.revision, savedRevision: savedRevisionOf(state) };
}

function savedRevisionOf(state: DocumentLifecycleState): number {
  return state.status === "clean" ? state.revision : state.savedRevision;
}

function trace(
  level: "info" | "warn" | "error",
  message: string,
  snapshot: DocumentBufferSnapshot,
  operationId: string,
  payload: Record<string, unknown> = {},
) {
  frontendTrace(level, "document.lifecycle", message, {
    operationID: operationId,
    bufferId: snapshot.bufferId,
    path: snapshot.path,
    ...payload,
  });
}
