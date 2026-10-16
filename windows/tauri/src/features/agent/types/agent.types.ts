/**
 * Agent conversation domain types and pure reducers.
 *
 * Shapes are fixed by `shared/fixtures/agent/acp-events-v1.json`, which macOS
 * also reads. Every ACP event and command crosses this boundary as UTF-8 JSON
 * and is parsed here, so the panel never invents its own protocol vocabulary.
 *
 * The reducers stay pure and framework-free: the connection store calls them,
 * and tests drive them straight from the shared fixture.
 */

/** Agent-owned context occupancy, distinct from cumulative billing tokens. */
export interface AgentContextUsage {
  usedTokens: number;
  capacityTokens: number;
  /** Preserved even above 1 so an over-full window is visible rather than clamped. */
  fraction: number;
}

export interface AgentSubscriptionQuotaWindow {
  id: string;
  name: string;
  limitSeconds: number;
  usedPercent: number | null;
  resetsAt: number | null;
}

export interface AgentSubscriptionQuota {
  windows: AgentSubscriptionQuotaWindow[];
  fetchedAt: number;
}

export interface AgentSessionConfigChoice {
  id: string;
  name: string;
  group: string | null;
  description: string | null;
}

export interface AgentSessionConfigOption {
  id: string;
  name: string;
  category: string | null;
  currentValue: string;
  choices: AgentSessionConfigChoice[];
}

export type AgentMessageRole = "user" | "agent" | "tool";

export type AgentToolStatus = "pending" | "in_progress" | "completed" | "failed" | "interrupted";

export interface AgentToolLocation {
  path: string;
  line: number | null;
}

export interface AgentToolContent {
  title: string;
  text: string;
}

/** Bounded presentation of ACP tool evidence; partial updates replace present fields only. */
export interface AgentToolDetails {
  kind: string | null;
  input: string | null;
  output: string | null;
  locations: AgentToolLocation[];
  content: AgentToolContent[];
}

export interface AgentConversationMessage {
  id: string;
  role: AgentMessageRole;
  text: string;
  toolStatus: AgentToolStatus | null;
  toolDetails: AgentToolDetails;
}

export interface AgentPermissionChoice {
  id: string;
  label: string;
  kind: string | null;
}

export interface AgentPermissionPrompt {
  id: string;
  title: string;
  choices: AgentPermissionChoice[];
  details: AgentToolDetails;
}

export interface AgentSessionSummary {
  id: string;
  title: string | null;
  updatedAt: string | null;
}

/** Display state of one conversation session. */
export interface AgentConversation {
  messages: AgentConversationMessage[];
  contextUsage: AgentContextUsage | null;
  isResponding: boolean;
  isLoading: boolean;
  isCancelling: boolean;
  configOptions: AgentSessionConfigOption[];
  pendingConfigToken: string | null;
  configurationError: string | null;
  /** A new process must load this session before prompting it again. */
  isAttached: boolean;
  /**
   * Only a successful creation or load establishes a complete history snapshot.
   * Unlike `isAttached`, it stays true after the process disconnects.
   */
  hasCompleteHistory: boolean;
  pendingPermissions: AgentPermissionPrompt[];
  errorMessage: string | null;
}

/** A native file the user attached, not a copied or preloaded attachment. */
export interface AgentFileReference {
  uri: string;
  name: string;
}

export interface AgentPrompt {
  text: string;
  files: AgentFileReference[];
}

export type AgentConnectionState =
  | { status: "idle" }
  | { status: "connecting" }
  | { status: "authenticationRequired" }
  | { status: "authenticating" }
  | { status: "ready" }
  | { status: "failed"; message: string };

/** Attach up to this many files per message, matching the macOS panel. */
export const AGENT_FILE_LIMIT = 32;

/** Tool evidence is truncated so one chatty tool call cannot grow the panel without bound. */
export const AGENT_TOOL_TEXT_LIMIT = 32_768;

const TOOL_LOCATION_LIMIT = 100;
const TOOL_CONTENT_LIMIT = 100;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function asNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function emptyToolDetails(): AgentToolDetails {
  return { kind: null, input: null, output: null, locations: [], content: [] };
}

export function createConversation(): AgentConversation {
  return {
    messages: [],
    contextUsage: null,
    isResponding: false,
    isLoading: false,
    isCancelling: false,
    configOptions: [],
    pendingConfigToken: null,
    configurationError: null,
    isAttached: false,
    hasCompleteHistory: false,
    pendingPermissions: [],
    errorMessage: null,
  };
}

