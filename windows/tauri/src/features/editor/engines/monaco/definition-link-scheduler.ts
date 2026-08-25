type TimerHandle = ReturnType<typeof setTimeout> | number;

interface DefinitionHoverSchedulerOptions<Request, Result> {
  delayMilliseconds: number;
  keyOf: (request: Request) => string;
  resolve: (request: Request) => Promise<Result>;
  onActiveRequest?: (request: Request) => void;
  onActiveResult: (request: Request, result: Result) => void;
  onError?: (error: unknown) => void;
  scheduleTimer?: (callback: () => void, delayMilliseconds: number) => TimerHandle;
  cancelTimer?: (handle: TimerHandle) => void;
  cacheLimit?: number;
}

interface QueuedRequest<Request, Result> {
  request: Request;
  key: string;
  generation: number;
  priority: "hover" | "immediate";
  promise: Promise<Result | undefined>;
  resolve: (result: Result | undefined) => void;
}

interface InFlightRequest<Result> {
  key: string;
  generation: number;
  promise: Promise<Result | undefined>;
}

interface ActiveRequest<Request> {
  request: Request;
  key: string;
}

interface ScheduledRequest {
  handle: TimerHandle;
  key: string;
}

type SchedulerLifecycle = { phase: "active" } | { phase: "disposed" };

