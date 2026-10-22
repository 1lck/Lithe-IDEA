import { emptyModelCallTotals, record, type AgentModelCallTotals } from "./agent-observations";
import { parseTurnUsage, type AgentTurnUsage } from "./agent-turn-statistics";
import { parseContextUsage, type AgentContextUsage, type AgentSessionConfigOption } from "./agent.types";

/** Only cumulative observations are durable. Replayed messages never increment them. */
export interface AgentSessionStatistics {
  turnCount: number;
  toolCallCount: number;
  toolDurationMs: number;
  calls: AgentModelCallTotals;
  latestUsage: AgentTurnUsage | null;
  contextUsage: AgentContextUsage | null;
  contextModels: string;
}
export interface AgentStatisticsStore {
  read(sessionID: string): AgentSessionStatistics | null;
  write(sessionID: string, value: AgentSessionStatistics): void;
}
export function emptySessionStatistics(): AgentSessionStatistics {
  return { turnCount: 0, toolCallCount: 0, toolDurationMs: 0, calls: emptyModelCallTotals(), latestUsage: null, contextUsage: null, contextModels: "" };
}
export function contextModels(options: AgentSessionConfigOption[]): string {
  return JSON.stringify(options.filter((option) => option.category === "model")
    .map((option) => [option.id, option.currentValue]).sort(([a], [b]) => a.localeCompare(b)));
}
export function parseSessionStatistics(value: unknown): AgentSessionStatistics | null {
  if (!record(value) || !record(value.calls)) return null;
  const calls = emptyModelCallTotals();
  for (const key of Object.keys(calls) as (keyof AgentModelCallTotals)[]) {
    if (key === "lowerBound") {
      if (typeof value.calls[key] !== "boolean") return null;
      calls.lowerBound = value.calls[key];
    } else {
      const count = value.calls[key];
      if (typeof count !== "number" || !Number.isFinite(count) || count < 0) return null;
      calls[key] = count;
    }
  }
  if (typeof value.turnCount !== "number" || !Number.isSafeInteger(value.turnCount) || value.turnCount < 0) return null;
  const toolCallCount = value.toolCallCount ?? 0;
  const toolDurationMs = value.toolDurationMs ?? 0;
  if (typeof toolCallCount !== "number" || !Number.isSafeInteger(toolCallCount) || toolCallCount < 0 ||
    typeof toolDurationMs !== "number" || !Number.isFinite(toolDurationMs) || toolDurationMs < 0) return null;
  const usage = record(value.contextUsage) ? value.contextUsage : null;
  return { turnCount: value.turnCount, toolCallCount, toolDurationMs, calls, latestUsage: parseTurnUsage(value.latestUsage),
    contextUsage: usage ? parseContextUsage({ used: usage.usedTokens, size: usage.capacityTokens }) : null,
    contextModels: typeof value.contextModels === "string" ? value.contextModels : "" };
}
