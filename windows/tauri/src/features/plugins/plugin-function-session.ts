export interface FunctionInput {
  pluginId: string;
  actionId: string;
  workspacePath: string;
  expectedIdentity: string;
  operationId: string;
}
export interface FunctionContext {
  window: string;
  pluginId: string;
  actionId: string;
  functionId: string;
  workspacePath: string;
  generation: number;
  packageIdentity: string;
  settingIdentity: string;
  operationId: string;
}
export interface FunctionReview {
  context: FunctionContext;
  title: string;
  confirm: boolean;
  executesProjectCode: boolean;
  mayUseNetwork: boolean;
  launchPlan: unknown;
  program: unknown;
}
export interface FunctionFailure {
  code: string;
  message: string;
  pluginErrorCode?: string | null;
}
export interface FunctionSnapshot {
  context: FunctionContext;
  phase: "review" | "starting" | "running" | "succeeded" | "failed" | "cancelled" | "cleanupFailed";
  progress?: { message?: string; percentage?: number } | null;
  result?: unknown;
  error?: FunctionFailure | null;
}
export interface FunctionPorts {
  prepare(input: FunctionInput): Promise<FunctionReview>;
  confirm(operationId: string): Promise<void>;
  read(operationId: string): Promise<FunctionSnapshot>;
  cancel(operationId: string): Promise<void>;
  assertCurrent(): void;
  wait(signal: AbortSignal): Promise<void>;
  deadline(expired: () => void): () => void;
}
export interface FunctionState {
  phase: "idle" | "preparing" | "stopping" | FunctionSnapshot["phase"];
  review: FunctionReview | null;
  progress: FunctionSnapshot["progress"];
  result?: unknown;
  error: FunctionFailure | null;
}
export function functionFailure(error: unknown): FunctionFailure {
  if (error && typeof error === "object" && "code" in error && "message" in error)
    return error as FunctionFailure;
  return { code: "plugin.function.failed", message: String(error) };
}

/** One UI action incarnation. Its cleanup owner outlives the page, and joins
 * late prepare/confirm replies before releasing the exact native receipt. */
export class PluginFunctionSession {
  state: FunctionState = { phase: "idle", review: null, progress: null, error: null };
  private closed = false;
  private disposed = false;
  private released = false;
  private prepareTask: Promise<FunctionReview> | null = null;
  private confirmTask: Promise<void> | null = null;
  private cleanupTask: Promise<void> | null = null;
  private readonly controller = new AbortController();
  private clearDeadline: (() => void) | null = null;
  constructor(
    readonly input: FunctionInput,
    private readonly ports: FunctionPorts,
    private readonly publish: (state: FunctionState) => void,
    private readonly retain: (session: PluginFunctionSession, retained: boolean) => void,
  ) {}
  private emit(patch: Partial<FunctionState>) {
    this.state = { ...this.state, ...patch };
    if (!this.disposed) this.publish(this.state);
    this.retain(this, !this.released);
  }
  private current() {
    if (this.closed || this.disposed) throw new Error("plugin.function.staleContext");
    this.ports.assertCurrent();
  }
  private cleanupFailed() {
    return this.state.phase === "cleanupFailed";
  }
  async prepare() {
    if (this.state.phase !== "idle") return;
    try {
      this.current();
      this.emit({ phase: "preparing", error: null });
      this.clearDeadline = this.ports.deadline(() => void this.cancel());
      this.prepareTask = this.ports.prepare(this.input);
      const review = await this.prepareTask;
      this.state = { ...this.state, review };
      this.current();
      const context = review.context;
      if (
        context.pluginId !== this.input.pluginId ||
        context.actionId !== this.input.actionId ||
        context.operationId !== this.input.operationId ||
        context.workspacePath !== this.input.workspacePath ||
        context.settingIdentity !== this.input.expectedIdentity ||
        !context.packageIdentity ||
        !context.window ||
        !Number.isSafeInteger(context.generation) ||
        context.generation < 0
      )
        throw new Error("plugin.function.staleContext");
      this.emit({ phase: "review", review });
    } catch (error) {
      if (this.closed || this.disposed || this.state.review) {
        const wasClosed = this.closed || this.disposed;
        await this.cancel();
        if (!wasClosed && !this.cleanupFailed())
          this.emit({ phase: "failed", error: functionFailure(error) });
      } else {
        this.released = true;
        this.clearDeadline?.();
        this.emit({ phase: "failed", error: functionFailure(error) });
      }
    }
  }
  async confirm() {
    if (this.state.phase !== "review" || !this.state.review || this.closed) return;
    try {
      this.current();
      this.emit({ phase: "starting", error: null });
      this.confirmTask = this.ports.confirm(this.input.operationId);
      await this.confirmTask;
      this.current();
      while (!this.closed) {
        const snapshot = await this.ports.read(this.input.operationId);
        this.current();
        const expected = this.state.review!.context;
        if (
          (Object.keys(expected) as Array<keyof FunctionContext>).some(
            (key) => snapshot.context[key] !== expected[key],
          )
        )
          throw new Error("plugin.function.staleContext");
        if (snapshot.phase === "cleanupFailed") {
          this.clearDeadline?.();
          this.emit({
            phase: "cleanupFailed",
            progress: null,
            error: snapshot.error ?? {
              code: "plugin.function.cleanupFailed",
              message: "plugin.function.cleanupFailed",
            },
          });
          return;
        }
        if (["succeeded", "failed", "cancelled"].includes(snapshot.phase)) {
          await this.ports.cancel(this.input.operationId);
          this.current();
          this.released = true;
          this.clearDeadline?.();
          this.emit({
            phase: snapshot.phase,
            progress: null,
            result: snapshot.result,
            error: snapshot.error ?? null,
          });
          return;
        }
        this.emit({ phase: snapshot.phase, progress: snapshot.progress ?? null });
        await this.ports.wait(this.controller.signal);
      }
    } catch (error) {
      const failure = functionFailure(error);
      const wasClosed = this.closed || this.disposed;
      await this.cancel();
      if (!this.cleanupFailed() && !wasClosed) this.emit({ phase: "failed", error: failure });
    }
  }
  cancel(): Promise<void> {
    if (this.released) return Promise.resolve();
    if (this.state.phase === "idle") {
      this.released = true;
      return Promise.resolve();
    }
    if (this.cleanupTask) return this.cleanupTask;
    this.closed = true;
    this.controller.abort();
    this.clearDeadline?.();
    this.emit({ phase: "stopping", progress: null });
    const task = (async () => {
      try {
        // No other owner is allowed to cancel the later receipt on our behalf.
        const review = await this.prepareTask?.catch(() => null);
        await this.confirmTask?.catch(() => {});
        if (review) await this.ports.cancel(this.input.operationId);
        this.released = true;
        this.emit({ phase: "cancelled", error: null });
      } catch (error) {
        this.emit({ phase: "cleanupFailed", error: functionFailure(error) });
      } finally {
        this.cleanupTask = null;
      }
    })();
    this.cleanupTask = task;
    return task;
  }
  dispose() {
    this.disposed = true;
    void this.cancel();
  }
}
