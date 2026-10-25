import { describe, expect, test } from "bun:test";
import {
  CLAUDE_AGENT_ID,
  CODEX_AGENT_ID,
  CUSTOM_AGENT_ID,
  DEFAULT_AGENT_PANEL_SETTINGS,
  defaultAgentProvider,
  normalizeAgentPanelSettings,
  providerAfterAgentChange,
  selectAgentConfiguration,
  addAgentProvider,
  removeAgentProvider,
  updateAgentProvider,
  agentProviders,
} from "./agent-settings.types";

describe("Agent provider defaults", () => {
  test("named providers retain their metadata through selection, persistence and removal", () => {
    const original = normalizeAgentPanelSettings({ ...DEFAULT_AGENT_PANEL_SETTINGS,
      provider: { ...defaultAgentProvider(CODEX_AGENT_ID), id: "first", name: "First" } });
    const added = addAgentProvider(original);
    expect(agentProviders(added)).toHaveLength(2);
    expect(added.provider.id).not.toBe("first");
    const saved = normalizeAgentPanelSettings(added);
    expect(agentProviders(saved).find((provider) => provider.id === "first")?.name).toBe("First");
    expect(removeAgentProvider(saved).provider.id).toBe("first");
    expect(selectAgentConfiguration(saved, CLAUDE_AGENT_ID).providers).toEqual([]);
  });
  test("endpoint changes rotate the credential owner, names and models do not", () => {
    const settings = normalizeAgentPanelSettings(DEFAULT_AGENT_PANEL_SETTINGS);
    const renamed = updateAgentProvider(settings, { ...settings.provider, name: "Renamed", model: "custom" });
    expect(renamed.provider.id).toBe(settings.provider.id);
    const moved = updateAgentProvider(renamed, { ...renamed.provider, baseUrl: "https://example.test/v1" });
    expect(moved.provider.id).toBeDefined();
    expect(agentProviders(moved)).toHaveLength(1);
    expect(agentProviders(moved)[0].id).toBe(moved.provider.id);
  });
  test("normalization deduplicates providers and enforces the provider limit", () => {
    const settings = normalizeAgentPanelSettings({ providers: [{ id: "same" }, { id: "same" }, null, false] });
    expect(settings.providers).toHaveLength(1);
    const full = normalizeAgentPanelSettings({ provider: { id: "p0" },
      providers: Array.from({ length: 32 }, (_, index) => ({ id: `p${index}` })) });
    expect(addAgentProvider(full)).toBe(full);
  });
  test("switching Agents roundtrips their independent provider, authentication and observation settings", () => {
    const codex = normalizeAgentPanelSettings({ ...DEFAULT_AGENT_PANEL_SETTINGS,
      authentication: "codexSubscription", observeModelCalls: false,
      provider: { ...defaultAgentProvider(CODEX_AGENT_ID), baseUrl: "https://codex.example.test", model: "codex-custom" },
    });
    const claude = selectAgentConfiguration(codex, CLAUDE_AGENT_ID);
    expect(claude.authentication).toBe("apiKey");
    expect(claude.provider).toEqual(defaultAgentProvider(CLAUDE_AGENT_ID));
    claude.provider = { ...claude.provider, baseUrl: "https://claude.example.test", model: "claude-custom" };
    const restored = selectAgentConfiguration(normalizeAgentPanelSettings(claude), CODEX_AGENT_ID);
    expect(restored.provider).toEqual(codex.provider);
    expect(restored.authentication).toBe("codexSubscription");
    expect(restored.observeModelCalls).toBe(false);
    expect(selectAgentConfiguration(restored, CLAUDE_AGENT_ID).provider).toEqual(claude.provider);
  });

  test("import normalization bounds saved configurations and removes nested maps", () => {
    const configurations = Object.fromEntries(Array.from({ length: 40 }, (_, index) => [
      `agent-${index}`, { command: `agent-${index}`, configurations: { recursive: {} } },
    ]));
    const saved = normalizeAgentPanelSettings({ configurations }).configurations!;
    expect(Object.keys(saved)).toHaveLength(32);
    expect(saved["agent-0"].command).toBe("agent-0");
    expect(saved["agent-0"]).not.toHaveProperty("configurations");
  });

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
