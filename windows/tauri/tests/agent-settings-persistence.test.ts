import { afterEach, expect, mock, test } from "bun:test";
import isEqual from "fast-deep-equal";
import { defaultSettings } from "../src/features/settings/config/default-settings";
import { normalizeAgentPanelSettings, type AgentPanelSettings } from "../src/features/agent/types/agent-settings.types";

let persisted: unknown;
let notifyChange: (value: unknown) => void = () => undefined;
let published: AgentPanelSettings | undefined;
let calls = 0;
let keyWrites = 0;
let fail = false;
let gate: Promise<void> | undefined;
let entered: (() => void) | undefined;
let release: (() => void) | undefined;

async function withinDeadline<T>(operation: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_resolve, reject) => {
      // test-stability: allow(typescript-real-timer) reason: This is a failure deadline only; controlled gates determine event order and finally releases them.
      timer = setTimeout(() => reject(new Error("Agent settings operation exceeded its local deadline")), 1000);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

mock.module("@tauri-apps/plugin-store", () => ({ load: async () => ({
  entries: async () => Object.entries(defaultSettings),
  get: async () => persisted,
  onKeyChange: async (_key: string, handler: typeof notifyChange) => { notifyChange = handler; return () => undefined; },
  set: async () => undefined,
  delete: async () => undefined,
  save: async () => undefined,
}) }));
mock.module("@/platform/tauri-core", () => ({ invoke: async (_command: string, args: { expected: unknown; next: unknown; credential: unknown }) => {
  calls += 1;
  entered?.();
  await gate;
  if (!isEqual(persisted ?? null, args.expected)) throw new Error("agent.settings.conflict");
  if (fail) throw new Error("agent.settings.saveFailed");
  if (args.credential) keyWrites += 1;
  persisted = JSON.parse(JSON.stringify(args.next));
  notifyChange(persisted);
} }));

const { commitAgentPanelSettings, getSettingsStore, observeAgentPanelSettings } = await import("../src/features/settings/lib/settings-persistence");
observeAgentPanelSettings((value) => { published = value; });
function reset() {
  persisted = undefined;
  notifyChange(persisted);
  calls = keyWrites = 0;
  published = undefined;
}
afterEach(() => { release?.(); gate = undefined; release = entered = undefined; fail = false; });

test("rapid edits serialize without reverting the newest optimistic revision", async () => {
  await getSettingsStore();
  reset();
  const initial = normalizeAgentPanelSettings(persisted);
  const first = { ...initial, command: "first" };
  const next = { ...first, command: "second" };
  gate = new Promise<void>((resolve) => { release = resolve; });
  const started = new Promise<void>((resolve) => { entered = resolve; });
  const one = commitAgentPanelSettings(initial, first);
  const two = commitAgentPanelSettings(first, next);
  try {
    await withinDeadline(started);
    expect(published).toBeUndefined();
    release?.();
    await withinDeadline(Promise.all([one, two]));
    expect(calls).toBe(2);
    expect(published?.command).toBe("second");
    expect(persisted).toEqual(next);
  } finally {
    release?.();
    await withinDeadline(Promise.allSettled([one, two]));
  }
});

test("cross-window conflicts reject before writing credentials and publish the winning revision", async () => {
  reset();
  const initial = normalizeAgentPanelSettings(persisted);
  gate = new Promise<void>((resolve) => { release = resolve; });
  const started = new Promise<void>((resolve) => { entered = resolve; });
  const pending = commitAgentPanelSettings(initial, initial, { agentId: initial.agentId, value: "fixture-key" });
  const outcome = pending.catch((error: unknown) => error);
  try {
    await withinDeadline(started);
    persisted = { ...initial, command: "other-window" };
    notifyChange(persisted);
    release?.();
    expect(await withinDeadline(outcome)).toEqual(new Error("agent.settings.conflict"));
    expect(keyWrites).toBe(0);
    expect(published?.command).toBe("other-window");
  } finally {
    release?.();
    await withinDeadline(Promise.allSettled([pending]));
  }
});

test("a failed transaction refreshes state and does not poison the next edit", async () => {
  reset();
  const initial = normalizeAgentPanelSettings(persisted);
  fail = true;
  await expect(commitAgentPanelSettings(initial, { ...initial, command: "failed" })).rejects.toThrow("agent.settings.saveFailed");
  expect(published).toEqual(initial);
  fail = false;
  await commitAgentPanelSettings(initial, { ...initial, command: "retry" });
  expect(published?.command).toBe("retry");
});

test("idle external updates synchronize immediately and stale UI cannot overwrite them", async () => {
  reset();
  const initial = normalizeAgentPanelSettings(persisted);
  persisted = { ...initial, command: "external" };
  notifyChange(persisted);
  expect(published?.command).toBe("external");
  await expect(commitAgentPanelSettings(initial, initial)).rejects.toThrow("agent.settings.conflict");
  expect(calls).toBe(0);
  expect(published?.command).toBe("external");
});
