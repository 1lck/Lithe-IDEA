/**
 * Agent panel configuration as the Windows workbench persists it.
 *
 * The active configuration stays flat for persisted-settings compatibility;
 * inactive configurations retain each Agent's provider and authentication.
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
  /** Read a fresh CLI snapshot at connection time; credentials are never persisted here. */
  source?: "codex" | "claude";
  /** Stable credential owner. Absent only for the migrated single-provider entry. */
  id?: string;
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
  observeModelCalls?: boolean;
  provider: AgentProviderSettings;
  providers?: AgentProviderSettings[];
  configurations?: Record<string, AgentConfiguration>;
}

export type AgentConfiguration = Pick<AgentPanelSettings,
  "command" | "arguments" | "authentication" | "observeModelCalls" | "provider" | "providers">;

function configuration(settings: AgentPanelSettings): AgentConfiguration {
  const { command, arguments: args, authentication, observeModelCalls, provider, providers } = settings;
  return { command, arguments: args, authentication, observeModelCalls, provider: { ...provider }, providers };
}

/** Capture the active draft before selecting another named provider. */
export function agentProviders(settings: AgentPanelSettings): AgentProviderSettings[] {
  const entries = new Map<string | undefined, AgentProviderSettings>();
  for (const provider of settings.providers ?? []) entries.set(provider.id, provider);
  entries.set(settings.provider.id, settings.provider);
  return [...entries.values()];
}

/** A changed endpoint has a new credential owner, including legacy entries. */
export function updateAgentProvider(settings: AgentPanelSettings, provider: AgentProviderSettings): AgentPanelSettings {
  const changedEndpoint = settings.provider.baseUrl.trim() !== provider.baseUrl.trim();
  const next = changedEndpoint ? { ...provider, id: crypto.randomUUID() } : provider;
  return { ...settings, provider: next, providers: agentProviders(settings).map((entry) =>
    entry.id === settings.provider.id ? next : entry) };
}

export function addAgentProvider(settings: AgentPanelSettings): AgentPanelSettings {
  if (agentProviders(settings).length >= 32) return settings;
  const provider = { ...defaultAgentProvider(settings.agentId), id: crypto.randomUUID() };
  return { ...settings, provider, providers: [...agentProviders(settings), provider] };
}

export function removeAgentProvider(settings: AgentPanelSettings): AgentPanelSettings {
  const providers = agentProviders(settings).filter((entry) => entry.id !== settings.provider.id);
  return { ...settings, providers, provider: providers[0] ?? { ...defaultAgentProvider(settings.agentId), id: crypto.randomUUID() } };
}

/** Save the outgoing Agent before restoring the destination's own settings. */
export function selectAgentConfiguration(settings: AgentPanelSettings, agentId: string): AgentPanelSettings {
  if (settings.agentId === agentId) return settings;
  const configurations = { ...settings.configurations, [settings.agentId]: configuration(settings) };
  const next = configurations[agentId] ?? {
    command: "", arguments: "", authentication: "apiKey", observeModelCalls: true,
    provider: defaultAgentProvider(agentId), providers: [],
  };
  return { ...settings, ...next, agentId, configurations };
}

export function configuredAgentIDs(settings: AgentPanelSettings): string[] {
  return [...new Set([settings.agentId, ...Object.keys(settings.configurations ?? {})])].filter((id) => {
    const candidate = selectAgentConfiguration(settings, id);
    return id === CUSTOM_AGENT_ID ? candidate.command.trim().length > 0 :
      candidate.authentication === "codexSubscription" || candidate.provider.baseUrl.trim().length > 0;
  });
}

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

export const DEFAULT_AGENT_PROVIDER_SETTINGS: AgentProviderSettings = {
  protocol: "responses",
  baseUrl: "",
  model: "",
  name: "",
  allowInsecureHttp: false,
};

