import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/provider-configuration-v1.json";
import {
  agentProviderConfigSource,
  importedProviderMatchesAgent,
  parseImportedAgentProvider,
} from "./agent-provider-import";

const [codexCase, claudeCase] = fixture.cases;

describe("Imported Agent provider metadata", () => {
  test("reads the metadata the shared parser reported for each format", () => {
    expect(parseImportedAgentProvider(codexCase?.expected)).toEqual({
      protocol: "responses",
      baseUrl: "https://example.test/v1",
      model: "fixture-model",
    });
    expect(parseImportedAgentProvider(claudeCase?.expected)).toEqual({
      protocol: "anthropicMessages",
      baseUrl: "https://example.test/v1",
      model: "fixture-model",
    });
  });

  test("an unsupported or incomplete response is rejected instead of filled in", () => {
    // `chatCompletions` has no Agent settings equivalent; guessing a protocol
    // would silently send prompts to the wrong wire format.
    expect(
      parseImportedAgentProvider({
        endpoint: "https://example.test/v1",
        model: "fixture-model",
        apiProtocol: "chatCompletions",
      }),
    ).toBeNull();
    expect(parseImportedAgentProvider({ endpoint: "", model: "m", apiProtocol: "responses" })).toBeNull();
    expect(parseImportedAgentProvider({ endpoint: "https://x.test", model: " " })).toBeNull();
    expect(parseImportedAgentProvider(null)).toBeNull();
    expect(parseImportedAgentProvider("responses")).toBeNull();
  });
});

describe("CLI configuration source of an agent", () => {
  test("only the catalog agents that own a CLI format are importable", () => {
    expect(agentProviderConfigSource("codex-acp")).toBe("codex");
    expect(agentProviderConfigSource("claude-acp")).toBe("claude");
    expect(agentProviderConfigSource("custom")).toBeNull();
  });

  test("imported metadata must speak the selected adapter's protocol", () => {
    const responses = {
      protocol: "responses" as const,
      baseUrl: "https://example.test/v1",
      model: "fixture-model",
    };
    expect(importedProviderMatchesAgent("codex-acp", responses)).toBe(true);
    expect(importedProviderMatchesAgent("claude-acp", responses)).toBe(false);
    // A custom adapter declares no protocol here, so the user's choice stands.
    expect(importedProviderMatchesAgent("custom", responses)).toBe(true);
  });
});
