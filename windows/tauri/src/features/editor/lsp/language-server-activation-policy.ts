import { invoke } from "@/platform/tauri-core";

/** Failure history Core returns; stored verbatim per server key. */
export interface LanguageServerActivationState {
  consecutiveFailures: number;
  lastFailureAtMs: number;
}

export type LanguageServerActivationEvent =
  | "automaticStart"
  | "explicitStart"
  | "startFailed"
  | "ready";

export interface LanguageServerActivationOutcome {
  state: LanguageServerActivationState | null;
  decision: "allow" | "wait" | "explicitRetryRequired";
  retryAfterMs: number | null;
}

/**
 * Keeps each server's startup failure history and asks Core
 * (`lsp.activationPolicy`) whether an automatic start may run. The retry
 * budget and cooldown are shared with macOS; time is a monotonic reading.
 */
export class LanguageServerActivationHistory {
  private readonly states = new Map<string, LanguageServerActivationState>();

  constructor(private readonly monotonicNowMs: () => number = () => performance.now()) {}

  async apply(
    serverKey: string,
    event: LanguageServerActivationEvent,
  ): Promise<LanguageServerActivationOutcome> {
    const outcome = await invoke<LanguageServerActivationOutcome>("lsp.activationPolicy", {
      state: this.states.get(serverKey) ?? null,
      event,
      nowMs: Math.max(0, Math.floor(this.monotonicNowMs())),
    });
    if (outcome.state) this.states.set(serverKey, outcome.state);
    else this.states.delete(serverKey);
    return outcome;
  }

  /** Forgets a server whose last tracked document closed. */
  release(serverKey: string): void {
    this.states.delete(serverKey);
  }
}
