/**
 * Import Agent provider metadata from pasted CLI configuration text.
 *
 * The parse itself belongs to the shared Rust core
 * (`agent.parseProviderConfiguration`), which returns provider metadata only:
 * endpoint, model and wire protocol, with no credentials or credential
 * presence. Lithe therefore never copies a key out of the user's CLI files;
 * the panel asks for one separately when the endpoint needs it.
 */

import { invoke } from "@/platform/tauri-core";
import {
  AGENT_PROTOCOL_BY_ID,
  CLAUDE_AGENT_ID,
  CODEX_AGENT_ID,
  type AgentProviderProtocol,
} from "../types/agent-settings.types";

/** CLI configuration formats the shared parser understands. */
export type AgentProviderConfigSource = "codex" | "claude";

/** Provider metadata the shared parser extracted from pasted configuration. */
export interface ImportedAgentProvider {
  protocol: AgentProviderProtocol;
  baseUrl: string;
  model: string;
}

/** Which CLI format describes the local configuration of a catalog agent. */
export function agentProviderConfigSource(agentId: string): AgentProviderConfigSource | null {
  if (agentId === CODEX_AGENT_ID) return "codex";
  if (agentId === CLAUDE_AGENT_ID) return "claude";
  return null;
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

/**
 * Read the documented parser response, or `null` when it does not carry the
 * metadata the panel needs. `chatCompletions` is a valid provider protocol but
 * has no Agent settings equivalent, so it is rejected instead of being
 * silently rewritten into another protocol.
 */
export function parseImportedAgentProvider(value: unknown): ImportedAgentProvider | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const endpoint = (asString(record.endpoint) ?? "").trim();
  const model = (asString(record.model) ?? "").trim();
  const protocol = record.apiProtocol;
  if (endpoint.length === 0 || model.length === 0) return null;
  if (protocol !== "responses" && protocol !== "anthropicMessages") return null;
  return { protocol, baseUrl: endpoint, model };
}

/** Whether imported metadata speaks the protocol the selected adapter expects. */
export function importedProviderMatchesAgent(
  agentId: string,
  provider: ImportedAgentProvider,
): boolean {
  const expected = AGENT_PROTOCOL_BY_ID[agentId];
  return expected === undefined || expected === provider.protocol;
}

/** Parse pasted CLI configuration into provider metadata through the shared core. */
export async function importAgentProviderConfiguration(
  source: AgentProviderConfigSource,
  configuration: string,
): Promise<ImportedAgentProvider> {
  const response = await invoke<unknown>("agent.parseProviderConfiguration", {
    source,
    configuration,
  });
  const provider = parseImportedAgentProvider(response);
  if (provider === null) throw new Error("The provider configuration could not be read.");
  return provider;
}