/** Model a newly added built-in provider starts from, as macOS does. */
export const DEFAULT_AGENT_MODELS: Record<string, string> = {
  [CODEX_AGENT_ID]: "gpt-6.1-sol",
  [CLAUDE_AGENT_ID]: "claude-fable-5-1",
};

export function defaultAgentModel(agentId: string): string {
  return DEFAULT_AGENT_MODELS[agentId] ?? "";
}

export function defaultAgentProvider(agentId: string): AgentProviderSettings {
  return {
    ...DEFAULT_AGENT_PROVIDER_SETTINGS,
    protocol: AGENT_PROTOCOL_BY_ID[agentId] ?? DEFAULT_AGENT_PROVIDER_SETTINGS.protocol,
    model: defaultAgentModel(agentId),
  };
}

/**
 * Switching adapters keeps a model the user typed, and only replaces the
 * previous adapter's own default. An empty field is a new provider.
 */
export function providerAfterAgentChange(
  provider: AgentProviderSettings,
  previousAgentId: string,
  agentId: string,
): AgentProviderSettings {
  const model = provider.model.trim();
  const previousDefault = defaultAgentModel(previousAgentId);
  if (model.length > 0 && model !== previousDefault) return provider;
  return { ...provider, model: defaultAgentModel(agentId) };
}

export const DEFAULT_AGENT_PANEL_SETTINGS: AgentPanelSettings = {
  enabled: false,
  agentId: CODEX_AGENT_ID,
  command: "",
  arguments: "",
  authentication: "apiKey",
  observeModelCalls: true,
  provider: defaultAgentProvider(CODEX_AGENT_ID),
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

function normalizeProvider(value: unknown, agentId: string): AgentProviderSettings {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return defaultAgentProvider(agentId);
  }
  const record = value as Record<string, unknown>;
  const protocol = record.protocol;
  return {
    source: record.source === "codex" || record.source === "claude" ? record.source : undefined,
    id: typeof record.id === "string" && /^[a-zA-Z0-9-]{1,64}$/.test(record.id) ? record.id : undefined,
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
    return normalizeAgentPanelSettings(DEFAULT_AGENT_PANEL_SETTINGS);
  }
  const record = value as Record<string, unknown>;
  const agentId = asString(record.agentId, DEFAULT_AGENT_PANEL_SETTINGS.agentId).trim();
  const authentication = record.authentication;
  const configurations: Record<string, AgentConfiguration> = {};
  if (typeof record.configurations === "object" && record.configurations !== null && !Array.isArray(record.configurations)) {
    for (const [id, saved] of Object.entries(record.configurations).slice(0, 32)) {
      if (id.length === 0 || typeof saved !== "object" || saved === null || Array.isArray(saved)) continue;
      configurations[id] = configuration(normalizeAgentPanelSettings({ ...saved, agentId: id, configurations: undefined }));
    }
  }
  return {
    enabled: asBoolean(record.enabled, DEFAULT_AGENT_PANEL_SETTINGS.enabled),
    agentId: agentId.length > 0 ? agentId : DEFAULT_AGENT_PANEL_SETTINGS.agentId,
    command: asString(record.command, DEFAULT_AGENT_PANEL_SETTINGS.command),
    arguments: asString(record.arguments, DEFAULT_AGENT_PANEL_SETTINGS.arguments),
    observeModelCalls: asBoolean(record.observeModelCalls, true),
    authentication:
      authentication === "codexSubscription" || authentication === "apiKey"
        ? authentication
        : DEFAULT_AGENT_PANEL_SETTINGS.authentication,
    // A persisted provider, including an intentionally empty model, is kept.
    provider: normalizeProvider(record.provider, agentId),
    providers: Array.isArray(record.providers) ? [...new Map(record.providers.slice(0, 32)
      .filter((entry) => typeof entry === "object" && entry !== null && !Array.isArray(entry))
      .map((entry) => normalizeProvider(entry, agentId)).map((provider) => [provider.id, provider])).values()] : [],
    configurations,
  };
}
