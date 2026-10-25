import type { AgentProviderConfigSource } from "./agent-provider-import";

const LIMIT = 64 * 1024;
const invalid = () => new Error("The CLI API-key configuration is missing or unsupported.");

/** Extract only explicit API keys. Subscription, cloud and helper authentication stay unsupported. */
export function agentProviderCredential(source: AgentProviderConfigSource, configuration: string, authentication: string): string {
  if (new TextEncoder().encode(configuration).length > LIMIT || new TextEncoder().encode(authentication).length > LIMIT) throw invalid();
  try {
    const object: unknown = JSON.parse(source === "codex" ? authentication || "{}" : configuration);
    if (!object || typeof object !== "object" || Array.isArray(object)) throw invalid();
    const record = object as Record<string, unknown>;
    if (source === "codex") {
      const key = record.OPENAI_API_KEY ?? record.api_key;
      if (key !== undefined && typeof key !== "string") throw invalid();
      return typeof key === "string" ? key.trim() : "";
    }
    const env = record.env && typeof record.env === "object" && !Array.isArray(record.env) ? record.env as Record<string, unknown> : {};
    // These routes can override an explicit API key in Claude Code; do not silently import them.
    if ([record.apiKeyHelper, record.authToken, env.ANTHROPIC_AUTH_TOKEN, env.ANTHROPIC_CUSTOM_HEADERS,
      env.CLAUDE_CODE_USE_BEDROCK, env.CLAUDE_CODE_USE_VERTEX, env.CLAUDE_CODE_USE_FOUNDRY]
      .some((value) => typeof value === "string" ? value.trim() !== "" && value !== "0" && value !== "false" : Boolean(value))) throw invalid();
    const key = [env.ANTHROPIC_API_KEY, record.apiKey].find((value) => typeof value === "string" && value.trim().length > 0);
    return typeof key === "string" ? key.trim() : "";
  } catch {
    // JSON diagnostics can contain credentials; expose only a fixed message.
    throw invalid();
  }
}
