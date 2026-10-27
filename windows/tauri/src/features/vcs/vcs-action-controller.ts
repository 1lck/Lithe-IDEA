import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";
import {
  reviewPaths,
  permitsWholeCopy,
  type VcsReview,
  type VcsWriteAction,
  type VcsWriteSnapshot,
} from "./vcs-action-types";

export interface VcsActionState {
  phase:
    | "idle"
    | "confirming"
    | "running"
    | "stopping"
    | "cancelFailed"
    | "completed"
    | "failed"
    | "unknown";
  rootId: string | null;
  review: VcsReview | null;
  result: VcsWriteSnapshot["result"] | null;
  error: unknown;
}
interface Attempt {
  id: string;
  source: VcsSnapshot;
  status: VcsStatusSnapshot;
  history: { rootId: string | null; path: string | null };
  abort: AbortController;
  cancellation: Promise<void> | null;
  failure: { error: unknown; uncertain: boolean } | null;
}
/** A local deadline/abort or malformed reply cannot prove a write's outcome. */
class UncertainWriteError extends Error {}
/** Confirmation is local and inert. Only confirm dispatches one native write;
 * every cleanup/retry retains that ID and can only stop its original owner. */
export class VcsActionController {
  #state: VcsActionState = { phase: "idle", rootId: null, review: null, result: null, error: null };
  #attempt: Attempt | null = null;
  #closed = false;
  #refreshing = false;
  #listeners = new Set<() => void>();
  constructor(
    private roots: VcsRootController,
    private port: VcsRootPort,
  ) {}
  getSnapshot = () => this.#state;
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  get busy() {
    return this.#attempt !== null || this.#state.phase === "confirming";
  }
  #publish(patch: Partial<VcsActionState>) {
    this.#state = { ...this.#state, ...patch };
    for (const listener of this.#listeners) listener();
  }
  prepare(status: VcsStatusSnapshot, action: VcsWriteAction) {
    const source = this.roots.getSnapshot().snapshot;
    const root = source?.detection.roots.find(
      (root) => root.id === status.rootId && root.vcs === status.vcs,
    );
    if (
      this.#closed ||
      this.busy ||
      this.roots.query.busy ||
      !source ||
      source.detection.truncated ||
      !root ||
      this.roots.status.getSnapshot().snapshot !== status ||
      status.generation !== source.generation
    )
      return;
    try {
      const paths = reviewPaths(status, action);
      // Neither v1 update nor cleanup can restrict itself to a subdirectory.
      if (
        (action.operation === "update" || action.operation === "cleanup") &&
        !permitsWholeCopy(source, root.id)
      )
        throw new Error("vcs.provider.pathUnavailable");
      this.#publish({
        phase: "confirming",
        rootId: root.id,
        review: {
          status,
          statusId: status.requestId,
          action: structuredClone(action),
          rootPath: root.path,
          paths,
        },
        error: null,
        result: null,
      });
    } catch (error) {
      this.#publish({ phase: "failed", rootId: status.rootId, error });
    }
  }
  #bounded<T>(start: () => Promise<T>, signal?: AbortSignal, long = false): Promise<T> {
    return new Promise((resolve, reject) => {
      let ended = false;
      let stopDeadline = () => {};
      const finish = (value: T | null, error?: unknown) => {
        if (ended) return;
        ended = true;
        stopDeadline();
        signal?.removeEventListener("abort", abort);
        if (error) reject(error);
        else resolve(value!);
      };
      const failure = (code: string) => (long ? new UncertainWriteError(code) : new Error(code));
      const abort = () => finish(null, failure("requestCancelled"));
      signal?.addEventListener("abort", abort, { once: true });
      stopDeadline = (
        long
          ? (this.port.writeDeadline ?? this.port.statusDeadline ?? this.port.deadline)
          : this.port.deadline
      )(() => finish(null, failure("requestTimeout")));
      if (signal?.aborted) abort();
      if (ended) stopDeadline();
      else
        Promise.resolve()
          .then(() => {
            if (ended) throw new Error("requestCancelled");
            return start();
          })
          .then(
            (value) => finish(value),
            (error: unknown) => finish(null, error),
          );
    });
  }
  async confirm(): Promise<void> {
    if (this.#attempt) return;
    const review = this.#state.review;
    const source = this.roots.getSnapshot().snapshot;
    if (
      this.#closed ||
      this.#state.phase !== "confirming" ||
      !review ||
      !source ||
      this.roots.status.getSnapshot().snapshot !== review.status ||
      review.status.requestId !== review.statusId ||
      source.generation !== review.status.generation
    ) {
      this.invalidate();
      return;
    }
    const history = this.roots.query.getSnapshot();
    const attempt: Attempt = {
      id: crypto.randomUUID(),
      source,
      status: review.status,
      history: { rootId: history.rootId, path: history.path },
      abort: new AbortController(),
      cancellation: null,
      failure: null,
    };
    this.#attempt = attempt;
    this.#publish({ phase: "running", review: null, error: null });
    try {
      const result = await this.#bounded(
        () => {
          if (!this.port.write) throw new Error("vcs.provider.unavailable");
          return this.port.write(
            this.roots.scope,
            source.generation,
            review.status.rootId,
            attempt.id,
            review.statusId,
            review.action,
          );
        },
        attempt.abort.signal,
        true,
      );
      if (
        this.#attempt !== attempt ||
        this.#closed ||
        attempt.abort.signal.aborted ||
        this.roots.getSnapshot().snapshot !== source
      )
        return;
      if (
        result.requestId !== attempt.id ||
        result.rootId !== review.status.rootId ||
        result.generation !== source.generation ||
        result.vcs !== review.status.vcs ||
        result.operation !== review.action.operation
      )
        throw new UncertainWriteError("invalidResponse");
      this.#attempt = null;
      this.#publish({ phase: "completed", result: result.result, error: null });
      await this.#refresh(attempt);
    } catch (error) {
      if (this.#attempt !== attempt) return;
      attempt.failure = {
        error,
        uncertain:
          error instanceof UncertainWriteError ||
          String(error).includes("vcs.provider.outcomeUnknown"),
      };
      try {
        await this.#stop(attempt);
        await this.#refresh(attempt);
      } catch {
        /* Retry Stop retains the original owner; never resend. */
      }
    }
  }
  async #refresh(attempt: Attempt) {
    if (this.#closed || this.roots.getSnapshot().snapshot !== attempt.source) return;
    this.#refreshing = true;
    try {
      await this.roots.refresh();
      const root = this.roots
        .getSnapshot()
        .snapshot?.detection.roots.find((root) => root.id === attempt.status.rootId);
      const original = attempt.source.detection.roots.find(
        (root) => root.id === attempt.status.rootId,
      );
      if (!root || root.path !== original?.path || root.vcs !== original.vcs || this.#closed) {
        this.#publish({ phase: "idle", rootId: null, result: null, error: null });
        return;
      }
      await this.roots.status.refresh(root.id);
      const current = this.roots.status.getSnapshot().snapshot;
      if (!current || current.rootIdentity !== attempt.status.rootIdentity) {
        this.#publish({ phase: "idle", rootId: null, result: null, error: null });
        return;
      }
      if (!this.#closed && attempt.history.rootId === root.id)
        await this.roots.query.history(root.id, attempt.history.path);
    } finally {
      this.#refreshing = false;
    }
  }

  async #stop(attempt: Attempt): Promise<void> {
    if (attempt.cancellation) return attempt.cancellation;
    attempt.abort.abort();
    this.#publish({ phase: "stopping", review: null });
    const cancellation = this.#bounded(async () => {
      if (!this.port.cancelStatus) throw new Error("vcs.provider.unavailable");
      await this.port.cancelStatus(this.roots.scope, attempt.id);
    });
    attempt.cancellation = cancellation;
    try {
      await cancellation;
      if (this.#attempt === attempt) {
        this.#attempt = null;
        const failure = attempt.failure;
        this.#publish({
          phase: failure && !failure.uncertain ? "failed" : "unknown",
          error: failure?.error ?? new Error("vcs.provider.outcomeUnknown"),
          result: null,
        });
      }
    } catch (error) {
      attempt.cancellation = null;
      if (this.#attempt === attempt) this.#publish({ phase: "cancelFailed", error });
      throw error;
    }
  }
  async cancel(): Promise<void> {
    if (this.#attempt) {
      const attempt = this.#attempt;
      await this.#stop(attempt);
      await this.#refresh(attempt);
    } else this.#publish({ phase: "idle", review: null, error: null });
  }
  invalidate() {
    if (this.#attempt) void this.#stop(this.#attempt).catch(() => {});
    else if (!this.#refreshing || this.#state.phase === "confirming")
      this.#publish({ phase: "idle", rootId: null, review: null, result: null, error: null });
  }
  async close() {
    this.#closed = true;
    this.invalidate();
    if (this.#attempt) await this.#stop(this.#attempt);
    this.#listeners.clear();
  }
}
