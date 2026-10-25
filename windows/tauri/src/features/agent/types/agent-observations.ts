/** Bounded, session-scoped observations supplied by the shared Agent Host. */
import {
  appendMessage, createConversation, interruptPendingTools, parseContextUsage, parsePlan, upsertToolMessage,
  type AgentContextUsage, type AgentConversationMessage, type AgentPlanEntry,
} from "./agent.types";

export interface AgentSubagent {
  id: string;
  parentID: string;
  name: string;
  task: string;
  state: "running" | "completed" | "failed" | "cancelled" | "disconnected";
  messages: AgentConversationMessage[];
  plan: AgentPlanEntry[];
  contextUsage: AgentContextUsage | null;
}

export interface AgentNotice {
  id: string;
  revision: number;
  severity: string;
  title: string;
  description: string | null;
}

export interface AgentModelCall {
  api: string;
  model: string | null;
  status: number;
  streaming: boolean;
  durationMs: number;
  firstTokenMs: number | null;
  usage: { inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number; reasoningTokens: number | null } | null;
  context: { systemPromptTokens: number; toolTokens: number; mcpToolTokens: number; messageTokens: number; toolCount: number; mcpToolCount: number; scaledToUsage: boolean } | null;
  /** A background request the Agent made for itself (Claude Code naming the session): its tokens count, it is not a step. */
  auxiliary: boolean;
}

export function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function count(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}
export function terminalChild(child: AgentSubagent): boolean { return child.state !== "running"; }

const MAX_FINISHED_SUBAGENTS = 64;

/** Bound historical display records without evicting live permission owners. */
export function retainSubagentHistory(children: AgentSubagent[]): AgentSubagent[] {
  const finished = children.filter(terminalChild);
  if (finished.length <= MAX_FINISHED_SUBAGENTS) return children;
  const retained = new Set(finished.slice(-MAX_FINISHED_SUBAGENTS).map((child) => child.id));
  return children.filter((child) => !terminalChild(child) || retained.has(child.id));
}

/** All descendants, including the target. Ownership is immutable after spawn. */
export function childSubtree(children: AgentSubagent[], id: string): Set<string> {
  const ids = new Set([id]);
  for (let pass = 0; pass < children.length; pass++) {
    const previous = ids.size;
    for (const child of children) if (ids.has(child.parentID)) ids.add(child.id);
    if (ids.size === previous) break;
  }
  return ids;
}

export function finishChildren(children: AgentSubagent[], parentID?: string): AgentSubagent[] {
  const ids = parentID === undefined ? null : childSubtree(children, parentID);
  return retainSubagentHistory(children.map((child) => !terminalChild(child) && (ids === null || ids.has(child.id))
    ? { ...child, state: "disconnected", messages: interruptPendingTools({ ...createConversation(), messages: child.messages }).messages } : child));
}

export function updateChild(child: AgentSubagent, update: Record<string, unknown>): AgentSubagent {
  if (terminalChild(child)) return child;
  let view = { ...createConversation(), messages: child.messages };
  const text = record(update.content) && typeof update.content.text === "string" ? update.content.text : null;
  switch (update.sessionUpdate) {
    case "agent_message_chunk":
    case "agent_thought_chunk":
    case "user_message_chunk":
      if (text !== null) view = appendMessage(view, update.sessionUpdate === "agent_message_chunk" ? "agent" : update.sessionUpdate === "agent_thought_chunk" ? "reasoning" : "user", text);
      break;
    case "tool_call":
    case "tool_call_update":
      if (typeof update.toolCallId === "string") view = upsertToolMessage(view, update.toolCallId, update);
      break;
    case "plan": return { ...child, plan: parsePlan(update) ?? child.plan };
    case "usage_update": return { ...child, contextUsage: parseContextUsage(update) };
  }
  return { ...child, messages: view.messages.slice(-200) };
}

