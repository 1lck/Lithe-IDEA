import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";

export interface VcsStatusState {
  phase: "idle" | "loading" | "ready" | "failed" | "stopping" | "cancelFailed";
  rootId: string | null;
  snapshot: VcsStatusSnapshot | null;
  error: unknown;
}
interface Attempt {
  id: string;
  source: VcsSnapshot;
  rootId: string;
  controller: AbortController;
  cancellation: Promise<void> | null;
}
/** A separate read-only projection. Git's repository state, branches and
 * mutation actions never consume provider status or change its active path. */
export class VcsStatusController {
  #state: VcsStatusState = { phase: "idle", rootId: null, snapshot: null, error: null };
  #attempt: Attempt | null = null;
  #closed = false;
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
  #publish(patch: Partial<VcsStatusState>) {
    this.#state = { ...this.#state, ...patch };
    for (const listener of this.#listeners) listener();
  }
  #read(attempt: Attempt): Promise<VcsStatusSnapshot> {
    return new Promise((resolve, reject) => {
      let ended = false;
      let stopDeadline = () => {};
      const finish = (result: VcsStatusSnapshot | null, error?: unknown) => {
        if (ended) return;
        ended = true;
        stopDeadline();
        attempt.controller.signal.removeEventListener("abort", abort);
        if (error) reject(error);
        else resolve(result!);
      };
      const abort = () => finish(null, new Error("requestCancelled"));
      attempt.controller.signal.addEventListener("abort", abort, { once: true });
      stopDeadline = (this.port.statusDeadline ?? this.port.deadline)(() =>
        finish(null, new Error("requestTimeout")),
      );
      if (attempt.controller.signal.aborted) abort();
      if (ended) stopDeadline();
      else
        Promise.resolve()
          .then(() => {
            if (ended) throw new Error("requestCancelled");
            if (!this.port.status) throw new Error("vcs.provider.unavailable");
            return this.port.status(
              this.roots.scope,
              attempt.source.generation,
              attempt.rootId,
              attempt.id,
            );
          })
          .then(
            (result) => finish(result),
            (error: unknown) => finish(null, error),
          );
    });
  }
  async refresh(rootId: string): Promise<void> {
    if (this.#closed || this.#attempt) return;
    const source = this.roots.getSnapshot().snapshot;
    const root = source?.detection.roots.find((root) => root.id === rootId);
    if (
      !source ||
      !root ||
      !source.detection.providers.some(
        (provider) => provider.vcs === root.vcs && provider.origin.kind === "plugin",
      )
    )
      return;
    const attempt: Attempt = {
      id: crypto.randomUUID(),
      source,
      rootId,
      controller: new AbortController(),
      cancellation: null,
    };
    this.#attempt = attempt;
    this.#publish({ phase: "loading", rootId, snapshot: null, error: null });
    try {
      const answer = await this.#read(attempt);
      if (
        this.#closed ||
        this.#attempt !== attempt ||
        attempt.controller.signal.aborted ||
        this.roots.getSnapshot().snapshot !== source
      )
        return;
      if (
        !answer ||
        answer.requestId !== attempt.id ||
        answer.generation !== source.generation ||
        answer.rootId !== root.id ||
        answer.vcs !== root.vcs ||
        !Array.isArray(answer.result?.changes) ||
        typeof answer.result.truncated !== "boolean"
      )
        throw new Error("invalidResponse");
      this.#attempt = null;
      this.#publish({ phase: "ready", snapshot: answer, error: null });
    } catch (error) {
      if (this.#attempt !== attempt) return;
      const cancelled = attempt.controller.signal.aborted;
      try {
        await this.#cancel(attempt);
        if (!this.#closed && !cancelled) this.#publish({ phase: "failed", snapshot: null, error });
      } catch {
        /* The original native owner and Stop action remain retryable. */
      }
    }
  }
  async #cancel(attempt: Attempt): Promise<void> {
    if (attempt.cancellation) return attempt.cancellation;
    attempt.controller.abort();
    this.#publish({ phase: "stopping", snapshot: null, error: null });
    const pending = new Promise<void>((resolve, reject) => {
      let ended = false;
      let stopDeadline = () => {};
      const finish = (error?: unknown) => {
        if (ended) return;
        ended = true;
        stopDeadline();
        if (error) reject(error);
        else resolve();
      };
      stopDeadline = this.port.deadline(() => finish(new Error("requestTimeout")));
      if (ended) stopDeadline();
      else
        Promise.resolve()
          .then(async () => {
            if (!this.port.cancelStatus) throw new Error("vcs.provider.unavailable");
            await this.port.cancelStatus(this.roots.scope, attempt.id);
          })
          .then(() => finish(), finish);
    });
    attempt.cancellation = pending;
    try {
      await pending;
      if (this.#attempt === attempt) {
        this.#attempt = null;
        this.#publish({ phase: "idle", snapshot: null, error: null });
      }
    } catch (error) {
      attempt.cancellation = null;
      if (this.#attempt === attempt)
        this.#publish({ phase: "cancelFailed", snapshot: null, error });
      throw error;
    }
  }
  cancel(): Promise<void> {
    return this.#attempt ? this.#cancel(this.#attempt) : Promise.resolve();
  }
  invalidate() {
    this.#publish({ snapshot: null });
    if (this.#attempt) void this.cancel().catch(() => {});
    else this.#publish({ phase: "idle", rootId: null, error: null });
  }
  async close() {
    this.#closed = true;
    this.#publish({ snapshot: null });
    await this.cancel();
    this.#listeners.clear();
  }
}
