/**
 * Locally observed timing and Agent-reported token counts of one prompt turn,
 * the Windows counterpart of `AgentTurnStatistics.swift`.
 *
 * Timing starts when the user submits, so session preparation, tools and
 * permission waits are included. It uses a monotonic clock supplied by the
 * caller, so a wall-clock change never makes a turn look shorter or negative.
 * Replayed history carries no timing, so loaded turns get no statistics instead
 * of fabricated ones.
 */

/** Token counters from a prompt response; the Agent owns their accounting scope. */
export interface AgentTurnUsage {
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  thoughtTokens: number | null;
  cachedReadTokens: number | null;
  cachedWriteTokens: number | null;
}

export interface AgentTurnStatistics {
  /** Id of the user message that started the turn. */
  id: string;
  /** Monotonic milliseconds at submission. */
  startedAt: number;
  /** Last message of the turn; its summary is drawn after this message. */
  endingMessageID: string | null;
  /** Seconds, set once the turn finished. */
  duration: number | null;
  usage: AgentTurnUsage | null;
}

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

/** The required counters must all be present; optional ones may be missing. */
export function parseTurnUsage(value: unknown): AgentTurnUsage | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const totalTokens = count(record.totalTokens);
  const inputTokens = count(record.inputTokens);
  const outputTokens = count(record.outputTokens);
  if (totalTokens === null || inputTokens === null || outputTokens === null) return null;
  return {
    totalTokens,
    inputTokens,
    outputTokens,
    thoughtTokens: count(record.thoughtTokens),
    cachedReadTokens: count(record.cachedReadTokens),
    cachedWriteTokens: count(record.cachedWriteTokens),
  };
}

export function startTurn(id: string, startedAt: number): AgentTurnStatistics {
  return { id, startedAt, endingMessageID: null, duration: null, usage: null };
}

/** Seconds since submission, or the frozen duration of a finished turn. */
export function turnElapsed(turn: AgentTurnStatistics, now: number): number {
  return turn.duration ?? Math.max(0, (now - turn.startedAt) / 1000);
}

export function finishTurn(
  turn: AgentTurnStatistics,
  now: number,
  endingMessageID: string,
  usage: AgentTurnUsage | null,
): AgentTurnStatistics {
  return { ...turn, duration: turnElapsed(turn, now), endingMessageID, usage };
}

/** Labels for `formatTurnDuration`, already localized by the caller. */
export interface AgentDurationLabels {
  hours: (hours: number, minutes: number, seconds: number) => string;
  minutes: (minutes: number, seconds: number) => string;
  seconds: (seconds: number) => string;
}

/** `1h 2m 3s`, `2m 3s` or `3s`, truncating partial seconds like macOS. */
export function formatTurnDuration(seconds: number, labels: AgentDurationLabels): string {
  if (!Number.isFinite(seconds)) return "—";
  const total = Math.floor(Math.max(0, seconds));
  if (total >= 3600) {
    return labels.hours(Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60);
  }
  if (total >= 60) return labels.minutes(Math.floor(total / 60), total % 60);
  return labels.seconds(total);
}
