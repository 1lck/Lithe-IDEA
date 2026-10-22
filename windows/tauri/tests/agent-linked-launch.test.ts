import { afterEach, expect, mock, test } from "bun:test";
import { DEFAULT_AGENT_PANEL_SETTINGS } from "../src/features/agent/types/agent-settings.types";

let generation = 0;
let fail = false;
let savedKeyReads = 0;
mock.module("@/platform/agent-cli-configuration", () => ({ readAgentCliSnapshot: async () => {
  if (fail) throw new Error("fixture-secret");
  generation += 1;
  return { configuration: String(generation), authentication: JSON.stringify({ OPENAI_API_KEY: `fixture-key-${generation}` }) };
} }));
mock.module("@/platform/tauri-core", () => ({ invoke: async (command: string, payload: { configuration: string }) => {
  if (command === "get_secure_secret") { savedKeyReads += 1; return "stale-key"; }
  return { apiProtocol: "responses", endpoint: `https://provider-${payload.configuration}.example.test/v1`, model: `model-${payload.configuration}` };
} }));
const { loadAgentLaunch, settingsWithLinkedAgentProvider } = await import("../src/features/agent/services/agent-launch");
afterEach(() => { fail = false; generation = 0; savedKeyReads = 0; });
const inputs = () => ({ workspacePath: "C:/fixture", dataDirectory: "C:/fixture-data", settings: {
  ...DEFAULT_AGENT_PANEL_SETTINGS, enabled: true,
  provider: { ...DEFAULT_AGENT_PANEL_SETTINGS.provider, source: "codex" as const },
} });

test("each connection reads matching fresh metadata and key without saved-key fallback", async () => {
  for (const index of [1, 2]) {
    const launch = await loadAgentLaunch(inputs());
    expect(launch.provider?.baseUrl).toBe(`https://provider-${index}.example.test/v1`);
    expect(launch.provider?.apiKey).toBe(`fixture-key-${index}`);
    expect(launch.provider?.model).toBe(`model-${index}`);
  }
  expect(savedKeyReads).toBe(0);
});
test("missing linked configuration fails with a fixed message instead of using saved credentials", async () => {
  fail = true;
  await expect(loadAgentLaunch(inputs())).rejects.toMatchObject({ failure: "invalidCliConfiguration" });
  expect(savedKeyReads).toBe(0);
});

test("linked metadata refresh keeps credential identity and unrelated provider choices", async () => {
  const input = inputs();
  const other = { ...input.settings.provider, id: "other", name: "Other" };
  const settings = { ...input.settings, provider: { ...input.settings.provider, id: "linked", name: "Local", allowInsecureHttp: true }, providers: [other] };
  const launch = await loadAgentLaunch({ ...input, settings });
  const next = settingsWithLinkedAgentProvider(settings, launch);
  expect(next.provider).toMatchObject({ id: "linked", source: "codex", name: "Local", allowInsecureHttp: true, model: "model-1" });
  expect(next.providers?.find((provider) => provider.id === "other")).toEqual(other);
  expect(settingsWithLinkedAgentProvider(next, launch)).toBe(next);
  expect(next).not.toHaveProperty("apiKey");
});
