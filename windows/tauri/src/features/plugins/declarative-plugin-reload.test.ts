import { expect, test } from "bun:test";
import { PluginSettingsReloads, type PluginReloadReceipt } from "./declarative-plugin-reload";

const receipt: PluginReloadReceipt = {
  pluginId: "example.plugin",
  workspacePath: "/fixture/project",
  expectedIdentity: "saved-bytes",
  expectedPackageIdentity: "accepted-package",
};
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}

test("saving only queues the saved receipt; reload requires its own confirmation", async () => {
  const calls: unknown[] = [];
  const owner = new PluginSettingsReloads({
    reload: async (value) => {
      calls.push(value);
    },
    refresh: async () => {
      calls.push("refresh");
    },
  });
  owner.require(receipt);
  expect(calls).toEqual([]);
  expect(owner.state(receipt.pluginId)?.receipt).toBe(receipt);
  await owner.confirm(receipt.pluginId);
  expect(calls).toEqual([receipt, "refresh"]);
  expect(owner.state(receipt.pluginId)).toBeUndefined();
}, 1000);

test("ordinary saves only advance an existing reload requirement", async () => {
  const owner = new PluginSettingsReloads({
    reload: async () => {},
    refresh: async () => {},
  });
  owner.saved(receipt, false);
  expect(owner.states()).toEqual([]);
  owner.require(receipt);
  const newer = { ...receipt, expectedIdentity: "latest-read-back" };
  owner.saved(newer, false);
  expect(owner.state(receipt.pluginId)?.receipt).toBe(newer);
  expect(owner.state(receipt.pluginId)?.busy).toBe(false);
}, 1000);

test("a later save cannot replace a pending reload's accepted package", async () => {
  const owner = new PluginSettingsReloads({
    reload: async () => {},
    refresh: async () => {},
  });
  owner.require(receipt);
  const changed = {
    ...receipt,
    expectedIdentity: "later-read-back",
    expectedPackageIdentity: "different-package",
  };
  expect(() => owner.saved(changed, false)).toThrow("plugin.settings.packageChanged");
  expect(() => owner.require(changed)).toThrow("plugin.settings.packageChanged");
  expect(owner.state(receipt.pluginId)?.receipt).toBe(receipt);
}, 1000);

test("failed drain retains the exact saved receipt after the settings view unsubscribes", async () => {
  const gate = deferred<void>();
  const calls: PluginReloadReceipt[] = [];
  let first = true;
  const owner = new PluginSettingsReloads({
    reload: (value) => {
      calls.push(value);
      return first ? gate.promise : Promise.resolve();
    },
    refresh: async () => {},
  });
  const unsubscribe = owner.subscribe(() => {});
  owner.require(receipt);
  const pending = owner.confirm(receipt.pluginId);
  try {
    unsubscribe();
    gate.reject(new Error("process still running"));
    await pending;
    expect(owner.state(receipt.pluginId)?.receipt).toBe(receipt);
    expect(owner.state(receipt.pluginId)?.error).toContain("process still running");
    first = false;
    await owner.confirm(receipt.pluginId);
    expect(calls).toEqual([receipt, receipt]);
    expect(owner.state(receipt.pluginId)).toBeUndefined();
  } finally {
    gate.resolve();
    await pending;
    unsubscribe();
  }
}, 1000);

test("postponing an unconfirmed reload never invokes native and cannot discard a failed owner", async () => {
  let calls = 0;
  const owner = new PluginSettingsReloads({
    reload: async () => {
      calls++;
      throw new Error("stop failed");
    },
    refresh: async () => {},
  });
  owner.require(receipt);
  owner.postpone(receipt.pluginId);
  expect(calls).toBe(0);
  expect(owner.state(receipt.pluginId)).toBeUndefined();
  owner.require(receipt);
  await owner.confirm(receipt.pluginId);
  owner.postpone(receipt.pluginId);
  expect(owner.state(receipt.pluginId)?.error).toContain("stop failed");
  expect(calls).toBe(1);
}, 1000);

