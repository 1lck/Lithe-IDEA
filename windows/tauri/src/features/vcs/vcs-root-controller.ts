import type {
  VcsOwnership,
  VcsRootPort,
  VcsRootState,
  VcsScope,
  VcsSnapshot,
} from "./vcs-root-types";
import { VcsStatusController } from "./vcs-status-controller";

/** Presentation/lifecycle owner only. All root assignment stays in native Core. */
export class VcsRootController {
  #state: VcsRootState = { status: "idle", snapshot: null, error: null };
  #epoch = 0;
  #closed = false;
  #listeners = new Set<() => void>();
  #reads = new Set<() => void>();
  #closing: Promise<void> | null = null;
  readonly status: VcsStatusController;
  constructor(
    readonly scope: VcsScope,
    private readonly port: VcsRootPort,
  ) {
    this.status = new VcsStatusController(this, port);
  }
  getSnapshot = () => this.#state;
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  #publish(state: VcsRootState) {
    this.#state = state;
    for (const listener of this.#listeners) listener();
  }
  #current(epoch: number) {
    if (this.#closed || this.#epoch !== epoch) throw new Error("requestCancelled");
  }
  #read<T>(start: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let finished = false;
      let stopDeadline = () => {};
      const finish = (value: T | null, error: unknown) => {
        if (finished) return;
        finished = true;
        stopDeadline();
        this.#reads.delete(cancel);
        signal?.removeEventListener("abort", cancel);
        if (error) reject(error);
        else resolve(value as T);
      };
      const cancel = () => finish(null, new Error("requestCancelled"));
      this.#reads.add(cancel);
      signal?.addEventListener("abort", cancel, { once: true });
      if (signal?.aborted) cancel();
      stopDeadline = this.port.deadline(() => finish(null, new Error("requestTimeout")));
      if (finished) stopDeadline();
      else
        Promise.resolve()
          .then(() => {
            if (finished) throw new Error("requestCancelled");
            return start();
          })
          .then(
            (value) => finish(value, null),
            (error: unknown) => finish(null, error),
          );
    });
  }
  invalidate() {
    this.status.invalidate();
    ++this.#epoch;
    for (const cancel of [...this.#reads]) cancel();
    this.#publish({ status: "idle", snapshot: null, error: null });
  }
  async refresh(): Promise<void> {
    if (this.#closed) throw new Error("requestCancelled");
    this.invalidate();
    const epoch = this.#epoch;
    this.#publish({ status: "loading", snapshot: null, error: null });
    try {
      const snapshot = await this.#read(() => this.port.detect(this.scope));
      this.#current(epoch);
      this.#validate(snapshot);
      this.#publish({ status: "ready", snapshot, error: null });
    } catch (error) {
      if (!this.#closed && epoch === this.#epoch)
        this.#publish({ status: "failed", snapshot: null, error });
    }
  }
  #validate(snapshot: VcsSnapshot) {
    if (
      !snapshot ||
      snapshot.workspaceId !== this.scope.workspaceId ||
      snapshot.workspaceRoot !== this.scope.workspaceRoot ||
      !Number.isSafeInteger(snapshot.generation) ||
      snapshot.generation <= 0 ||
      !Array.isArray(snapshot.detection?.roots) ||
      !Array.isArray(snapshot.detection.providers) ||
      !Array.isArray(snapshot.detection.ambiguous) ||
      typeof snapshot.detection.truncated !== "boolean"
    )
      throw new Error("invalidResponse");
  }
  async owners(paths: readonly string[], signal?: AbortSignal): Promise<VcsOwnership> {
    const snapshot = this.#state.snapshot;
    const epoch = this.#epoch;
    this.#current(epoch);
    if (this.#state.status !== "ready" || !snapshot) throw new Error("requestCancelled");
    const answer = await this.#read(
      () => this.port.owners(this.scope, snapshot.generation, [...paths]),
      signal,
    );
    this.#current(epoch);
    if (
      this.#state.snapshot !== snapshot ||
      answer.generation !== snapshot.generation ||
      answer.owners.length !== paths.length ||
      answer.owners.some((owner, index) => owner.path !== paths[index])
    )
      throw new Error("requestCancelled");
    return answer;
  }
  close(): Promise<void> {
    if (this.#closing) return this.#closing;
    this.#closed = true;
    this.invalidate();
    this.#listeners.clear();
    this.#closing = (async () => {
      // Native close must still run when an individual status cleanup failed;
      // it revokes every owner in this exact workspace incarnation.
      let failure: unknown;
      try {
        await this.status.close();
      } catch (error) {
        failure = error;
      }
      try {
        await this.#read(() => this.port.close(this.scope));
      } catch (error) {
        failure = error;
      }
      if (failure) throw failure;
    })();
    void this.#closing.catch(() => {
      this.#closing = null;
    });
    return this.#closing;
  }
}
