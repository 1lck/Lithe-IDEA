import { afterEach, expect, mock, test } from "bun:test";
import type { AgentLaunchConfiguration } from "../src/features/agent/services/agent-transport";
import { DEFAULT_AGENT_PANEL_SETTINGS } from "../src/features/agent/types/agent-settings.types";

function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

const opened: AgentLaunchConfiguration[] = [];
const closed: string[] = [];
const pending: Promise<void>[] = [];
let started = gate();
let release = gate();
let holdFirst = true;

mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: { getState: () => ({ settings: { displayLanguage: "en" } }) },
}));
mock.module("@/platform/app-data-directory", () => ({
  resolveAppDataDirectory: async () => "C:/fake-data",
}));
mock.module("@/i18n/locale", () => ({ createTranslator: () => (key: string) => key }));
mock.module("../src/features/agent/services/agent-launch", () => ({
  AgentLaunchError: class extends Error {},
  loadAgentLaunch: async ({ workspacePath, settings, dataDirectory }: {
    workspacePath: string;
    settings: typeof DEFAULT_AGENT_PANEL_SETTINGS;
    dataDirectory: string;
  }) => ({
    agentId: settings.agentId,
    authentication: settings.authentication,
    cwd: workspacePath,
    dataDirectory,
  }),
}));
mock.module("../src/features/agent/services/agent-transport", () => ({
  createTauriAgentTransport: () => ({
    open: async (_id: string, launch: AgentLaunchConfiguration) => {
      opened.push(launch);
      if (holdFirst && opened.length === 1) {
        started.resolve();
        await release.promise;
      }
      return {
        send: async () => {},
        close: async () => { closed.push(launch.agentId!); },
      };
    },
  }),
}));

// Run this file separately from hook tests that mock the connection service.
const { openAgentConnection, closeAgentConnection } =
  await import("../src/features/agent/stores/agent-connection-service");

afterEach(async () => {
  release.resolve();
  await Promise.allSettled(pending);
  await closeAgentConnection();
  opened.length = 0;
  closed.length = 0;
  pending.length = 0;
  started = gate();
  release = gate();
  holdFirst = true;
});

for (const change of ["agent", "authentication"] as const) {
  test(`a superseded startup closes before switching ${change}`, async () => {
    const first = { ...DEFAULT_AGENT_PANEL_SETTINGS, enabled: true };
    const next = change === "agent"
      ? { ...first, agentId: "claude-acp" }
      : { ...first, authentication: "codexSubscription" as const };
    pending.push(openAgentConnection(`C:/fake-${change}`, first));
    await started.promise;
    pending.push(openAgentConnection(`C:/fake-${change}`, next));
    release.resolve();
    await Promise.all(pending);

    expect(opened.map((launch) => [launch.agentId, launch.authentication])).toEqual([
      [first.agentId, first.authentication],
      [next.agentId, next.authentication],
    ]);
    expect(closed).toEqual([first.agentId]);
    await openAgentConnection(`C:/fake-${change}`, next);
    expect(opened).toHaveLength(2);
  }, 5_000);
}

test("stop and immediate reopen stay ordered during startup", async () => {
  const settings = { ...DEFAULT_AGENT_PANEL_SETTINGS, enabled: true };
  pending.push(openAgentConnection("C:/fake-reopen", settings));
  await started.promise;
  pending.push(closeAgentConnection());
  pending.push(openAgentConnection("C:/fake-reopen", settings));
  release.resolve();
  await Promise.all(pending);

  expect(opened).toHaveLength(2);
  expect(closed).toEqual([settings.agentId]);
}, 5_000);


test("editor and sidebar claims join the same startup", async () => {
  const settings = { ...DEFAULT_AGENT_PANEL_SETTINGS, enabled: true };
  pending.push(openAgentConnection("C:/fake-shared-start", settings));
  await started.promise;
  pending.push(openAgentConnection("C:/fake-shared-start", settings));
  release.resolve();
  await Promise.all(pending);

  expect(opened).toHaveLength(1);
  expect(closed).toEqual([]);
}, 5_000);
