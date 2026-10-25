import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "../src/test-utils/happy-dom";
import { CLAUDE_AGENT_ID, CODEX_AGENT_ID, normalizeAgentPanelSettings, type AgentPanelSettings } from "../src/features/agent/types/agent-settings.types";
import type { AgentManagement } from "../src/features/agent/hooks/use-agent-management";

const restoreDom = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
const transactions: { before: AgentPanelSettings; next: AgentPanelSettings; key: { value: string } }[] = [];
let publish: (settings: AgentPanelSettings) => void;
let commits = 0;
mock.module("@/features/settings/stores/settings.store", () => ({ useSettingsStore: { use: {
  actions: () => ({ commitAgentProvider: async (before: AgentPanelSettings, next: AgentPanelSettings, key: { value: string }) => {
    transactions.push({ before, next, key });
    publish(next);
  } }),
  agentSettingsError: () => null,
} } }));
mock.module("@/features/agent/services/agent-launch", () => ({ readAgentApiKey: async () => "fixture-key" }));
mock.module("@/platform/tauri-core", () => ({ invoke: async (_command: string, args: { source: string; configuration: string }) => {
  if (args.source === "codex") return { apiProtocol: "responses", endpoint: "https://codex.example.test/v1", model: "imported-codex-model" };
  const config = JSON.parse(args.configuration).env;
  return { apiProtocol: "anthropicMessages", endpoint: config.ANTHROPIC_BASE_URL ?? "", model: config.ANTHROPIC_MODEL ?? "" };
} }));
mock.module("@/i18n/locale-provider", () => ({ useTranslation: () => ({ t: (key: string) => key }) }));
mock.module("@/features/keymaps/hooks/use-command-shortcut", () => ({ useCommandShortcut: () => undefined }));
const { createRoot } = await import("react-dom/client");
const { AgentSettingsSection } = await import("../src/features/agent/components/agent-settings-section");
const management = { status: null, error: null, busyAgentId: null, progress: null, cliUpdates: {}, isRefreshing: false } as AgentManagement;
let root: Root;
let container: HTMLDivElement;
let initial: AgentPanelSettings;

function Harness() {
  const [settings, setSettings] = useState(initial);
  publish = setSettings;
  return <AgentSettingsSection settings={settings} onChange={(next) => { commits++; setSettings(next); }}
    management={management} onReconnect={() => {}} canChangeAuthentication />;
}
async function click(label: string) {
  const button = [...container.querySelectorAll("button")].find((node) => node.textContent === label);
  if (!button) throw new Error(`Missing button ${label}`);
  await act(async () => { button.click(); });
}
async function input(label: string, value: string) {
  const node = container.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[aria-label="${label}"]`);
  if (!node) throw new Error(`Missing field ${label}`);
  const prototype = node.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
beforeEach(async () => {
  transactions.length = 0;
  commits = 0;
  initial = normalizeAgentPanelSettings({ agentId: CLAUDE_AGENT_ID, provider: {
    id: "fixture-provider", protocol: "anthropicMessages", name: "Fixture", baseUrl: "https://example.invalid", model: "fixture-model",
  } });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => { root.render(<Harness />); });
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
afterAll(() => { restoreDom(); if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT; else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct; });

test("cancel discards an added provider and edited credentials without publishing settings", async () => {
  await click("agent.settings.addProvider");
  await input("agent.settings.providerName", "Discard me");
  await input("agent.settings.apiKey", "discard-key");
  await click("ui.cancel");
  expect(transactions).toHaveLength(0);
  expect(commits).toBe(0);
  expect(container.querySelector<HTMLInputElement>('[aria-label="agent.settings.providerName"]')!.value).toBe("Fixture");
});

test("save commits the complete provider and credential once with its original CAS revision", async () => {
  await click("agent.settings.editProvider");
  await input("agent.settings.providerName", "Edited fixture");
  await input("agent.settings.apiKey", "edited-key");
  expect(transactions).toHaveLength(0);
  await click("ui.save");
  expect(transactions).toHaveLength(1);
  expect(transactions[0]!.before).toEqual(initial);
  expect(transactions[0]!.next.provider).toMatchObject({ id: "fixture-provider", name: "Edited fixture" });
  expect(transactions[0]!.key.value).toBe("edited-key");
  expect(JSON.stringify(transactions[0]!.next)).not.toContain("edited-key");
});

test("form and configuration text roundtrip keeps credentials in the unsaved editor", async () => {
  await click("agent.settings.editProvider");
  await click("agent.settings.textMode");
  const text = container.querySelector<HTMLTextAreaElement>('[aria-label="agent.settings.importConfiguration"]')!;
  expect(JSON.parse(text.value).env.ANTHROPIC_API_KEY).toBe("fixture-key");
  await input("agent.settings.importConfiguration", JSON.stringify({ env: { ANTHROPIC_MODEL: "partial-model" } }));
  await click("agent.settings.formMode");
  expect(container.querySelector<HTMLInputElement>('[aria-label="agent.settings.model"]')!.value).toBe("partial-model");
  expect(container.querySelector<HTMLInputElement>('[aria-label="agent.settings.apiKey"]')!.value).toBe("fixture-key");
  expect(transactions).toHaveLength(0);
  await click("ui.cancel");
});

for (const agentId of [CODEX_AGENT_ID, CLAUDE_AGENT_ID]) {
  test(`${agentId} text import can be saved immediately with its imported credential`, async () => {
    initial = normalizeAgentPanelSettings({ ...initial, agentId, provider: { ...initial.provider,
      protocol: agentId === CODEX_AGENT_ID ? "responses" : "anthropicMessages" } });
    await act(async () => { publish(initial); });
    await click("agent.settings.editProvider");
    await click("agent.settings.textMode");
    const source = agentId === CODEX_AGENT_ID ? "codex" : "claude";
    const endpoint = `https://${source}.example.test/v1`;
    const key = `imported-${source}-key`;
    await input("agent.settings.importConfiguration", source === "codex"
      ? `model_provider = "fixture"\nmodel = "imported-codex-model"\n[model_providers.fixture]\nbase_url = "${endpoint}"\nwire_api = "responses"\n`
      : JSON.stringify({ env: { ANTHROPIC_BASE_URL: endpoint, ANTHROPIC_MODEL: "imported-claude-model", ANTHROPIC_API_KEY: key } }));
    if (source === "codex") await input("agent.settings.authJson", JSON.stringify({ OPENAI_API_KEY: key }));
    await click("agent.settings.importConfigurationAction");
    expect(transactions).toHaveLength(0);
    await click("ui.save");
    expect(transactions).toHaveLength(1);
    expect(transactions[0]!.next.provider).toMatchObject({ baseUrl: endpoint, model: `imported-${source}-model` });
    expect(transactions[0]!.key.value).toBe(key);
    expect(JSON.stringify(transactions[0]!.next)).not.toContain(key);
  });
}
