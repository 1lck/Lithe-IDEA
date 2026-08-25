import {
  resolveJavaWorkspacePolicy,
  type JavaWorkspacePolicy,
} from "@/platform/java-workspace-policy";
import { LspOperationLog } from "@/platform/lsp-session-lifecycle";
import { getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";

type FileChangeKind = "created" | "changed" | "deleted";

interface ScheduledChange {
  path: string;
  kind: FileChangeKind;
  includeSource: boolean;
}

interface OperationLog {
  succeeded(details?: Record<string, unknown>): void;
  failed(reason: unknown, details?: Record<string, unknown>): void;
  cancelled(reason: string, details?: Record<string, unknown>): void;
}

type TimerHandle = ReturnType<typeof setTimeout>;
type TimerCallback = () => void | Promise<void>;

type ChangeBatchState =
  | { phase: "scheduled"; timer: TimerHandle }
  | { phase: "flushing" }
  | { phase: "cancelled" }
  | { phase: "completed" };

interface ChangeBatchOwner {
  key: string;
  workspaceId: string;
  workspacePath: string;
  operationId: string;
  changes: Map<string, ScheduledChange>;
  operation: OperationLog;
  state: ChangeBatchState;
}

interface JavaWorkspaceChangeSchedulerDependencies {
  resolvePolicy(
    workspacePaths: string[],
    changedPaths: string[],
  ): Promise<JavaWorkspacePolicy>;
  notify(
    workspacePath: string,
    changes: Array<{ path: string; kind: FileChangeKind }>,
  ): Promise<void>;
  createOperationLog(operationId: string, context: Record<string, unknown>): OperationLog;
  setTimer(callback: TimerCallback, delayMilliseconds: number): TimerHandle;
  clearTimer(timer: TimerHandle): void;
}

const FLUSH_DELAY_MS = 350;

function workspaceKey(workspaceId: string): string {
  return workspaceId.toLowerCase();
}

async function notifyWorkspaceFilesChanged(
  workspacePath: string,
  changes: Array<{ path: string; kind: FileChangeKind }>,
): Promise<void> {
  const { LspClient } = await import("./lsp-client");
  await LspClient.getInstance().notifyWorkspaceFilesChanged(workspacePath, changes);
}

/** Owns debounced Java watcher batches until they reach one explicit terminal state. */
export class JavaWorkspaceChangeScheduler {
  private readonly batches = new Map<string, ChangeBatchOwner>();
  private readonly resolvePolicy: JavaWorkspaceChangeSchedulerDependencies["resolvePolicy"];
  private readonly notify: JavaWorkspaceChangeSchedulerDependencies["notify"];
  private readonly createOperationLog: JavaWorkspaceChangeSchedulerDependencies["createOperationLog"];
  private readonly setTimer: JavaWorkspaceChangeSchedulerDependencies["setTimer"];
  private readonly clearTimer: JavaWorkspaceChangeSchedulerDependencies["clearTimer"];

  constructor(dependencies: Partial<JavaWorkspaceChangeSchedulerDependencies> = {}) {
    this.resolvePolicy = dependencies.resolvePolicy ?? resolveJavaWorkspacePolicy;
    this.notify = dependencies.notify ?? notifyWorkspaceFilesChanged;
    this.createOperationLog =
      dependencies.createOperationLog ??
      ((operationId, context) =>
        new LspOperationLog("javaWorkspaceChanges", operationId, context));
    this.setTimer =
      dependencies.setTimer ??
      ((callback, delayMilliseconds) =>
        setTimeout(() => void callback(), delayMilliseconds));
    this.clearTimer = dependencies.clearTimer ?? clearTimeout;
  }

  schedule(
    workspaceId: string,
    workspacePath: string,
    change: ScheduledChange,
  ): void {
    const key = workspaceKey(workspaceId);
    let owner = this.batches.get(key);

    if (owner?.state.phase === "flushing") {
      owner.state = { phase: "cancelled" };
      owner.operation.cancelled("superseded-by-new-batch");
      const carriedChanges = new Map(owner.changes);
      owner = this.createOwner(key, workspaceId, workspacePath, carriedChanges);
      this.batches.set(key, owner);
    } else if (!owner || owner.state.phase !== "scheduled") {
      owner = this.createOwner(key, workspaceId, workspacePath);
      this.batches.set(key, owner);
    } else {
      this.clearTimer(owner.state.timer);
    }

    const previous = owner.changes.get(change.path);
    owner.changes.set(change.path, {
      ...change,
      includeSource: change.includeSource || previous?.includeSource === true,
    });
    this.arm(owner);
  }

  cancel(workspaceId?: string): void {
    const owners = workspaceId
      ? [this.batches.get(workspaceKey(workspaceId))]
      : [...this.batches.values()];
    for (const owner of owners) {
      if (!owner || owner.state.phase === "cancelled" || owner.state.phase === "completed") {
        continue;
      }
      if (owner.state.phase === "scheduled") this.clearTimer(owner.state.timer);
      owner.state = { phase: "cancelled" };
      owner.operation.cancelled("workspace-closed");
      if (this.batches.get(owner.key) === owner) this.batches.delete(owner.key);
    }
  }

  private createOwner(
    key: string,
    workspaceId: string,
    workspacePath: string,
    changes: Map<string, ScheduledChange> = new Map(),
  ): ChangeBatchOwner {
    const operationId = crypto.randomUUID();
    return {
      key,
      workspaceId,
      workspacePath,
      operationId,
      changes,
      operation: this.createOperationLog(operationId, { workspaceId, workspacePath }),
      state: { phase: "completed" },
    };
  }

  private arm(owner: ChangeBatchOwner): void {
    const timer = this.setTimer(() => this.flush(owner), FLUSH_DELAY_MS);
    owner.state = { phase: "scheduled", timer };
  }

  private isCurrent(owner: ChangeBatchOwner): boolean {
    return this.batches.get(owner.key) === owner && owner.state.phase === "flushing";
  }

  private complete(
    owner: ChangeBatchOwner,
    outcome:
      | { kind: "succeeded"; forwardedChangeCount: number }
      | { kind: "cancelled"; reason: string },
  ): void {
    if (!this.isCurrent(owner)) return;
    owner.state = { phase: "completed" };
    if (outcome.kind === "succeeded") {
      owner.operation.succeeded({ forwardedChangeCount: outcome.forwardedChangeCount });
    } else {
      owner.operation.cancelled(outcome.reason);
    }
    this.batches.delete(owner.key);
  }

  private async flush(owner: ChangeBatchOwner): Promise<void> {
    if (this.batches.get(owner.key) !== owner || owner.state.phase !== "scheduled") return;
    owner.state = { phase: "flushing" };

    try {
      const relativeChanges = [...owner.changes.values()]
        .filter((change) => pathStartsWithRoot(change.path, owner.workspacePath))
        .map((change) => ({
          ...change,
          relativePath: getRelativePath(change.path, owner.workspacePath),
        }));
      if (relativeChanges.length === 0) {
        this.complete(owner, { kind: "cancelled", reason: "no-workspace-contained-paths" });
        return;
      }

      const policy = await this.resolvePolicy(
        [],
        relativeChanges.map((change) => change.relativePath),
      );
      if (!this.isCurrent(owner)) return;

      const kinds = new Map(policy.changes.map((change) => [change.path, change.kind]));
      const relevant = relativeChanges.filter((change) => {
        const kind = kinds.get(change.relativePath);
        return kind === "buildConfiguration" || (kind === "source" && change.includeSource);
      });
      if (relevant.length === 0) {
        this.complete(owner, { kind: "succeeded", forwardedChangeCount: 0 });
        return;
      }

      await this.notify(
        owner.workspacePath,
        relevant.map(({ path, kind }) => ({ path, kind })),
      );
      if (!this.isCurrent(owner)) return;
      this.complete(owner, { kind: "succeeded", forwardedChangeCount: relevant.length });
    } catch (reason) {
      if (!this.isCurrent(owner)) return;
      owner.state = { phase: "completed" };
      owner.operation.failed(reason);
      this.batches.delete(owner.key);
    }
  }
}

const sharedScheduler = new JavaWorkspaceChangeScheduler();

/** Coalesces watcher bursts before applying the Rust-owned Java change policy. */
export function scheduleJavaWorkspaceChange(
  workspaceId: string,
  workspacePath: string,
  change: ScheduledChange,
): void {
  sharedScheduler.schedule(workspaceId, workspacePath, change);
}

/** Cancels scheduled and in-flight Java workspace change batches on close. */
export function cancelJavaWorkspaceChanges(workspaceId?: string): void {
  sharedScheduler.cancel(workspaceId);
}
