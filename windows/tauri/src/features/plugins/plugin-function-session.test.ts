import { describe, expect, test } from "bun:test";
import {
  PluginFunctionSession,
  type FunctionInput,
  type FunctionPorts,
  type FunctionReview,
  type FunctionSnapshot,
} from "./plugin-function-session";

const input: FunctionInput = {
  pluginId: "example.plugin",
  actionId: "refresh",
  workspacePath: "/fixture/project",
  expectedIdentity: "global+project-bytes",
  operationId: "operation-one",
};
function review(value = input): FunctionReview {
  return {
    context: {
      window: "workspace-one",
      windowIncarnation: 7,
      pluginId: value.pluginId,
      actionId: value.actionId,
      functionId: "snapshot.refresh",
      workspacePath: value.workspacePath,
      generation: 3,
      packageIdentity: "all-package-bytes",
      settingIdentity: value.expectedIdentity,
      operationId: value.operationId,
    },
    title: "Refresh",
    confirm: true,
    executesProjectCode: true,
    mayUseNetwork: false,
    program: { serverPath: "/fixture/backend" },
    launchPlan: {},
  };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}
function fixture(overrides: Partial<FunctionPorts> = {}, value = input) {
  const calls: string[] = [];
  const owners = new Set<PluginFunctionSession>();
  let current = true;
  let expired: (() => void) | null = null;
  const ports: FunctionPorts = {
    prepare: async () => {
      calls.push("prepare");
      return review(value);
    },
    confirm: async () => {
      calls.push("confirm");
    },
    read: async () => ({
      context: review(value).context,
      phase: "succeeded",
      result: { refreshed: true },
    }),
    cancel: async (id) => {
      calls.push(`cancel:${id}`);
    },
    assertCurrent: () => {
      if (!current) throw new Error("plugin.function.staleContext");
    },
    wait: async () => {},
    deadline: (callback) => {
      expired = callback;
      return () => {
        expired = null;
      };
    },
    ...overrides,
  };
  const session = new PluginFunctionSession(
    value,
    ports,
    () => {},
    (owner, retained) => {
      if (retained) owners.add(owner);
      else owners.delete(owner);
    },
  );
  return {
    session,
    calls,
    owners,
    stale: () => {
      current = false;
    },
    expire: () => expired?.(),
    hasDeadline: () => expired !== null,
  };
}

describe("plugin function consent and identity", () => {
  test("opening is passive; prepare never starts; confirmation returns actual result and releases", async () => {
    const f = fixture();
    try {
      expect(f.calls).toEqual([]);
      await f.session.prepare();
      expect(f.calls).toEqual(["prepare"]);
      expect(f.session.state.phase).toBe("review");
      await f.session.confirm();
      expect(f.session.state.result).toEqual({ refreshed: true });
      expect(f.session.state.phase).toBe("succeeded");
      expect(f.calls).toEqual(["prepare", "confirm", "cancel:operation-one"]);
      expect(f.owners.size).toBe(0);
      expect(f.hasDeadline()).toBe(false);
    } finally {
      f.session.dispose();
      await f.session.cancel();
    }
  }, 1000);

  test("cancelled confirmation never starts a process or writes a setting", async () => {
    const f = fixture();
    try {
      await f.session.prepare();
      await f.session.cancel();
      await f.session.confirm();
      expect(f.calls).toEqual(["prepare", "cancel:operation-one"]);
      expect(f.session.state.phase).toBe("cancelled");
    } finally {
      f.session.dispose();
      await f.session.cancel();
    }
  }, 1000);

  test("a CAS conflict cannot start a function", async () => {
    const f = fixture({
      prepare: async () => {
        throw new Error("plugin.settings.conflict");
      },
    });
    try {
      await f.session.prepare();
      await f.session.confirm();
      expect(f.calls).toEqual([]);
      expect(f.session.state.error?.message).toContain("conflict");
      expect(f.owners.size).toBe(0);
    } finally {
      f.session.dispose();
      await f.session.cancel();
    }
  }, 1000);

  test("another plugin, action, snapshot or operation in a review is rejected", async () => {
    for (const patch of [
      { pluginId: "other.plugin" },
      { actionId: "other" },
      { settingIdentity: "old" },
      { operationId: "other-operation" },
      { workspacePath: "/fixture/other" },
    ]) {
      const foreign = review();
      Object.assign(foreign.context, patch);
      const f = fixture({ prepare: async () => foreign });
      try {
        await f.session.prepare();
        await f.session.confirm();
        expect(f.calls).not.toContain("confirm");
        expect(f.session.state.phase).toBe("failed");
        expect(f.calls).toEqual(["cancel:operation-one"]);
      } finally {
        f.session.dispose();
        await f.session.cancel();
      }
    }
  }, 1000);
});

