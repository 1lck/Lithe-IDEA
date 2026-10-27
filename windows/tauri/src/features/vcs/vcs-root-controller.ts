import type {
  VcsOwnership,
  VcsRootPort,
  VcsRootState,
  VcsScope,
  VcsSnapshot,
  VcsInvalidation,
} from "./vcs-root-types";
import { VcsRefreshQueue } from "./vcs-refresh-queue";
import { VcsMappingController } from "./vcs-mapping-controller";
import { VcsStatusController } from "./vcs-status-controller";

/** Presentation/lifecycle owner only. All root assignment stays in native Core. */
export class VcsRootController {
  #state: VcsRootState = { status: "idle", snapshot: null, error: null };
  #epoch = 0;
  #closed = false;
  #listeners = new Set<() => void>();
  #reads = new Set<() => void>();
  #scans = new Set<() => void>();
  #scansInFlight = new Set<Promise<VcsSnapshot>>();
  #closing: Promise<void> | null = null;
  #saves = new Set<() => void>();
  #stopWatch: (() => void) | null = null;
  #watchReady: Promise<void>;
  #watchError: string | null = null;
  #latestGeneration = 0;
  #queue: VcsRefreshQueue;
  readonly status: VcsStatusController;
  readonly mappings: VcsMappingController;
  constructor(
    readonly scope: VcsScope,
    private readonly port: VcsRootPort,
  ) {
    this.status = new VcsStatusController(this, port);
    this.mappings = new VcsMappingController(this);
    this.#queue = new VcsRefreshQueue(port.debounce ?? port.deadline, async () => {
      const generation = this.#latestGeneration;
      await Promise.allSettled([...this.#scansInFlight]);
      if (!this.#closed && (this.#state.snapshot?.generation ?? 0) <= generation)
        await this.refresh(true);
    });
    this.#watchReady = port.subscribe
      ? port.subscribe(scope, this.metadataChanged).then(
          (stop) => {
            if (this.#closed) stop();
            else this.#stopWatch = stop;
          },
          () => {
            this.#watchError = "vcs.watch.failed";
          },
        )
      : Promise.resolve();
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
  #read<T>(start: () => Promise<T>, signal?: AbortSignal, reads = this.#reads): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let finished = false;
      let stopDeadline = () => {};
      const finish = (value: T | null, error: unknown) => {
        if (finished) return;
        finished = true;
        stopDeadline();
        reads.delete(cancel);
        signal?.removeEventListener("abort", cancel);
        if (error) reject(error);
        else resolve(value as T);
      };
      const cancel = () => finish(null, new Error("requestCancelled"));
      reads.add(cancel);
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
  invalidate(preserveScan = false) {
    if (!preserveScan) this.#queue.reset();
    this.status.invalidate();
    ++this.#epoch;
    for (const cancel of [...this.#reads]) cancel();
    if (!preserveScan) for (const cancel of [...this.#scans]) cancel();
    this.#publish({ status: "idle", snapshot: null, error: null });
  }
  metadataChanged = (event: VcsInvalidation) => {
    if (
      this.#closed ||
      !event ||
      event.workspaceId !== this.scope.workspaceId ||
      event.incarnation !== this.scope.incarnation ||
      !Number.isSafeInteger(event.generation) ||
      event.generation <= 0 ||
      event.generation < this.#latestGeneration
    )
      return;
    this.#latestGeneration = event.generation;
    this.invalidate(true);
    this.#queue.changed();
  };
  async saveMapping(id: string, vcs: string | null): Promise<void> {
    const snapshot = this.#state.snapshot;
    if (this.#closed || !snapshot?.mappings || !this.port.saveMapping || this.#saves.size)
      throw new Error("requestCancelled");
    await this.#read(
      () =>
        this.port.saveMapping!(
          this.scope,
          snapshot.generation,
          snapshot.mappings!.revision,
          id,
          vcs,
        ),
      undefined,
      this.#saves,
    );
    if (this.#closed) throw new Error("requestCancelled");
    await this.refresh();
  }
  async refresh(automatic = false): Promise<void> {
    if (this.#closed) throw new Error("requestCancelled");
    this.invalidate(automatic);
    const epoch = this.#epoch;
    this.#publish({ status: "loading", snapshot: null, error: null });
    try {
      const scan = this.#read(
        async () => {
          await this.#watchReady;
          return this.port.detect(this.scope);
        },
        undefined,
        this.#scans,
      );
      this.#scansInFlight.add(scan);
      let snapshot: VcsSnapshot;
      try {
        snapshot = await scan;
      } finally {
        this.#scansInFlight.delete(scan);
      }
      this.#current(epoch);
      this.#validate(snapshot);
      this.#latestGeneration = Math.max(this.#latestGeneration, snapshot.generation);
      if (this.#watchError) snapshot.watchError = this.#watchError;
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
    this.mappings.close();
    this.#queue.close();
    this.#stopWatch?.();
    this.#stopWatch = null;
    for (const cancel of [...this.#saves]) cancel();
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
