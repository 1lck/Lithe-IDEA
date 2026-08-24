import { frontendTrace } from "@/utils/frontend-trace";

export type CoreLspSessionState =
  | "created"
  | "processStarting"
  | "initializing"
  | "ready"
  | "stopping"
  | "stopped"
  | "failed";

export type LspAdapterSessionPhase = CoreLspSessionState | "recovering";

export type LspFeatureSnapshot =
  | { phase: "unknown" }
  | { phase: "known"; features: string[] };

export interface LspSessionLifecycle {
  phase: LspAdapterSessionPhase;
  operationId: string;
}

export type LspOperationOutcome = "started" | "succeeded" | "failed" | "cancelled" | "timedOut";

type TraceReporter = typeof frontendTrace;
type Clock = () => number;

export function createSessionLifecycle(
  phase: LspAdapterSessionPhase,
  operationId: string = crypto.randomUUID(),
): LspSessionLifecycle {
  return { phase, operationId };
}

export function transitionSessionLifecycle(
  lifecycle: LspSessionLifecycle,
  phase: LspAdapterSessionPhase,
  operationId = lifecycle.operationId,
): void {
  lifecycle.phase = phase;
  lifecycle.operationId = operationId;
}

export function isSessionReady(lifecycle: LspSessionLifecycle): boolean {
  return lifecycle.phase === "ready";
}

export function isSessionTerminal(lifecycle: LspSessionLifecycle): boolean {
  return lifecycle.phase === "stopped" || lifecycle.phase === "failed";
}

export function featureSnapshot(features?: Iterable<string>): LspFeatureSnapshot {
  return features === undefined
    ? { phase: "unknown" }
    : { phase: "known", features: [...features].sort() };
}

export class LspOperationLog {
  private state: "active" | "completed" = "active";
  private readonly startedAt: number;

  constructor(
    private readonly name: string,
    readonly operationId: string,
    private readonly context: Record<string, unknown> = {},
    private readonly report: TraceReporter = frontendTrace,
    private readonly now: Clock = Date.now,
  ) {
    this.startedAt = now();
    this.emit("info", "started");
  }

  succeeded(details: Record<string, unknown> = {}): void {
    this.complete("info", "succeeded", details);
  }

  failed(reason: unknown, details: Record<string, unknown> = {}): void {
    this.complete("error", "failed", { ...errorFields(reason), ...details });
  }

  cancelled(reason: string, details: Record<string, unknown> = {}): void {
    this.complete("info", "cancelled", { reason, ...details });
  }

  timedOut(details: Record<string, unknown> = {}): void {
    this.complete("warn", "timedOut", details);
  }

  private complete(
    level: "info" | "warn" | "error",
    outcome: Exclude<LspOperationOutcome, "started">,
    details: Record<string, unknown>,
  ): void {
    if (this.state === "completed") return;
    this.state = "completed";
    this.emit(level, outcome, {
      durationMilliseconds: Math.max(0, this.now() - this.startedAt),
      ...details,
    });
  }

  private emit(
    level: "info" | "warn" | "error",
    outcome: LspOperationOutcome,
    details: Record<string, unknown> = {},
  ): void {
    this.report(level, "lsp.lifecycle", `${this.name}:${outcome}`, {
      operationId: this.operationId,
      operation: this.name,
      outcome,
      ...this.context,
      ...details,
    });
  }
}

function errorFields(reason: unknown): Record<string, unknown> {
  if (reason instanceof Error) {
    const coded = reason as Error & { code?: string; details?: string };
    return {
      error: reason.message,
      errorCode: coded.code,
      errorDetails: coded.details,
    };
  }
  return { error: String(reason) };
}