export function currentPermission(conversation: AgentConversation): AgentPermissionPrompt | null {
  return conversation.pendingPermissions[0] ?? null;
}

/**
 * Agent-reported occupancy. A window without a positive size carries no
 * meaning, so it is reported as unknown instead of zero.
 */
export function parseContextUsage(update: unknown): AgentContextUsage | null {
  if (!isRecord(update)) return null;
  const used = asNumber(update.used);
  const size = asNumber(update.size);
  if (used === null || size === null || size <= 0) return null;
  return { usedTokens: used, capacityTokens: size, fraction: used / size };
}

/**
 * Account-owned subscription windows. An entry that loses its identity or
 * reports an impossible percentage is rejected instead of shown as zero usage.
 */
export function parseSubscriptionQuota(value: unknown): AgentSubscriptionQuota | null {
  if (!isRecord(value) || !Array.isArray(value.windows) || value.windows.length === 0) return null;
  const fetchedAt = asNumber(value.fetchedAt);
  if (fetchedAt === null) return null;
  const windows: AgentSubscriptionQuotaWindow[] = [];
  for (const entry of value.windows) {
    if (!isRecord(entry)) return null;
    const id = asString(entry.id);
    const name = asString(entry.name);
    const limitSeconds = asNumber(entry.limitSeconds);
    if (!id || !name || limitSeconds === null || limitSeconds <= 0) return null;
    const percent = entry.usedPercent ?? null;
    const usedPercent = percent === null ? null : asNumber(percent);
    if (percent !== null && (usedPercent === null || usedPercent < 0 || usedPercent > 100)) {
      return null;
    }
    const reset = entry.resetsAt ?? null;
    const resetsAt = reset === null ? null : asNumber(reset);
    if (reset !== null && resetsAt === null) return null;
    windows.push({ id, name, limitSeconds, usedPercent, resetsAt });
  }
  return { windows, fetchedAt };
}

/** Window closest to its limit; the panel shows this one by default. */
export function mostUsedQuotaWindow(quota: AgentSubscriptionQuota): AgentSubscriptionQuotaWindow | null {
  let best: AgentSubscriptionQuotaWindow | null = null;
  for (const window of quota.windows) {
    if (window.usedPercent === null) continue;
    if (best === null || (best.usedPercent ?? 0) < window.usedPercent) best = window;
  }
  return best;
}

/**
 * A snapshot older than two minutes, or one whose window already reset, must
 * not be presented as current usage.
 */
export function isQuotaStale(quota: AgentSubscriptionQuota, nowSeconds: number): boolean {
  if (nowSeconds - quota.fetchedAt > 120) return true;
  return quota.windows.some((window) => window.resetsAt !== null && window.resetsAt <= nowSeconds);
}

/**
 * Agent-owned configuration choices, never a hardcoded product model or
 * permission catalog. Grouped entries nest one level, as the ACP schema allows.
 */
export function parseSessionConfigOptions(value: unknown): AgentSessionConfigOption[] {
  if (!Array.isArray(value)) return [];
  const options: AgentSessionConfigOption[] = [];
  for (const entry of value) {
    if (!isRecord(entry) || entry.type !== "select") continue;
    const id = asString(entry.id);
    const name = asString(entry.name);
    const currentValue = asString(entry.currentValue);
    if (!id || !name || currentValue === null) continue;
    const choices: AgentSessionConfigChoice[] = [];
    const rawOptions = Array.isArray(entry.options) ? entry.options : [];
    for (const group of rawOptions) {
      if (!isRecord(group)) continue;
      // A nested `options` array marks a group; its entries inherit the group name.
      const isGroup = Array.isArray(group.options);
      const nested = isGroup ? (group.options as unknown[]) : [group];
      const groupName = isGroup ? asString(group.name) : null;
      for (const choice of nested) {
        if (!isRecord(choice)) continue;
        const choiceID = asString(choice.value);
        const choiceName = asString(choice.name);
        if (choiceID === null || choiceName === null) continue;
        choices.push({ id: choiceID, name: choiceName, group: groupName, description: asString(choice.description) });
      }
    }
    options.push({ id, name, category: asString(entry.category), currentValue, choices });
  }
  return options;
}

export function configOptionLabel(option: AgentSessionConfigOption): string {
  return option.choices.find((choice) => choice.id === option.currentValue)?.name ?? option.currentValue;
}

/** Message text of an ACP content update, or null when this update carries none. */
export function updateText(update: Record<string, unknown>): string | null {
  const content = update.content;
  if (!isRecord(content)) return null;
  return asString(content.text);
}

