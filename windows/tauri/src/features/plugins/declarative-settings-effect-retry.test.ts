import { expect, test } from "bun:test";
import { DeclarativeSettingsSession } from "./declarative-settings-session";
import type {
  DeclarativePluginSetting,
  DeclarativeSettingSnapshot,
} from "./declarative-plugin-launch";

const setting: DeclarativePluginSetting = {
  id: "message",
  title: "Message",
  type: "text",
  default: "original",
  scope: "project",
  effect: "immediate",
};
function snapshot(identity: string): DeclarativeSettingSnapshot {
  return {
    identity,
    packageIdentity: "accepted",
    manifest: {},
    settings: [setting],
    settingActions: [],
    globalValues: {},
    projectValues: { message: "saved" },
    globalPath: "/fixture/global.json",
    projectPath: "/fixture/project.json",
    resolvedGlobal: [],
    resolvedProject: [{ id: "message", value: "saved", source: "project" }],
  };
}
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
function fixture() {
  let stored = snapshot("initial");
  let writes = 0;
  let effects = 0;
  let failure = true;
  let gate: Promise<void> | undefined;
  const session = new DeclarativeSettingsSession(
    {
      read: async () => stored,
      write: async () => {
        writes++;
        stored = snapshot("saved");
        return stored;
      },
      effect: async () => {
        effects++;
        await gate;
        if (failure) throw new Error("fixture.effect.failed");
        return "immediate";
      },
      assertCurrent() {},
    },
    () => {},
  );
  return {
    session,
    writes: () => writes,
    effects: () => effects,
    setStored: (next: DeclarativeSettingSnapshot) => {
      stored = next;
    },
    succeed: () => {
      failure = false;
    },
    hold: (pending: Promise<void>) => {
      gate = pending;
    },
  };
}

test("effect retry reads the saved identity, never repeats persistence, and coalesces duplicate clicks", async () => {
  const f = fixture();
  const gate = deferred();
  let retry: Promise<void> | undefined;
  try {
    await f.session.reload();
    f.session.edit(setting.id, "project", "changed");
    await f.session.save(setting, "project");
    expect(f.session.state.effectRetry).toBe(true);
    expect(f.session.state.snapshot?.identity).toBe("saved");
    f.succeed();
    f.hold(gate.promise);
    retry = f.session.retryEffect();
    await f.session.retryEffect();
    gate.resolve();
    await retry;
    expect(f.writes()).toBe(1);
    expect(f.effects()).toBe(2);
    expect(f.session.state.effect).toBe("immediate");
    expect(f.session.state.effectRetry).toBe(false);
  } finally {
    gate.resolve();
    await retry;
    f.session.dispose();
  }
}, 1000);

test("effect retry rejects externally changed settings and package bytes", async () => {
  for (const next of [
    snapshot("external"),
    { ...snapshot("saved"), packageIdentity: "replacement" },
  ]) {
    const f = fixture();
    try {
      await f.session.reload();
      f.session.edit(setting.id, "project", "changed");
      await f.session.save(setting, "project");
      f.setStored(next);
      f.succeed();
      await f.session.retryEffect();
      expect(f.effects()).toBe(1);
      expect(f.writes()).toBe(1);
      expect(f.session.state.error).toContain("plugin.settings.conflict");
      expect(f.session.state.effect).toBeNull();
      expect(f.session.state.effectRetry).toBe(true);
    } finally {
      f.session.dispose();
    }
  }
}, 1000);

test("disposing a pending effect retry suppresses its late result", async () => {
  const f = fixture();
  const gate = deferred();
  let retry: Promise<void> | undefined;
  try {
    await f.session.reload();
    f.session.edit(setting.id, "project", "changed");
    await f.session.save(setting, "project");
    f.succeed();
    f.hold(gate.promise);
    retry = f.session.retryEffect();
    f.session.dispose();
    gate.resolve();
    await retry;
    expect(f.session.state.effect).toBeNull();
    expect(f.writes()).toBe(1);
  } finally {
    gate.resolve();
    await retry;
    f.session.dispose();
  }
}, 1000);
