import { describe, expect, test } from "bun:test";
import {
  applySettingEffect,
  DeclarativeSettingsSession,
  type SettingsSessionPorts,
} from "./declarative-settings-session";
import type {
  DeclarativePluginSetting,
  DeclarativeSettingSnapshot,
} from "./declarative-plugin-launch";

const setting: DeclarativePluginSetting = {
  id: "option",
  title: "Option",
  type: "text",
  default: "default",
  scope: "project",
  effect: "immediate",
};
function snapshot(identity = "baseline"): DeclarativeSettingSnapshot {
  return {
    identity,
    manifest: { languageServers: [{ languageID: "fixture" }] },
    settings: [setting],
    settingActions: [],
    globalValues: {},
    projectValues: {},
    globalPath: "/example/preferences.json",
    projectPath: "/example/workspace/.lithe/plugin-settings.json",
    resolvedGlobal: [{ id: setting.id, value: setting.default, source: "default" }],
    resolvedProject: [{ id: setting.id, value: setting.default, source: "default" }],
  };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
function fixture(overrides: Partial<SettingsSessionPorts> = {}) {
  const writes: unknown[][] = [];
  let effects = 0;
  const session = new DeclarativeSettingsSession(
    {
      read: async () => snapshot(),
      write: async (...args) => {
        writes.push(args);
        return snapshot("read-back");
      },
      effect: async () => {
        effects++;
        return "immediate";
      },
      assertCurrent() {},
      ...overrides,
    },
    () => {},
  );
  return { session, writes, effects: () => effects };
}

describe("declarative settings draft lifecycle", () => {
  test("opening, unchanged input, cancel and dispose never write", async () => {
    const f = fixture();
    try {
      await f.session.reload();
      expect(f.session.state.snapshot?.resolvedProject[0].value).toBe("default");
      f.session.edit(setting.id, "global", "default");
      await f.session.save(setting, "global");
      f.session.edit(setting.id, "project", "draft");
      f.session.cancel(setting.id, "project");
      await f.session.save(setting, "project");
      await f.session.save(setting, "project", true);
      expect(f.writes).toEqual([]);
      expect(f.session.state.drafts).toEqual({});
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("explicit empty is saved with baseline and read-back; reset alone erases", async () => {
    const persisted = snapshot("stored");
    persisted.projectValues.option = "";
    persisted.resolvedProject = [{ id: "option", value: "", source: "project" }];
    const writes: unknown[][] = [];
    const f = fixture({
      write: async (...args) => {
        writes.push(args);
        return writes.length === 1 ? persisted : snapshot("reset");
      },
    });
    try {
      await f.session.reload();
      f.session.edit(setting.id, "project", "");
      await f.session.save(setting, "project");
      expect(writes[0]).toEqual(["option", "project", "", "baseline"]);
      expect(f.session.state.snapshot).toBe(persisted);
      expect(f.session.state.drafts).toEqual({});
      await f.session.save(setting, "project", true);
      expect(writes[1]).toEqual(["option", "project", null, "stored"]);
      expect(f.session.state.snapshot?.projectValues).toEqual({});
      // A queued blur/unmount cannot resurrect the reset override.
      await f.session.save(setting, "project");
      expect(writes).toHaveLength(2);
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("conflict retains the draft and cannot claim an effect", async () => {
    const f = fixture({
      write: async () => {
        throw new Error("plugin.settings.conflict");
      },
    });
    try {
      await f.session.reload();
      f.session.edit(setting.id, "global", "draft");
      await f.session.save(setting, "global");
      expect(f.session.state.drafts["global:option"]).toBe("draft");
      expect(f.session.state.error).toContain("plugin.settings.conflict");
      expect(f.session.state.snapshot?.identity).toBe("baseline");
      expect(f.effects()).toBe(0);
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("saving the global layer cannot turn an equal project draft into an override", async () => {
    const next = snapshot("global-saved");
    next.globalValues.option = "new";
    next.resolvedGlobal = next.resolvedProject = [{ id: "option", value: "new", source: "global" }];
    const writes: unknown[][] = [];
    const f = fixture({
      write: async (...args) => {
        writes.push(args);
        return next;
      },
    });
    try {
      await f.session.reload();
      f.session.edit(setting.id, "project", "new");
      f.session.edit(setting.id, "global", "new");
      expect(Object.keys(f.session.state.drafts)).toHaveLength(2);
      await f.session.save(setting, "global");
      await f.session.save(setting, "project");
      expect(writes).toEqual([["option", "global", "new", "baseline"]]);
      expect(f.session.state.drafts).toEqual({});
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("read failure stays unavailable instead of inventing defaults", async () => {
    const f = fixture({
      read: async () => {
        throw new Error("plugin.settings.readFailed");
      },
    });
    try {
      await f.session.reload();
      expect(f.session.state.snapshot).toBeNull();
      expect(f.session.state.error).toContain("plugin.settings.readFailed");
      f.session.edit(setting.id, "global", "draft");
      await f.session.save(setting, "global");
      expect(f.writes).toEqual([]);
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("disposing during discovery suppresses a late workspace result", async () => {
    const gate = deferred<DeclarativeSettingSnapshot>();
    const f = fixture({ read: () => gate.promise });
    const pending = f.session.reload();
    try {
      f.session.dispose();
      gate.resolve(snapshot());
      await pending;
      expect(f.session.state.snapshot).toBeNull();
    } finally {
      gate.resolve(snapshot());
      await pending;
      f.session.dispose();
    }
  }, 1000);

  test("plugin revocation before save prevents native write", async () => {
    let active = true;
    const f = fixture({
      assertCurrent: () => {
        if (!active) throw new Error("stale plugin/workspace");
      },
    });
    try {
      await f.session.reload();
      f.session.edit(setting.id, "global", "draft");
      active = false;
      await f.session.save(setting, "global");
      expect(f.writes).toEqual([]);
      expect(f.session.state.error).toContain("stale");
    } finally {
      f.session.dispose();
    }
  }, 1000);

  test("workspace switch during save suppresses effects and obsolete read-back", async () => {
    const gate = deferred<DeclarativeSettingSnapshot>();
    const f = fixture({ write: () => gate.promise });
    await f.session.reload();
    f.session.edit(setting.id, "global", "draft");
    const pending = f.session.save(setting, "global");
    try {
      f.session.dispose();
      gate.resolve(snapshot("old-workspace"));
      await pending;
      expect(f.effects()).toBe(0);
      expect(f.session.state.snapshot?.identity).toBe("baseline");
    } finally {
      gate.resolve(snapshot());
      await pending;
      f.session.dispose();
    }
  }, 1000);

  test("failed effect keeps saved read-back and reports failure", async () => {
    const f = fixture({
      effect: async () => {
        throw new Error("effect unavailable");
      },
    });
    try {
      await f.session.reload();
      f.session.edit(setting.id, "global", "draft");
      await f.session.save(setting, "global");
      expect(f.session.state.snapshot?.identity).toBe("read-back");
      expect(f.session.state.drafts).toEqual({});
      expect(f.session.state.effect).toBeNull();
      expect(f.session.state.error).toContain("effect unavailable");
    } finally {
      f.session.dispose();
    }
  }, 1000);
});

describe("declarative settings effect reporting", () => {
  test("only a matching ready LSP receiving configuration counts as immediate", async () => {
    const pushed: unknown[] = [];
    let live = false;
    const ports = {
      pluginId: "example.plugin",
      assertCurrent() {},
      configuration: async () => ({ status: "ok", configuration: { feature: true } }),
      push: async (args: unknown) => {
        pushed.push(args);
        return live;
      },
    };
    expect(await applySettingEffect(setting, snapshot(), "/example/workspace", ports)).toBe(
      "nextStart",
    );
    live = true;
    expect(await applySettingEffect(setting, snapshot(), "/example/workspace", ports)).toBe(
      "immediate",
    );
    expect(pushed[1]).toEqual({
      pluginId: "example.plugin",
      workspacePath: "/example/workspace",
      languageId: "fixture",
      configuration: { feature: true },
    });
  }, 1000);

  test("restart, next run, and unavailable reload never call a provider", async () => {
    let calls = 0;
    const ports = {
      pluginId: "example.plugin",
      assertCurrent() {},
      configuration: async () => {
        calls++;
        return { status: "ok" };
      },
      push: async () => {
        calls++;
        return true;
      },
    };
    expect(
      await applySettingEffect({ ...setting, effect: "restart" }, snapshot(), "/example", ports),
    ).toBe("restart");
    expect(
      await applySettingEffect({ ...setting, effect: "nextRun" }, snapshot(), "/example", ports),
    ).toBe("nextRun");
    expect(
      await applySettingEffect({ ...setting, effect: "reload" }, snapshot(), "/example", ports),
    ).toBe("reloadUnavailable");
    expect(await applySettingEffect(setting, snapshot(), null, ports)).toBe("nextStart");
    expect(calls).toBe(0);
  }, 1000);

  test("revocation after configuration resolution prevents a stale push", async () => {
    const gate = deferred<{ status: string; configuration: unknown }>();
    let active = true;
    let pushes = 0;
    const pending = applySettingEffect(setting, snapshot(), "/example", {
      pluginId: "example.plugin",
      assertCurrent() {
        if (!active) throw new Error("revoked");
      },
      configuration: () => gate.promise,
      push: async () => {
        pushes++;
        return true;
      },
    });
    // Subscribe before releasing the gate; Bun must not observe an unhandled rejection.
    const outcome = pending.then(
      () => "resolved",
      (error: unknown) => String(error),
    );
    try {
      active = false;
      gate.resolve({ status: "ok", configuration: {} });
      expect(await outcome).toContain("revoked");
      expect(pushes).toBe(0);
    } finally {
      gate.resolve({ status: "ok", configuration: {} });
      await outcome;
    }
  }, 1000);
});
