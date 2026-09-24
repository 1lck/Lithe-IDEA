import { readDocumentFile, type DocumentReadDetails, type FileEncoding } from "@/platform/document-files";
import { decideDocumentLifecycle, type DocumentLifecycleState } from "@/platform/document-lifecycle";
import { frontendTrace } from "@/utils/frontend-trace";

export type ExternalBufferChangeResult = "reloaded" | "conflict" | "ignored" | "failed" | "deferred";
export interface DocumentBufferSnapshot {
  bufferId: string;
  path: string;
  lifecycle: DocumentLifecycleState;
  baseline: string | null;
  diskIdentity?: string;
  readEncoding?: FileEncoding;
  /** @deprecated Legacy snapshot field. */
  encoding?: FileEncoding;
  externalContent?: string | null;
  externalIdentity?: string;
}
export interface DocumentBufferOwner {
  getSnapshot: () => DocumentBufferSnapshot | null;
  applyLifecycle: (state: DocumentLifecycleState) => void;
  replaceWithDiskContent: (content: string, details?: Pick<DocumentReadDetails, "encoding" | "identity">) => void;
  observeConflict: (content: string | null, identity?: string) => void;
  reportFailure?: () => void;
  acknowledgeDisk: (content: string | null, identity?: string) => void;
}
export interface ExternalChangeWorkflowDependencies {
  decide?: typeof decideDocumentLifecycle;
  readFile?: typeof readDocumentFile;
  readDetails?: (path: string, encoding?: FileEncoding) => Promise<DocumentReadDetails | null>;
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
    const details = dependencies.readDetails
      ? await dependencies.readDetails(source.path, source.readEncoding ?? source.encoding)
      : null;
    const content = dependencies.readDetails ? details?.content ?? null : await (dependencies.readFile ?? readDocumentFile)(source.path);
    const identity = details?.identity;
    let latest = owner.getSnapshot();
    if (!latest || latest.path !== source.path) return "ignored";
    if (latest.lifecycle.status === "saving") return "deferred";
    if (latest.baseline !== source.baseline || latest.diskIdentity !== source.diskIdentity ||
        (latest.readEncoding ?? latest.encoding) !== (source.readEncoding ?? source.encoding)) return "deferred";
    if (identity && latest.diskIdentity && identity === latest.diskIdentity) return "ignored";
    if (!identity && content === latest.baseline) return "ignored";
    const observed = latest;
    const decision = await decide(latest.lifecycle, { type: content === null ? "diskConflict" : "externalChanged" }, { operationId });
    latest = owner.getSnapshot();
    if (!latest || latest.path !== source.path) return "ignored";
    if (!sameSnapshot(latest, observed)) return "deferred";
    if (decision.action === "reloadFromDisk" && content !== null) {
      owner.replaceWithDiskContent(content, details ?? undefined);
      return "reloaded";
    }
    if (decision.action === "showConflict") {
      owner.observeConflict(content, identity);
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
      const details = dependencies.readDetails
        ? await dependencies.readDetails(source.path, source.readEncoding ?? source.encoding)
        : null;
      const content = dependencies.readDetails ? details?.content ?? null : await (dependencies.readFile ?? readDocumentFile)(source.path);
      const latest = owner.getSnapshot();
      if (content === null || !latest || !sameSnapshot(source, latest)) return;
      owner.replaceWithDiskContent(content, details ?? undefined);
    } else {
      if (source.externalContent === undefined) return;
      const decision = await decide(source.lifecycle, { type: "keepEditor" }, { operationId });
      const latest = owner.getSnapshot();
      if (!latest || !sameSnapshot(source, latest) || latest.externalContent !== source.externalContent) return;
      owner.acknowledgeDisk(source.externalContent, source.externalIdentity);
      owner.applyLifecycle(decision.state);
    }
  } catch (error) {
    owner.reportFailure?.();
    (dependencies.trace ?? trace)("error", "conflict-resolution:failed", source, operationId, { error: String(error) });
  }
}

function sameSnapshot(left: DocumentBufferSnapshot, right: DocumentBufferSnapshot) {
  return left.bufferId === right.bufferId && left.path === right.path && left.baseline === right.baseline &&
    left.lifecycle.revision === right.lifecycle.revision && left.lifecycle.status === right.lifecycle.status &&
    left.diskIdentity === right.diskIdentity && left.externalIdentity === right.externalIdentity &&
    (left.readEncoding ?? left.encoding) === (right.readEncoding ?? right.encoding);
}
function trace(level: "info" | "warn" | "error", message: string, snapshot: DocumentBufferSnapshot, operationId: string, payload: Record<string, unknown> = {}) {
  frontendTrace(level, "document.lifecycle", message, { operationID: operationId, bufferId: snapshot.bufferId, path: snapshot.path, ...payload });
}
