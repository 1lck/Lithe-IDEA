import { describe, expect, test } from "bun:test";
import { agentProviderCredential } from "./agent-provider-credentials";

describe("Ephemeral Agent CLI credentials", () => {
  test("Codex reads explicit auth JSON keys and preserves missing-key state", () => {
    expect(agentProviderCredential("codex", "", '{"OPENAI_API_KEY":" fixture-key "}')).toBe("fixture-key");
    expect(agentProviderCredential("codex", "", '{"api_key":"fixture-key"}')).toBe("fixture-key");
    expect(agentProviderCredential("codex", "", '{"tokens":{"access_token":"fixture-token"}}')).toBe("");
  });
  test("Claude reads API keys and rejects routes that can override them", () => {
    expect(agentProviderCredential("claude", '{"env":{"ANTHROPIC_API_KEY":"fixture-key"}}', "")).toBe("fixture-key");
    expect(agentProviderCredential("claude", '{"apiKey":"fixture-key"}', "")).toBe("fixture-key");
    for (const configuration of [
      { env: { ANTHROPIC_API_KEY: "fixture-key", ANTHROPIC_AUTH_TOKEN: "fixture-token" } },
      { apiKey: "fixture-key", apiKeyHelper: "external-command" },
      { env: { CLAUDE_CODE_USE_BEDROCK: "1" } },
    ]) expect(() => agentProviderCredential("claude", JSON.stringify(configuration), "")).toThrow("unsupported");
  });
  test("bounded parse errors never quote the supplied credential", () => {
    for (const text of ['{"OPENAI_API_KEY":"fixture-secret', "[]", "x".repeat(65537)]) {
      let message = "";
      try { agentProviderCredential("codex", "", text); } catch (error) { message = String(error); }
      expect(message).toContain("unsupported");
      expect(message).not.toContain("fixture-secret");
    }
  });
});