function bounded(text: string): string {
  return text.length > AGENT_TOOL_TEXT_LIMIT ? `${text.slice(0, AGENT_TOOL_TEXT_LIMIT)}\n[...]` : text;
}

/** JSON is sorted so the same tool input always renders identically. */
function displayValue(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") return bounded(value);
  try {
    return bounded(JSON.stringify(value, stableKeys, 2));
  } catch {
    return bounded(String(value));
  }
}

function stableKeys(_key: string, value: unknown): unknown {
  if (!isRecord(value)) return value;
  return Object.fromEntries(Object.entries(value).sort(([left], [right]) => (left < right ? -1 : 1)));
}

/** Merge one tool update into the accumulated evidence, keeping absent fields. */
export function mergeToolDetails(details: AgentToolDetails, update: Record<string, unknown>): AgentToolDetails {
  const merged: AgentToolDetails = { ...details, locations: details.locations, content: details.content };
  const kind = asString(update.kind);
  if (kind !== null) merged.kind = kind;
  if ("rawInput" in update) merged.input = displayValue(update.rawInput);
  if ("rawOutput" in update) merged.output = displayValue(update.rawOutput);
  if (Array.isArray(update.locations)) {
    merged.locations = update.locations.slice(0, TOOL_LOCATION_LIMIT).flatMap((entry) => {
      if (!isRecord(entry)) return [];
      const path = asString(entry.path);
      if (path === null) return [];
      const line = asNumber(entry.line);
      return [{ path, line: line !== null && line > 0 ? line : null }];
    });
  }
  if (Array.isArray(update.content)) {
    merged.content = update.content.slice(0, TOOL_CONTENT_LIMIT).flatMap((entry): AgentToolContent[] => {
      if (!isRecord(entry)) return [];
      if (entry.type === "content") {
        const block = entry.content;
        if (!isRecord(block)) return [];
        const text = asString(block.text);
        if (text !== null) return [{ title: "Output", text: bounded(text) }];
        return [{ title: "Content", text: asString(block.type) ?? "Unsupported content" }];
      }
      if (entry.type === "diff") {
        const oldText = asString(entry.oldText) ?? "";
        const newText = asString(entry.newText) ?? "";
        return [{ title: asString(entry.path) ?? "Diff", text: bounded(`---\n${oldText}\n+++\n${newText}`) }];
      }
      if (entry.type === "terminal") {
        return [{ title: "Terminal", text: asString(entry.terminalId) ?? "" }];
      }
      return [];
    });
  }
  return merged;
}

function toolStatusOf(update: Record<string, unknown>): AgentToolStatus | null {
  const status = asString(update.status);
  switch (status) {
    case "pending":
    case "in_progress":
    case "completed":
    case "failed":
    case "interrupted":
      return status;
    default:
      return null;
  }
}

/**
 * Insert or update one tool call. A partial update replaces only the fields it
 * carries, so a streamed tool keeps its title and evidence while it runs.
 */
export function upsertToolMessage(
  conversation: AgentConversation,
  toolCallID: string,
  update: Record<string, unknown>,
): AgentConversation {
  const id = `tool:${toolCallID}`;
  const status = toolStatusOf(update);
  const title = asString(update.title);
  const messages = conversation.messages.slice();
  const index = messages.findIndex((message) => message.id === id);
  if (index >= 0) {
    const existing = messages[index];
    messages[index] = {
      ...existing,
      text: title !== null && title.length > 0 ? title : existing.text,
      toolStatus: status ?? existing.toolStatus,
      toolDetails: mergeToolDetails(existing.toolDetails, update),
    };
  } else {
    messages.push({
      id,
      role: "tool",
      text: title !== null && title.length > 0 ? title : "Tool call",
      toolStatus: status ?? "pending",
      toolDetails: mergeToolDetails(emptyToolDetails(), update),
    });
  }
  return { ...conversation, messages };
}

/** Consecutive chunks of one role extend the previous message instead of splitting it. */
export function appendMessage(
  conversation: AgentConversation,
  role: AgentMessageRole,
  text: string,
): AgentConversation {
  const messages = conversation.messages.slice();
  const last = messages[messages.length - 1];
  if (last !== undefined && last.role === role) {
    messages[messages.length - 1] = { ...last, text: last.text + text };
  } else {
    messages.push({
      id: crypto.randomUUID(),
      role,
      text,
      toolStatus: null,
      toolDetails: emptyToolDetails(),
    });
  }
  return { ...conversation, messages };
}