test("in-flight reload rejects another receipt and duplicate confirmation", async () => {
  const gate = deferred<void>();
  let calls = 0;
  const owner = new PluginSettingsReloads({
    reload: () => {
      calls++;
      return gate.promise;
    },
    refresh: async () => {},
  });
  owner.require(receipt);
  const pending = owner.confirm(receipt.pluginId);
  try {
    expect(() => owner.require({ ...receipt, expectedIdentity: "newer" })).toThrow("reloadBusy");
    expect(() => owner.saved({ ...receipt, expectedIdentity: "newer" }, false)).toThrow(
      "reloadBusy",
    );
    await owner.confirm(receipt.pluginId);
    expect(calls).toBe(1);
    gate.resolve();
    await pending;
  } finally {
    gate.resolve();
    await pending;
  }
}, 1000);

test("a stale settings conflict never claims reload and can be postponed for a fresh baseline", async () => {
  let refreshes = 0;
  const owner = new PluginSettingsReloads({
    reload: async () => {
      throw new Error("plugin.settings.conflict");
    },
    refresh: async () => {
      refreshes++;
    },
  });
  owner.require(receipt);
  await owner.confirm(receipt.pluginId);
  expect(refreshes).toBe(0);
  expect(owner.state(receipt.pluginId)?.error).toContain("conflict");
  owner.postpone(receipt.pluginId);
  expect(owner.states()).toEqual([]);
}, 1000);

test("a stop diagnostic containing a conflict code cannot discard the revoked retry owner", async () => {
  const owner = new PluginSettingsReloads({
    reload: async () => {
      throw new Error("stop failed: plugin.settings.conflict");
    },
    refresh: async () => {},
  });
  owner.require(receipt);
  await owner.confirm(receipt.pluginId);
  owner.postpone(receipt.pluginId);
  expect(owner.state(receipt.pluginId)?.error).toContain("stop failed");
  expect(owner.canPostpone(receipt.pluginId)).toBe(false);
}, 1000);

test("changed package retains the original acceptance receipt for explicit recovery", async () => {
  const owner = new PluginSettingsReloads({
    reload: async () => {
      throw new Error("plugin.settings.packageChanged");
    },
    refresh: async () => {},
  });
  owner.require(receipt);
  await owner.confirm(receipt.pluginId);
  owner.postpone(receipt.pluginId);
  expect(owner.states()).toHaveLength(1);
  expect(owner.state(receipt.pluginId)?.receipt.expectedPackageIdentity).toBe("accepted-package");
}, 1000);

test("global reload keeps its saved root when the originating workspace changes", async () => {
  const gate = deferred<void>();
  const calls: PluginReloadReceipt[] = [];
  const owner = new PluginSettingsReloads({
    reload: (value) => {
      calls.push(value);
      return gate.promise;
    },
    refresh: async () => {},
  });
  owner.require({ ...receipt });
  const running = owner.confirm(receipt.pluginId);
  try {
    const release = owner.subscribe(() => {});
    release();
    expect(owner.states()[0]?.busy).toBe(true);
    expect(calls[0]?.workspacePath).toBe("/fixture/project");
    gate.resolve();
    await running;
    expect(owner.states()).toEqual([]);
  } finally {
    gate.resolve();
    await running;
  }
}, 1000);

test("contribution refresh failure remains a visible retry instead of successful reload", async () => {
  const owner = new PluginSettingsReloads({
    reload: async () => {},
    refresh: async () => {
      throw new Error("catalog unavailable");
    },
  });
  owner.require(receipt);
  await owner.confirm(receipt.pluginId);
  expect(owner.state(receipt.pluginId)?.error).toContain("catalog unavailable");
}, 1000);

test("reloading one plugin preserves the pending reload of another", async () => {
  const other = { ...receipt, pluginId: "other.plugin" };
  const calls: PluginReloadReceipt[] = [];
  const owner = new PluginSettingsReloads({
    reload: async (value) => {
      calls.push(value);
    },
    refresh: async () => {},
  });
  owner.require(receipt);
  owner.require(other);
  await owner.confirm(receipt.pluginId);
  expect(calls).toEqual([receipt]);
  expect(owner.state(other.pluginId)?.receipt).toBe(other);
}, 1000);
