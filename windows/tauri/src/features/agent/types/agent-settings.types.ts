/**
 * Agent panel configuration as the Windows workbench persists it.
 *
 * macOS keeps one configuration per agent id. Windows starts from one active
 * agent plus one provider, because the panel only talks to the adapter the user
 * selected; the shape stays flat so a later per-agent map is a pure widening.
 */

export type AgentAuthenticationMode = "apiKey" | "codexSubscription";

/** Wire protocol of the provider behind an adapter. */
export type AgentProviderProtocol = "responses" | "anthropicMessages";

/** Built-in adapter id used for a user-supplied ACP executable. */
export const CUSTOM_AGENT_ID = "custom";

export const CODEX_AGENT_ID = "codex-acp";

/** Built-in adapter id for the Claude Code CLI. */
export const CLAUDE_AGENT_ID = "claude-acp";

export interface AgentProviderSettings {
  protocol: AgentProviderProtocol;
  /** Endpoint as configured, with or without the protocol's path suffix. */
  baseUrl: string;
  /** Model to request; empty keeps the adapter's own default. */
  model: string;
  /** Label shown in settings and in the panel header. */
  name: string;
  /** Allow a plain `http` endpoint the user explicitly opted into. */
  allowInsecureHttp: boolean;
}

export interface AgentPanelSettings {
  /** Off until the user turns it on, matching the macOS module default. */
  enabled: boolean;
  /** Catalog id, or `custom` for an ACP executable the user supplies. */
  agentId: string;
  /** Executable used when `agentId` is the custom agent. */
  command: string;
  /** One argument per line, as macOS `agentArguments` stores it. */
  arguments: string;
  authentication: AgentAuthenticationMode;
  provider: AgentProviderSettings;
}

export const DEFAULT_AGENT_PROVIDER_SETTINGS: AgentProviderSettings = {
  protocol: "responses",
  baseUrl: "",
  model: "",
  name: "",
  allowInsecureHttp: false,
};

export const DEFAULT_AGENT_PANEL_SETTINGS: AgentPanelSettings = {
  enabled: false,
  agentId: CODEX_AGENT_ID,
  command: "",
  arguments: "",
  authentication: "apiKey",
  provider: DEFAULT_AGENT_PROVIDER_SETTINGS,
};

/**
 * Protocol each built-in adapter speaks. The shared host rejects a mismatch, so
 * the panel derives the protocol from the selected agent instead of letting the
 * two drift apart in settings.
 */
export const AGENT_PROTOCOL_BY_ID: Record<string, AgentProviderProtocol> = {
  "codex-acp": "responses",
  "claude-acp": "anthropicMessages",
  [CUSTOM_AGENT_ID]: "responses",
};

/** Codex is the only adapter with an official ChatGPT subscription route. */
export function supportsCodexSubscription(agentId: string): boolean {
  return agentId === CODEX_AGENT_ID;
}

function asString(value: unknown, fallback: string): string {
  return typeof value === "string" ? value : fallback;
}

function asBoolean(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function normalizeProvider(value: unknown): AgentProviderSettings {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ...DEFAULT_AGENT_PROVIDER_SETTINGS };
  }
  const record = value as Record<string, unknown>;
  const protocol = record.protocol;
  return {
    protocol:
      protocol === "anthropicMessages" || protocol === "responses"
        ? protocol
        : DEFAULT_AGENT_PROVIDER_SETTINGS.protocol,
    baseUrl: asString(record.baseUrl, DEFAULT_AGENT_PROVIDER_SETTINGS.baseUrl),
    model: asString(record.model, DEFAULT_AGENT_PROVIDER_SETTINGS.model),
    name: asString(record.name, DEFAULT_AGENT_PROVIDER_SETTINGS.name),
    allowInsecureHttp: asBoolean(
      record.allowInsecureHttp,
      DEFAULT_AGENT_PROVIDER_SETTINGS.allowInsecureHttp,
    ),
  };
}

/** Merge a persisted or imported value with the defaults, dropping unknown shapes. */
export function normalizeAgentPanelSettings(value: unknown): AgentPanelSettings {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ...DEFAULT_AGENT_PANEL_SETTINGS };
  }
  const record = value as Record<string, unknown>;
  const agentId = asString(record.agentId, DEFAULT_AGENT_PANEL_SETTINGS.agentId).trim();
  const authentication = record.authentication;
  return {
    enabled: asBoolean(record.enabled, DEFAULT_AGENT_PANEL_SETTINGS.enabled),
    agentId: agentId.length > 0 ? agentId : DEFAULT_AGENT_PANEL_SETTINGS.agentId,
    command: asString(record.command, DEFAULT_AGENT_PANEL_SETTINGS.command),
    arguments: asString(record.arguments, DEFAULT_AGENT_PANEL_SETTINGS.arguments),
    authentication:
      authentication === "codexSubscription" || authentication === "apiKey"
        ? authentication
        : DEFAULT_AGENT_PANEL_SETTINGS.authentication,
    provider: normalizeProvider(record.provider),
  };
}