/** A turn that ended without a final tool status must not look like it is still running. */
export function interruptPendingTools(conversation: AgentConversation): AgentConversation {
  const messages = conversation.messages.map((message) =>
    message.role === "tool" && (message.toolStatus === "pending" || message.toolStatus === "in_progress")
      ? { ...message, toolStatus: "interrupted" as const }
      : message,
  );
  return { ...conversation, messages };
}

export function enqueuePermission(
  conversation: AgentConversation,
  prompt: AgentPermissionPrompt,
): AgentConversation {
  const pending = conversation.pendingPermissions.slice();
  const index = pending.findIndex((entry) => entry.id === prompt.id);
  if (index >= 0) {
    pending[index] = prompt;
  } else {
    pending.push(prompt);
  }
  return { ...conversation, pendingPermissions: pending };
}

/**
 * Build the prompt for one permission request, reusing the evidence the panel
 * already showed for that tool call when the agent sends a thinner request.
 */
export function permissionPrompt(
  conversation: AgentConversation,
  requestID: string,
  request: unknown,
): AgentPermissionPrompt {
  const record = isRecord(request) ? request : {};
  const tool = isRecord(record.toolCall) ? record.toolCall : null;
  const choices = (Array.isArray(record.options) ? record.options : []).flatMap(
    (option): AgentPermissionChoice[] => {
      if (!isRecord(option)) return [];
      const id = asString(option.optionId);
      const label = asString(option.name);
      if (id === null || label === null) return [];
      return [{ id, label, kind: asString(option.kind) }];
    },
  );
  let details = emptyToolDetails();
  if (tool !== null) {
    const toolCallID = asString(tool.toolCallId);
    const known = toolCallID === null
      ? undefined
      : conversation.messages.find((message) => message.id === `tool:${toolCallID}`);
    if (known !== undefined) details = known.toolDetails;
    details = mergeToolDetails(details, tool);
  }
  return {
    id: requestID,
    title: (tool !== null ? asString(tool.title) : null) ?? "Allow the Agent to continue?",
    choices,
    details,
  };
}

/** Title shown while a brand-new conversation has no agent-reported title yet. */
export function provisionalTitle(text: string): string {
  const line = text.trim().split("\n")[0] ?? "";
  return line.length > 60 ? `${line.slice(0, 60)}…` : line;
}

/** A turn that stopped early must say why instead of looking like a normal end. */
export function stopReasonMessage(stopReason: string | null): string | null {
  switch (stopReason) {
    case null:
    case "end_turn":
      return null;
    case "cancelled":
      return "The response was cancelled.";
    case "max_tokens":
      return "The Agent stopped at its output limit.";
    case "max_turn_requests":
      return "The Agent stopped at its request limit for this turn.";
    case "refusal":
      return "The Agent refused to continue.";
    default:
      return `The Agent stopped: ${stopReason}.`;
  }
}

/** One message including the attached files, which are not copied into the text. */
export function promptDisplayText(prompt: AgentPrompt): string {
  return [prompt.text, ...prompt.files.map((file) => `📎 ${file.uri}`)]
    .filter((part) => part.length > 0)
    .join("\n\n");
}

export class AgentFileReferenceError extends Error {}

function parseFileReference(uri: string): AgentFileReference {
  let url: URL;
  try {
    url = new URL(uri);
  } catch {
    throw new AgentFileReferenceError("Only local files can be attached to an Agent message.");
  }
  const host = url.hostname;
  if (url.protocol !== "file:" || (host !== "" && host !== "localhost") || url.search !== "" || url.hash !== "") {
    throw new AgentFileReferenceError("Only local files can be attached to an Agent message.");
  }
  if (url.pathname === "") {
    throw new AgentFileReferenceError("Only local files can be attached to an Agent message.");
  }
  const name = decodeURIComponent(url.pathname.split("/").pop() ?? "");
  return { uri: url.href, name };
}

/**
 * Add dropped files in order, rejecting an invalid batch atomically and keeping
 * the draft bounded, so a bad drop cannot silently drop earlier attachments.
 */
export function addFileReferences(existing: AgentFileReference[], uris: string[]): AgentFileReference[] {
  const result = existing.slice();
  const seen = new Set(result.map((file) => file.uri));
  for (const uri of uris) {
    const file = parseFileReference(uri);
    if (!seen.has(file.uri)) {
      seen.add(file.uri);
      result.push(file);
    }
    if (result.length > AGENT_FILE_LIMIT) {
      throw new AgentFileReferenceError("Attach up to 32 files per message.");
    }
  }
  return result;
}
