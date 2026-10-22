import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import isEqual from "fast-deep-equal";
import { defaultSettings } from "../src/features/settings/config/default-settings";
import { CLAUDE_AGENT_ID, CODEX_AGENT_ID, normalizeAgentPanelSettings, selectAgentConfiguration, type AgentPanelSettings } from "../src/features/agent/types/agent-settings.types";
import type { AgentLaunchConfiguration } from "../src/features/agent/services/agent-transport";

let persisted: unknown;
let notifyChange: (value: unknown) => void = () => undefined;
let workspace = "C:/fixture";
let afterCommit: ((count: number) => void) | undefined;
let afterLaunch: (() => void) | undefined;
let failCommit = false;
const launched: AgentLaunchConfiguration[] = [];
const errors: string[] = [];
let newSessions = 0;
let commits = 0;
let cliSource: "codex" | "claude" = "claude";
const cliProvider = { endpoint: "https://fresh.example.test/v1", model: "fresh-model" };
mock.module("@tauri-apps/plugin-store", () => ({ load: async () => ({
  entries: async () => Object.entries(defaultSettings), get: async () => persisted,
  onKeyChange: async (_key: string, handler: typeof notifyChange) => { notifyChange = handler; return () => undefined; },
  set: async () => undefined, delete: async () => undefined, save: async () => undefined,
}) }));
mock.module("@/platform/tauri-core", () => ({ invoke: async (command: string, args: { expected: unknown; next: unknown }) => {
  if (command === "get_secure_secret") return "fixture-key";
  if (command === "agent.parseProviderConfiguration") return {
    ...cliProvider, apiProtocol: cliSource === "claude" ? "anthropicMessages" : "responses",
  };
  if (command !== "commit_agent_panel_settings") throw new Error(`Unexpected command: ${command}`);
  if (failCommit) throw new Error("agent.settings.saveFailed");
  if (!isEqual(persisted, args.expected)) throw new Error("agent.settings.conflict");
  persisted = JSON.parse(JSON.stringify(args.next));
  commits++;
  afterCommit?.(commits);
} }));
mock.module("@/platform/agent-cli-configuration", () => ({ readAgentCliSnapshot: async () => ({
  configuration: JSON.stringify({ env: { ANTHROPIC_API_KEY: "fixture-cli-key" } }),
  authentication: JSON.stringify({ OPENAI_API_KEY: "fixture-cli-key" }),
}) }));
mock.module("@/platform/app-data-directory", () => ({ resolveAppDataDirectory: async () => "C:/fixture-data" }));
mock.module("@/features/settings/lib/settings-effects", () => ({ applySettingSideEffect() {}, applySettingsSideEffects() {} }));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({ useWorkspaceTabsStore: { getState: () => ({}) } }));
mock.module("@/features/file-system/stores/file-system.store", () => ({ useFileSystemStore: { getState: () => ({ rootFolderPath: workspace }) } }));
mock.module("@/features/editor/stores/buffer.store", () => ({ useBufferStore: { getState: () => ({ buffers: [] }) } }));
mock.module("@/platform/agent-local-files", () => ({ isAgentLocalFile: async () => true }));
mock.module("@/i18n/locale-provider", () => ({ useTranslation: () => ({ t: (key: string) => key }) }));
mock.module("sonner", () => ({ toast: { error: (message: string) => errors.push(message), warning() {} } }));
mock.module("@/features/agent/actions/agent-tool-window-actions", () => ({ openAgentToolWindow() {} }));
mock.module("@/features/agent/actions/agent-conversation-placement-actions", () => ({ openAgentConversationInEditor() {} }));
mock.module("@/features/agent/services/agent-transport", () => ({
  createTauriAgentTransport: () => ({ open: async (_id: string, launch: AgentLaunchConfiguration, onEvent: (event: unknown) => void) => {
    launched.push(launch);
    onEvent({ kind: "ready" });
    afterLaunch?.();
    return { send: async (command: unknown) => {
      if ((command as { kind: string }).kind === "newSession") newSessions++;
    }, close: async () => undefined };
  } }),
}));

// Keep the real connection/launch services, settings store, CAS queue and drafts.
const { openAgentConnection, closeAgentConnection } = await import("../src/features/agent/stores/agent-connection-service");
const { useSettingsStore } = await import("../src/features/settings/stores/settings.store");
const { getSettingsStore } = await import("../src/features/settings/lib/settings-persistence");
const { agentDraftKey, useAgentSurfaceStore } = await import("../src/features/agent/stores/agent-surface.store");
const { useAgentFileContextMenu } = await import("../src/features/agent/hooks/use-agent-file-context-menu");
let initial: AgentPanelSettings;
const key = agentDraftKey(CLAUDE_AGENT_ID, null);
function setSettings(settings: AgentPanelSettings) {
  useSettingsStore.getState().actions.initializeSettings({ ...useSettingsStore.getState().settings, agentPanel: settings });
}
function attachToAgent(agentID = CLAUDE_AGENT_ID) {
  const menu = useAgentFileContextMenu()(["C:/fixture/Main.java"]);
  const destination = menu[0]!.children!.find((item) => item.id === `agent-${agentID}`)!;
  return destination.children![0]!.onClick();
}
function linkedSettings(agentID: string, source: "codex" | "claude") {
  const selected = selectAgentConfiguration(initial, agentID);
  const provider = { ...selected.provider, source };
  return normalizeAgentPanelSettings({ ...initial, configurations: {
    ...initial.configurations, [agentID]: { ...selected, provider },
  }, ...(agentID === initial.agentId ? { provider } : {}) });
}

