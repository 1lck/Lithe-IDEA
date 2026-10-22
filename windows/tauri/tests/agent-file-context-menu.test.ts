import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import isEqual from "fast-deep-equal";
import { defaultSettings } from "../src/features/settings/config/default-settings";
import { CLAUDE_AGENT_ID, CODEX_AGENT_ID, normalizeAgentPanelSettings, type AgentPanelSettings } from "../src/features/agent/types/agent-settings.types";

let persisted: unknown;
let notifyChange: (value: unknown) => void = () => undefined;
let workspace = "C:/fixture";
let afterCommit: (() => void) | undefined;
let afterLaunch: (() => void) | undefined;
let failCommit = false;
const launched: AgentPanelSettings[] = [];
const errors: string[] = [];
let newSessions = 0;
mock.module("@tauri-apps/plugin-store", () => ({ load: async () => ({
  entries: async () => Object.entries(defaultSettings), get: async () => persisted,
  onKeyChange: async (_key: string, handler: typeof notifyChange) => { notifyChange = handler; return () => undefined; },
  set: async () => undefined, delete: async () => undefined, save: async () => undefined,
}) }));
mock.module("@/platform/tauri-core", () => ({ invoke: async (_command: string, args: { expected: unknown; next: unknown }) => {
  if (failCommit) throw new Error("agent.settings.saveFailed");
  if (!isEqual(persisted, args.expected)) throw new Error("agent.settings.conflict");
  persisted = JSON.parse(JSON.stringify(args.next));
  afterCommit?.();
} }));
mock.module("@/features/settings/lib/settings-effects", () => ({ applySettingSideEffect() {}, applySettingsSideEffects() {} }));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({ useWorkspaceTabsStore: { getState: () => ({}) } }));
mock.module("@/features/file-system/stores/file-system.store", () => ({ useFileSystemStore: { getState: () => ({ rootFolderPath: workspace }) } }));
mock.module("@/features/editor/stores/buffer.store", () => ({ useBufferStore: { getState: () => ({ buffers: [] }) } }));
mock.module("@/platform/agent-local-files", () => ({ isAgentLocalFile: async () => true }));
mock.module("@/i18n/locale-provider", () => ({ useTranslation: () => ({ t: (key: string) => key }) }));
mock.module("sonner", () => ({ toast: { error: (message: string) => errors.push(message), warning() {} } }));
mock.module("@/features/agent/actions/agent-tool-window-actions", () => ({ openAgentToolWindow() {} }));
mock.module("@/features/agent/actions/agent-conversation-placement-actions", () => ({ openAgentConversationInEditor() {} }));
mock.module("@/features/agent/stores/agent-connection-service", () => ({
  agentConnection: () => ({ getSnapshot: () => ({ isCreatingSession: false, conversations: {}, selectedSessionID: null }),
    startNewConversation: () => { newSessions++; }, selectSession() {} }),
  cachedAgentSessions: () => [],
  openAgentConnection: async (_workspace: string, settings: AgentPanelSettings) => { launched.push(settings); afterLaunch?.(); },
}));

// Keep the real settings store, CAS queue and draft store in this regression.
const { useSettingsStore } = await import("../src/features/settings/stores/settings.store");
const { getSettingsStore } = await import("../src/features/settings/lib/settings-persistence");
const { agentDraftKey, useAgentSurfaceStore } = await import("../src/features/agent/stores/agent-surface.store");
const { useAgentFileContextMenu } = await import("../src/features/agent/hooks/use-agent-file-context-menu");
let initial: AgentPanelSettings;
const key = agentDraftKey(CLAUDE_AGENT_ID, null);
function setSettings(settings: AgentPanelSettings) {
  useSettingsStore.getState().actions.initializeSettings({ ...useSettingsStore.getState().settings, agentPanel: settings });
}
function attachToClaude() {
  const menu = useAgentFileContextMenu()(["C:/fixture/Main.java"]);
  const destination = menu[0]!.children!.find((item) => item.id === `agent-${CLAUDE_AGENT_ID}`)!;
  return destination.children![0]!.onClick();
}

beforeEach(async () => {
  launched.length = errors.length = newSessions = 0;
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
  useAgentSurfaceStore.getState().actions.reset();
  useAgentSurfaceStore.getState().actions.setDraftText(key, "Keep this draft");
});
afterEach(() => { afterCommit = afterLaunch = undefined; failCommit = false; });

test("cross-Agent attachment uses the committed settings after normalization", async () => {
  await attachToClaude();
  expect(errors).toEqual([]);
  expect(launched).toHaveLength(1);
  expect(launched[0]).toEqual(normalizeAgentPanelSettings(persisted));
  expect(useSettingsStore.getState().settings.agentPanel).not.toBe(initial);
  expect(useAgentSurfaceStore.getState().drafts[key]).toMatchObject({ text: "Keep this draft", files: [{ uri: "file:///C:/fixture/Main.java" }] });
  expect(newSessions).toBe(1);
});

for (const boundary of ["commit", "launch"] as const) {
  test(`workspace replacement during ${boundary} leaves the destination draft untouched`, async () => {
    const replace = () => { workspace = "C:/other"; };
    if (boundary === "commit") afterCommit = replace;
    else afterLaunch = replace;
    await attachToClaude();
    expect(errors).toEqual(["agent.context.stale"]);
    expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
    expect(newSessions).toBe(0);
  });
}

test("a concurrent settings change after launch rejects the stale attachment", async () => {
  afterLaunch = () => setSettings(initial);
  await attachToClaude();
  expect(errors).toEqual(["agent.context.stale"]);
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});

test("a failed settings transaction cannot launch or attach using optimistic settings", async () => {
  failCommit = true;
  await attachToClaude();
  expect(errors).toHaveLength(1);
  expect(launched).toEqual([]);
  expect(useAgentSurfaceStore.getState().drafts[key]?.files).toEqual([]);
  expect(newSessions).toBe(0);
});
