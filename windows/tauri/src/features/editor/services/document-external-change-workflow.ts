import { readDocumentFile } from "@/platform/document-files";
import { decideDocumentLifecycle, type DocumentLifecycleState } from "@/platform/document-lifecycle";
import { frontendTrace } from "@/utils/frontend-trace";

export type ExternalBufferChangeResult = "reloaded" | "conflict" | "ignored" | "failed" | "deferred";
export interface DocumentBufferSnapshot {
  bufferId: string;
  path: string;
  lifecycle: DocumentLifecycleState;
  baseline: string | null;
  externalContent?: string | null;
}
export interface DocumentBufferOwner {
  getSnapshot: () => DocumentBufferSnapshot | null;
  applyLifecycle: (state: DocumentLifecycleState) => void;
  replaceWithDiskContent: (content: string) => void;
  observeConflict: (content: string | null) => void;
  reportFailure?: () => void;
  acknowledgeDisk: (content: string | null) => void;
}
export interface ExternalChangeWorkflowDependencies {
  decide?: typeof decideDocumentLifecycle;
  readFile?: typeof readDocumentFile;
  trace?: typeof trace;
}

/** Notifications are hints: compare real bytes before reloading or declaring a conflict. */
export async function handleExternalDocumentChange({ owner, operationId, dependencies = {} }: {
  owner: DocumentBufferOwner; operationId: string; dependencies?: ExternalChangeWorkflowDependencies;
}): Promise<ExternalBufferChangeResult> {
  const source = owner.getSnapshot();
  if (!source) return "ignored";
  if (source.lifecycle.status === "saving") return "deferred";
  const decide = dependencies.decide ?? decideDocumentLifecycle;
  try {
    const content = await (dependencies.readFile ?? readDocumentFile)(source.path);
    let latest = owner.getSnapshot();
    if (!latest || latest.path !== source.path) return "ignored";
    if (latest.lifecycle.status === "saving") return "deferred";
    if (latest.baseline !== source.baseline) return "deferred";
    if (content === latest.baseline) return "ignored";
    const observed = latest;
    const decision = await decide(latest.lifecycle, { type: content === null ? "diskConflict" : "externalChanged" }, { operationId });
    latest = owner.getSnapshot();
    if (!latest || latest.path !== source.path) return "ignored";
    if (!sameSnapshot(latest, observed)) return "deferred";
    if (decision.action === "reloadFromDisk" && content !== null) {
      owner.replaceWithDiskContent(content);
      return "reloaded";
    }
    if (decision.action === "showConflict") {
      owner.observeConflict(content);
      owner.applyLifecycle(decision.state);
      return "conflict";
    }
    return "ignored";
  } catch (error) {
    owner.reportFailure?.();
    (dependencies.trace ?? trace)("error", "external-change:failed", source, operationId, { error: String(error) });
    return "failed";
  }
}

/** The choice authorizes only the observed disk version, never a future overwrite. */
export async function resolveExternalDocumentConflict(owner: DocumentBufferOwner, resolution: "keepEditor" | "loadDisk", operationId: string, dependencies: ExternalChangeWorkflowDependencies = {}): Promise<void> {
  const source = owner.getSnapshot();
  if (!source || source.lifecycle.status !== "conflict") return;
  const decide = dependencies.decide ?? decideDocumentLifecycle;
  try {
    if (resolution === "loadDisk") {
      const content = await (dependencies.readFile ?? readDocumentFile)(source.path);
      const latest = owner.getSnapshot();
      if (content === null || !latest || !sameSnapshot(source, latest)) return;
      owner.replaceWithDiskContent(content);
    } else {
      if (source.externalContent === undefined) return;
      const decision = await decide(source.lifecycle, { type: "keepEditor" }, { operationId });
      const latest = owner.getSnapshot();
      if (!latest || !sameSnapshot(source, latest) || latest.externalContent !== source.externalContent) return;
      owner.acknowledgeDisk(source.externalContent);
      owner.applyLifecycle(decision.state);
    }
  } catch (error) {
    owner.reportFailure?.();
    (dependencies.trace ?? trace)("error", "conflict-resolution:failed", source, operationId, { error: String(error) });
  }
}

function sameSnapshot(left: DocumentBufferSnapshot, right: DocumentBufferSnapshot) {
  return left.bufferId === right.bufferId && left.path === right.path && left.baseline === right.baseline &&
    left.lifecycle.revision === right.lifecycle.revision && left.lifecycle.status === right.lifecycle.status;
}
function trace(level: "info" | "warn" | "error", message: string, snapshot: DocumentBufferSnapshot, operationId: string, payload: Record<string, unknown> = {}) {
  frontendTrace(level, "document.lifecycle", message, { operationID: operationId, bufferId: snapshot.bufferId, path: snapshot.path, ...payload });
}