export function parseNotice(update: Record<string, unknown>): AgentNotice | null {
  if (update.sessionUpdate === "notice" && typeof update.title === "string" && update.title.trim().length > 0 && ["info", "warning", "error"].includes(String(update.severity))) {
    return { id: update.title, revision: 0, severity: String(update.severity ?? "info"), title: update.title, description: typeof update.description === "string" ? update.description : null };
  }
  const meta = update._meta;
  const jetbrains = record(meta) ? meta.jetbrains : null;
  const air = record(jetbrains) ? jetbrains.air : null;
  const failure = record(air) ? air.sessionFailure : null;
  if (!record(failure) || typeof failure.id !== "string" || typeof failure.title !== "string") return null;
  // Codex recovery payloads are normalized by Host into turnRetrying. Never
  // render their encoded transport envelope as a user-facing error.
  if (failure.title.startsWith('{"litheCodexFailure"')) return null;
  return { id: failure.id, revision: count(failure.revision) ?? 0, severity: String(failure.severity ?? "error"), title: failure.title, description: typeof failure.details === "string" ? failure.details : null };
}

export function parseModelCall(value: unknown): AgentModelCall | null {
  if (!record(value) || typeof value.api !== "string") return null;
  const status = count(value.status), durationMs = count(value.durationMs);
  if (status === null || durationMs === null) return null;
  const usage = record(value.usage) ? value.usage : null;
  const context = record(value.context) ? value.context : null;
  const validUsage = usage !== null && ["inputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens"].every((key) => count(usage[key]) !== null);
  const validContext = context !== null && ["systemPromptTokens", "toolTokens", "mcpToolTokens", "messageTokens", "toolCount", "mcpToolCount"].every((key) => count(context[key]) !== null);
  return {
    api: value.api, model: typeof value.model === "string" ? value.model : null, status,
    streaming: value.streaming === true, durationMs, firstTokenMs: count(value.firstTokenMs), auxiliary: value.auxiliary === true,
    usage: validUsage ? { inputTokens: usage.inputTokens as number, cacheReadTokens: usage.cacheReadTokens as number, cacheWriteTokens: usage.cacheWriteTokens as number, outputTokens: usage.outputTokens as number, reasoningTokens: count(usage.reasoningTokens) } : null,
    context: validContext ? { systemPromptTokens: context.systemPromptTokens as number, toolTokens: context.toolTokens as number, mcpToolTokens: context.mcpToolTokens as number, messageTokens: context.messageTokens as number, toolCount: context.toolCount as number, mcpToolCount: context.mcpToolCount as number, scaledToUsage: context.scaledToUsage === true } : null,
  };
}

/** No accounting is inferred for requests without a provider usage report. */
export function modelCallTotals(calls: AgentModelCall[]) {
  return calls.reduce((total, call) => addModelCall(total, call), emptyModelCallTotals());
}

export function emptyModelCallTotals() {
  return { calls: 0, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, lowerBound: false,
    durationMs: 0, latencyMs: 0, latencyCount: 0, generatingMs: 0, streamingOutput: 0, nonStreaming: 0 };
}
export type AgentModelCallTotals = ReturnType<typeof emptyModelCallTotals>;

export function addModelCall(total: AgentModelCallTotals, call: AgentModelCall): AgentModelCallTotals {
  if (call.auxiliary) {
    return {
      ...total,
      input: total.input + (call.usage?.inputTokens ?? 0),
      cacheRead: total.cacheRead + (call.usage?.cacheReadTokens ?? 0),
      cacheWrite: total.cacheWrite + (call.usage?.cacheWriteTokens ?? 0),
      output: total.output + (call.usage?.outputTokens ?? 0),
      lowerBound: total.lowerBound || call.usage === null,
    };
  }
  const measuredStream = call.streaming && call.usage !== null && call.firstTokenMs !== null && call.durationMs > call.firstTokenMs;
  return {
    calls: total.calls + 1,
    input: total.input + (call.usage?.inputTokens ?? 0),
    cacheRead: total.cacheRead + (call.usage?.cacheReadTokens ?? 0),
    cacheWrite: total.cacheWrite + (call.usage?.cacheWriteTokens ?? 0),
    output: total.output + (call.usage?.outputTokens ?? 0),
    lowerBound: total.lowerBound || call.usage === null,
    durationMs: total.durationMs + call.durationMs,
    latencyMs: total.latencyMs + (call.firstTokenMs ?? 0),
    latencyCount: total.latencyCount + (call.firstTokenMs === null ? 0 : 1),
    generatingMs: total.generatingMs + (measuredStream ? call.durationMs - call.firstTokenMs! : 0),
    streamingOutput: total.streamingOutput + (measuredStream ? call.usage!.outputTokens : 0),
    nonStreaming: total.nonStreaming + (call.streaming ? 0 : 1),
  };
}
