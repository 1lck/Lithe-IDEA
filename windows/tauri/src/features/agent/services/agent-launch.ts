/**
 * Turn panel settings into the shared `AgentLaunch` payload.
 *
 * The rules mirror `AppModel.agentLaunchConfiguration(agentID:)` on macOS: a
 * Codex subscription launch carries no provider at all, an API-key launch needs
 * an endpoint and a key, and the custom agent needs an executable. Failures are
 * returned as typed kinds so the panel can show a translated reason instead of a
 * host error, and so nothing here depends on the current UI language.
 */

import { invoke } from "@/platform/tauri-core";
import {
  AGENT_PROTOCOL_BY_ID,
  CUSTOM_AGENT_ID,
  supportsCodexSubscription,
  type AgentPanelSettings,
} from "../types/agent-settings.types";
import type { AgentLaunchConfiguration } from "./agent-transport";

export type AgentLaunchFailure =
  | "disabled"
  | "noAgent"
  | "missingProvider"
  | "missingApiKey"
  | "missingCommand"
  | "subscriptionNeedsCodex";

export class AgentLaunchError extends Error {
  readonly failure: AgentLaunchFailure;

  constructor(failure: AgentLaunchFailure, message: string) {
    super(message);
    this.name = "AgentLaunchError";
    this.failure = failure;
  }
}

export interface AgentLaunchInputs {
  workspacePath: string;
  /** Platform data root; the host appends `agents/<id>` itself. */
  dataDirectory: string;
  settings: AgentPanelSettings;
  /** Provider key read from the secure store, empty in subscription mode. */
  apiKey: string;
}

/** Keychain entry holding one agent's provider key. */
export function agentApiKeyName(agentId: string): string {
  return `agent-provider-api-key/${agentId.trim() || CUSTOM_AGENT_ID}`;
}

export async function readAgentApiKey(agentId: string): Promise<string> {
  const value = await invoke<string | null>("get_secure_secret", {
    key: agentApiKeyName(agentId),
  });
  return (value ?? "").trim();
}

export async function storeAgentApiKey(agentId: string, apiKey: string): Promise<void> {
  const key = agentApiKeyName(agentId);
  const trimmed = apiKey.trim();
  if (trimmed.length === 0) {
    await invoke("remove_secure_secret", { key });
    return;
  }
  await invoke("store_secure_secret", { key, value: trimmed });
}

/** Protocol the selected adapter speaks; the host rejects a mismatch. */
export function agentProtocolFor(agentId: string): "responses" | "anthropicMessages" {
  return AGENT_PROTOCOL_BY_ID[agentId] ?? "responses";
}

/**
 * One argument per line, matching macOS `agentArguments`. Arguments reach the
 * process without shell parsing, so a line may contain spaces.
 */
export function agentArguments(value: string): string[] {
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

export function resolveAgentLaunch(inputs: AgentLaunchInputs): AgentLaunchConfiguration {
  const { settings } = inputs;
  if (!settings.enabled) {
    throw new AgentLaunchError("disabled", "The Agent panel is turned off.");
  }
  if (settings.agentId.trim().length === 0) {
    throw new AgentLaunchError("noAgent", "No Agent is selected.");
  }
  const workspacePath = inputs.workspacePath.trim();
  if (workspacePath.length === 0) {
    throw new AgentLaunchError("noAgent", "Open a project before starting the Agent.");
  }
  if (settings.authentication === "codexSubscription") {
    if (!supportsCodexSubscription(settings.agentId)) {
      throw new AgentLaunchError(
        "subscriptionNeedsCodex",
        "Only the Codex adapter can use a ChatGPT subscription.",
      );
    }
    return {
      agentId: settings.agentId,
      command: null,
      args: [],
      cwd: workspacePath,
      dataDirectory: inputs.dataDirectory,
      authentication: "codexSubscription",
      provider: null,
    };
  }
  const isCustom = settings.agentId === CUSTOM_AGENT_ID;
  const command = settings.command.trim();
  if (isCustom && command.length === 0) {
    throw new AgentLaunchError(
      "missingCommand",
      "Set the ACP Agent executable before starting a conversation.",
    );
  }
  const baseUrl = settings.provider.baseUrl.trim();
  if (baseUrl.length === 0) {
    throw new AgentLaunchError(
      "missingProvider",
      "The Agent needs a provider endpoint. Add one in Agent settings.",
    );
  }
  const apiKey = inputs.apiKey.trim();
  if (apiKey.length === 0) {
    throw new AgentLaunchError(
      "missingApiKey",
      "Add the provider's API key in Agent settings.",
    );
  }
  return {
    agentId: isCustom ? null : settings.agentId,
    command: isCustom ? command : null,
    args: isCustom ? agentArguments(settings.arguments) : [],
    cwd: workspacePath,
    dataDirectory: inputs.dataDirectory,
    authentication: "apiKey",
    provider: {
      protocol: agentProtocolFor(settings.agentId),
      baseUrl,
      apiKey,
      name: settings.provider.name.trim() || null,
      model: settings.provider.model.trim() || null,
      allowInsecureHttp: settings.provider.allowInsecureHttp,
    },
  };
}

/** Read the key, then resolve; rejects with `AgentLaunchError` when incomplete. */
export async function loadAgentLaunch(inputs: Omit<AgentLaunchInputs, "apiKey">): Promise<AgentLaunchConfiguration> {
  if (inputs.settings.authentication === "codexSubscription") {
    return resolveAgentLaunch({ ...inputs, apiKey: "" });
  }
  return resolveAgentLaunch({ ...inputs, apiKey: await readAgentApiKey(inputs.settings.agentId) });
}