function deferred<Result>() {
  let resolve!: (result: Result | undefined) => void;
  const promise = new Promise<Result | undefined>((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

export class DefinitionHoverScheduler<Request, Result> {
  private readonly delayMilliseconds: number;
  private readonly keyOf: (request: Request) => string;
  private readonly resolveRequest: (request: Request) => Promise<Result>;
  private readonly onActiveRequest?: (request: Request) => void;
  private readonly onActiveResult: (request: Request, result: Result) => void;
  private readonly onError?: (error: unknown) => void;
  private readonly scheduleTimer: (callback: () => void, delayMilliseconds: number) => TimerHandle;
  private readonly cancelTimer: (handle: TimerHandle) => void;
  private readonly cacheLimit: number;
  private readonly cache = new Map<string, Result>();

  private generation = 0;
  private lifecycle: SchedulerLifecycle = { phase: "active" };
  private active: ActiveRequest<Request> | null = null;
  private scheduled: ScheduledRequest | null = null;
  private queued: QueuedRequest<Request, Result> | null = null;
  private inFlight: InFlightRequest<Result> | null = null;

  constructor(options: DefinitionHoverSchedulerOptions<Request, Result>) {
    this.delayMilliseconds = options.delayMilliseconds;
    this.keyOf = options.keyOf;
    this.resolveRequest = options.resolve;
    this.onActiveRequest = options.onActiveRequest;
    this.onActiveResult = options.onActiveResult;
    this.onError = options.onError;
    this.scheduleTimer =
      options.scheduleTimer ?? ((callback, delay) => setTimeout(callback, delay));
    this.cancelTimer =
      options.cancelTimer ?? ((handle) => clearTimeout(handle as ReturnType<typeof setTimeout>));
    this.cacheLimit = Math.max(1, options.cacheLimit ?? 32);
  }

  activate(request: Request): void {
    if (this.lifecycle.phase === "disposed") return;

    const key = this.keyOf(request);
    this.active = { request, key };
    this.onActiveRequest?.(request);

    const cached = this.readCache(key);
    if (cached !== undefined) {
      this.cancelScheduled();
      this.onActiveResult(request, cached);
      return;
    }
    if (
      (this.inFlight?.key === key && this.inFlight.generation === this.generation) ||
      (this.queued?.key === key && this.queued.generation === this.generation) ||
      this.scheduled?.key === key
    ) {
      return;
    }

    this.cancelScheduled();
    const generation = this.generation;
    let handle!: TimerHandle;
    handle = this.scheduleTimer(() => {
      if (this.scheduled?.handle === handle) this.scheduled = null;
      if (
        this.lifecycle.phase === "disposed" ||
        generation !== this.generation ||
        this.active?.key !== key
      ) {
        return;
      }
      this.queueRequest(request, "hover", generation);
    }, this.delayMilliseconds);
    this.scheduled = { handle, key };
  }

  clearActive(): void {
    this.active = null;
    this.cancelScheduled();
  }

  resolveNow(request: Request): Promise<Result | undefined> {
    if (this.lifecycle.phase === "disposed") return Promise.resolve(undefined);

    const key = this.keyOf(request);
    const cached = this.readCache(key);
    if (cached !== undefined) return Promise.resolve(cached);

    if (this.scheduled?.key === key) this.cancelScheduled();
    if (this.inFlight?.key === key && this.inFlight.generation === this.generation) {
      return this.inFlight.promise;
    }
    if (this.queued?.key === key && this.queued.generation === this.generation) {
      this.queued.priority = "immediate";
      return this.queued.promise;
    }

    return this.queueRequest(request, "immediate", this.generation);
  }

  reset(): void {
    this.generation += 1;
    this.active = null;
    this.cancelScheduled();
    this.cache.clear();
    this.queued?.resolve(undefined);
    this.queued = null;
  }

  dispose(): void {
    if (this.lifecycle.phase === "disposed") return;
    this.reset();
    this.lifecycle = { phase: "disposed" };
  }

  private queueRequest(
    request: Request,
    priority: "hover" | "immediate",
    generation: number,
  ): Promise<Result | undefined> {
    const key = this.keyOf(request);
    if (priority === "hover" && this.queued?.priority === "immediate") {
      return Promise.resolve(undefined);
    }

    this.queued?.resolve(undefined);
    const pending = deferred<Result>();
    this.queued = {
      request,
      key,
      generation,
      priority,
      ...pending,
    };
    this.pump();
    return pending.promise;
  }

  private pump(): void {
    if (this.lifecycle.phase === "disposed" || this.inFlight || !this.queued) return;

    const queued = this.queued;
    this.queued = null;
    if (
      queued.generation !== this.generation ||
      (queued.priority === "hover" && this.active?.key !== queued.key)
    ) {
      queued.resolve(undefined);
      this.pump();
      return;
    }

    const cached = this.readCache(queued.key);
    if (cached !== undefined) {
      queued.resolve(cached);
      if (this.active?.key === queued.key) this.onActiveResult(queued.request, cached);
      this.pump();
      return;
    }

    let requestPromise: Promise<Result>;
    try {
      requestPromise = this.resolveRequest(queued.request);
    } catch (error) {
      this.onError?.(error);
      queued.resolve(undefined);
      this.scheduleActiveAfterCurrentWork(queued.key);
      return;
    }

    const work = requestPromise
      .then((result) => {
        if (this.lifecycle.phase === "disposed" || queued.generation !== this.generation) {
          return undefined;
        }
        this.writeCache(queued.key, result);
        if (this.active?.key === queued.key) this.onActiveResult(queued.request, result);
        return result;
      })
      .catch((error) => {
        if (this.lifecycle.phase === "active" && queued.generation === this.generation) {
          this.onError?.(error);
        }
        return undefined;
      })
      .finally(() => {
        if (this.inFlight?.promise === work) this.inFlight = null;
        this.pump();
        this.scheduleActiveAfterCurrentWork(queued.key);
      });

    this.inFlight = { key: queued.key, generation: queued.generation, promise: work };
    void work.then(queued.resolve);
  }

  private scheduleActiveAfterCurrentWork(completedKey: string): void {
    if (
      this.lifecycle.phase === "disposed" ||
      this.inFlight ||
      this.queued ||
      this.scheduled ||
      !this.active ||
      this.active.key === completedKey ||
      this.cache.has(this.active.key)
    ) {
      return;
    }
    this.activate(this.active.request);
  }

  private cancelScheduled(): void {
    if (this.scheduled) this.cancelTimer(this.scheduled.handle);
    this.scheduled = null;
  }

  private readCache(key: string): Result | undefined {
    const result = this.cache.get(key);
    if (result === undefined) return undefined;
    this.cache.delete(key);
    this.cache.set(key, result);
    return result;
  }

  private writeCache(key: string, result: Result): void {
    this.cache.delete(key);
    this.cache.set(key, result);
    while (this.cache.size > this.cacheLimit) {
      const oldestKey = this.cache.keys().next().value;
      if (oldestKey === undefined) break;
      this.cache.delete(oldestKey);
    }
  }
}