beforeEach(async () => {
  launched.length = errors.length = newSessions = 0;
  cliSource = "claude";
  workspace = "C:/fixture";
  initial = normalizeAgentPanelSettings({ enabled: true, agentId: CODEX_AGENT_ID,
    provider: { id: "codex", protocol: "responses", baseUrl: "https://codex.example.test/v1", model: "codex-fixture" },
    configurations: { [CLAUDE_AGENT_ID]: { authentication: "apiKey",
      provider: { id: "claude", protocol: "anthropicMessages", baseUrl: "https://claude.example.test/v1", model: "claude-fixture" } } },
  });
  persisted = JSON.parse(JSON.stringify(initial));
  await getSettingsStore();
  notifyChange(persisted);
  setSettings(initial);
  await openAgentConnection(workspace, initial);
  launched.length = commits = 0;
  useAgentSurfaceStore.getState().actions.reset();
  useAgentSurfaceStore.getState().actions.setDraftText(key, "Keep this draft");
});
afterEach(async () => {
  afterCommit = afterLaunch = undefined;
  failCommit = false;
  await closeAgentConnection();
});

test("cross-Agent attachment uses the committed settings after normalization", async () => {
  await attachToAgent();
  expect(errors).toEqual([]);
  expect(launched).toHaveLength(1);
  expect(launched[0]).toMatchObject({ agentId: CLAUDE_AGENT_ID, provider: { baseUrl: "https://claude.example.test/v1", model: "claude-fixture" } });
  expect(useSettingsStore.getState().settings.agentPanel).not.toBe(initial);
  expect(useAgentSurfaceStore.getState().drafts[key]).toMatchObject({ text: "Keep this draft", files: [{ uri: "file:///C:/fixture/Main.java" }] });
  expect(newSessions).toBe(1);
});

for (const boundary of ["commit", "launch"] as const) {
  test(`workspace replacement during ${boundary} leaves the destination draft untouched`, async () => {
    const replace = () => { workspace = "C:/other"; };
    if (boundary === "commit") afterCommit = replace;
    else afterLaunch = replace;
    await attachToAgent();
    expect(errors).toEqual(["agent.context.stale"]);
    expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
    expect(newSessions).toBe(0);
  });
}

test("a concurrent settings change after launch rejects the stale attachment", async () => {
  afterLaunch = () => setSettings(initial);
  await attachToAgent();
  expect(errors).toEqual(["agent.context.stale"]);
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});

test("a failed settings transaction cannot launch or attach using optimistic settings", async () => {
  failCommit = true;
  await attachToAgent();
  expect(errors).toHaveLength(1);
  expect(launched).toEqual([]);
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});

for (const agentID of [CLAUDE_AGENT_ID, CODEX_AGENT_ID]) {
  test(`a ${agentID} launch can refresh its own linked metadata and attach`, async () => {
    cliSource = agentID === CLAUDE_AGENT_ID ? "claude" : "codex";
    const linked = linkedSettings(agentID, cliSource);
    persisted = JSON.parse(JSON.stringify(linked));
    notifyChange(persisted);
    const destinationKey = agentDraftKey(agentID, null);
    useAgentSurfaceStore.getState().actions.setDraftText(destinationKey, "Keep this draft");
    await attachToAgent(agentID);
    expect(errors).toEqual([]);
    expect(useSettingsStore.getState().settings.agentPanel.provider).toMatchObject({
      source: cliSource, baseUrl: cliProvider.endpoint, model: cliProvider.model,
    });
    expect(launched[0]?.provider).toMatchObject({ baseUrl: cliProvider.endpoint, model: cliProvider.model, apiKey: "fixture-cli-key" });
    expect(commits).toBe(agentID === CLAUDE_AGENT_ID ? 2 : 1);
    expect(useAgentSurfaceStore.getState().drafts[destinationKey]).toMatchObject({ text: "Keep this draft", files: [{ uri: "file:///C:/fixture/Main.java" }] });
    expect(newSessions).toBe(1);
  });
}

test("an external revision during the launch's metadata save still rejects attachment", async () => {
  const linked = linkedSettings(CLAUDE_AGENT_ID, "claude");
  persisted = JSON.parse(JSON.stringify(linked));
  notifyChange(persisted);
  afterCommit = (count) => { if (count === 2) persisted = JSON.parse(JSON.stringify(initial)); };
  await attachToAgent();
  expect(errors).toEqual(["agent.context.stale"]);
  expect(commits).toBe(2);
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});

test("a failed linked metadata save leaves attachments untouched even after transport opens", async () => {
  persisted = JSON.parse(JSON.stringify(linkedSettings(CLAUDE_AGENT_ID, "claude")));
  notifyChange(persisted);
  afterLaunch = () => { failCommit = true; };
  await attachToAgent();
  expect(launched).toHaveLength(1);
  expect(errors).toEqual(["agent.context.stale"]);
  expect(useSettingsStore.getState().agentSettingsError).toBe("agent.settings.saveFailed");
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});