describe("plugin function owned cancellation", () => {
  test("stopping one plugin cannot stop another plugin's operation", async () => {
    const first = fixture();
    const second = fixture(
      {},
      { ...input, pluginId: "other.plugin", operationId: "operation-two" },
    );
    try {
      await first.session.prepare();
      await second.session.prepare();
      await first.session.cancel();
      expect(first.calls).toEqual(["prepare", "cancel:operation-one"]);
      expect(second.calls).toEqual(["prepare"]);
      expect(second.session.state.phase).toBe("review");
      expect(second.owners.size).toBe(1);
      await second.session.confirm();
      expect(second.session.state.result).toEqual({ refreshed: true });
      expect(second.calls).toEqual(["prepare", "confirm", "cancel:operation-two"]);
    } finally {
      first.session.dispose();
      second.session.dispose();
      await first.session.cancel();
      await second.session.cancel();
    }
  }, 1000);

  test("late preparation after page disposal is cancelled by the same owner", async () => {
    const gate = deferred<FunctionReview>();
    const f = fixture({ prepare: () => gate.promise });
    const pending = f.session.prepare();
    f.session.dispose();
    const stopping = f.session.cancel();
    try {
      expect(f.owners.size).toBe(1);
      gate.resolve(review());
      await pending;
      await stopping;
      expect(f.calls).toEqual(["cancel:operation-one"]);
      expect(f.owners.size).toBe(0);
    } finally {
      gate.resolve(review());
      await pending;
      await stopping;
    }
  }, 1000);

  test("late start completion and concurrent Stop join one cleanup attempt", async () => {
    const gate = deferred<void>();
    const f = fixture({ confirm: () => gate.promise });
    await f.session.prepare();
    const running = f.session.confirm();
    const stopping = f.session.cancel();
    try {
      expect(f.session.cancel()).toBe(stopping);
      expect(f.calls).toEqual(["prepare"]);
      gate.resolve();
      await running;
      await stopping;
      expect(f.calls.filter((call) => call.startsWith("cancel:"))).toHaveLength(1);
      expect(f.session.state.result).toBeUndefined();
    } finally {
      gate.resolve();
      await running;
      await stopping;
      f.session.dispose();
    }
  }, 1000);

  test("failed cleanup remains retryable after page unmount", async () => {
    let fails = true;
    const f = fixture({
      cancel: async () => {
        if (fails) throw new Error("cleanup failed");
      },
    });
    try {
      await f.session.prepare();
      f.session.dispose();
      await f.session.cancel();
      expect(f.session.state.phase).toBe("cleanupFailed");
      expect(f.owners.size).toBe(1);
      fails = false;
      await f.session.cancel();
      expect(f.owners.size).toBe(0);
    } finally {
      fails = false;
      await f.session.cancel();
    }
  }, 1000);

  test("old workspace results and progress cannot publish after a switch", async () => {
    const gate = deferred<FunctionSnapshot>();
    const f = fixture({ read: () => gate.promise });
    await f.session.prepare();
    const running = f.session.confirm();
    try {
      f.stale();
      gate.resolve({
        context: review().context,
        phase: "succeeded",
        result: "old result",
        progress: { message: "old progress" },
      });
      await running;
      expect(f.session.state.result).toBeUndefined();
      expect(f.session.state.progress).toBeNull();
      expect(f.owners.size).toBe(0);
    } finally {
      gate.resolve({ context: review().context, phase: "cancelled" });
      await running;
      f.session.dispose();
      await f.session.cancel();
    }
  }, 1000);

  test("progress comes from the exact native receipt and terminal null is a result", async () => {
    const gate = deferred<void>();
    const entered = deferred<void>();
    let reads = 0;
    const f = fixture({
      read: async () => ({
        context: review().context,
        phase: ++reads === 1 ? "running" : "succeeded",
        progress: { message: "refreshing", percentage: 40 },
        result: null,
      }),
      wait: () => {
        entered.resolve();
        return gate.promise;
      },
    });
    await f.session.prepare();
    const running = f.session.confirm();
    try {
      await entered.promise;
      expect(f.session.state.progress?.percentage).toBe(40);
      gate.resolve();
      await running;
      expect(f.session.state.result).toBeNull();
      expect(f.session.state.progress).toBeNull();
    } finally {
      gate.resolve();
      entered.resolve();
      await running;
      f.session.dispose();
      await f.session.cancel();
    }
  }, 1000);

  test("foreign-generation snapshots and backend errors never become success", async () => {
    const f = fixture({
      read: async () => ({
        context: { ...review().context, generation: 4 },
        phase: "succeeded",
        result: "foreign",
      }),
    });
    try {
      await f.session.prepare();
      await f.session.confirm();
      expect(f.session.state.phase).toBe("failed");
      expect(f.session.state.result).toBeUndefined();
    } finally {
      f.session.dispose();
      await f.session.cancel();
    }
    const failed = fixture({
      read: async () => ({
        context: review().context,
        phase: "failed",
        error: {
          code: "plugin.function.failed",
          message: "backend failure",
          pluginErrorCode: "example.rebuildFailed",
        },
      }),
    });
    try {
      await failed.session.prepare();
      await failed.session.confirm();
      expect(failed.session.state.error?.pluginErrorCode).toBe("example.rebuildFailed");
      expect(failed.session.state.phase).toBe("failed");
    } finally {
      failed.session.dispose();
      await failed.session.cancel();
    }
  }, 1000);

  test("native cleanup failure and local deadline retain their explicit Stop owner", async () => {
    const f = fixture({
      read: async () => ({
        context: review().context,
        phase: "cleanupFailed",
        error: { code: "plugin.function.cleanupFailed", message: "stop uncertain" },
      }),
    });
    try {
      await f.session.prepare();
      await f.session.confirm();
      expect(f.owners.size).toBe(1);
      expect(f.session.state.phase).toBe("cleanupFailed");
      await f.session.cancel();
      expect(f.owners.size).toBe(0);
    } finally {
      f.session.dispose();
      await f.session.cancel();
    }
    const deadline = fixture();
    try {
      await deadline.session.prepare();
      deadline.expire();
      await deadline.session.cancel();
      expect(deadline.calls).not.toContain("confirm");
      expect(deadline.owners.size).toBe(0);
    } finally {
      deadline.session.dispose();
      await deadline.session.cancel();
    }
  }, 1000);
});
