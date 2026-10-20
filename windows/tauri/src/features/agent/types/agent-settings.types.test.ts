import { describe, expect, test } from "bun:test";
import {
  CLAUDE_AGENT_ID,
  CODEX_AGENT_ID,
  CUSTOM_AGENT_ID,
  DEFAULT_AGENT_PANEL_SETTINGS,
  defaultAgentProvider,
  normalizeAgentPanelSettings,
  providerAfterAgentChange,
} from "./agent-settings.types";

describe("Agent provider defaults", () => {
  test("a new Codex or Claude provider starts from the macOS default model", () => {
    expect(DEFAULT_AGENT_PANEL_SETTINGS.provider.model).toBe("gpt-6.1-sol");
    expect(defaultAgentProvider(CODEX_AGENT_ID)).toMatchObject({
      protocol: "responses",
      model: "gpt-6.1-sol",
    });
    expect(defaultAgentProvider(CLAUDE_AGENT_ID)).toMatchObject({
      protocol: "anthropicMessages",
      model: "claude-fable-5-1",
    });
    expect(defaultAgentProvider(CUSTOM_AGENT_ID)).toMatchObject({
      protocol: "responses",
      model: "",
    });
  });

  test("a missing provider is filled, but a saved empty model stays empty", () => {
    expect(normalizeAgentPanelSettings({ agentId: CLAUDE_AGENT_ID }).provider.model).toBe(
      "claude-fable-5-1",
    );
    expect(
      normalizeAgentPanelSettings({
        agentId: CLAUDE_AGENT_ID,
        provider: {
          protocol: "anthropicMessages",
          baseUrl: "",
          model: "",
          name: "",
          allowInsecureHttp: false,
        },
      }).provider.model,
    ).toBe("");
  });

  test("switching adapters keeps a typed model and replaces only a built-in default", () => {
    const empty = {
      protocol: "responses" as const,
      baseUrl: "https://example.test/v1",
      model: "",
      name: "",
      allowInsecureHttp: false,
    };
    expect(providerAfterAgentChange(empty, CODEX_AGENT_ID, CLAUDE_AGENT_ID).model).toBe(
      "claude-fable-5-1",
    );
    expect(
      providerAfterAgentChange(
        { ...empty, model: "gpt-6.1-sol" },
        CODEX_AGENT_ID,
        CLAUDE_AGENT_ID,
      ).model,
    ).toBe("claude-fable-5-1");
    expect(
      providerAfterAgentChange(
        { ...empty, protocol: "anthropicMessages", model: "custom-model" },
        CLAUDE_AGENT_ID,
        CODEX_AGENT_ID,
      ).model,
    ).toBe("custom-model");
  });
});
