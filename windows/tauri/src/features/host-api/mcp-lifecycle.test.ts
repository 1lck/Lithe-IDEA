import { afterEach, expect, test } from "bun:test";
import { McpConnectionManager, type McpConnectionState } from "./mcp-lifecycle";
import type { hostControl } from "./ide-capabilities";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}

const cleanups = new Set<() => Promise<void>>();
afterEach(async () => {
  try {
    await Promise.all([...cleanups].map((cleanup) => cleanup()));
  } finally {
    cleanups.clear();
  }
});

function fixture() {
  let state: McpConnectionState = { connections: {}, error: null };
  const openStarted = deferred<void>();
  const finishOpen = deferred<void>();
  const oldPoll = deferred<{ requests: [] }>();
  const oldPollFinished = deferred<void>();
  const closed: string[] = [];
  const apis: { revoked: boolean }[] = [];
  const timers = new Set<ReturnType<typeof setTimeout>>();
  let sequence = 0;
  const control = async (action: string, args?: Record<string, unknown>): Promise<unknown> => {
    if (action === "open") {
      const hostID = String(++sequence);
      openStarted.resolve();
      if (hostID === "1") await finishOpen.promise;
      return { hostID, configuration: { hostID } };
    }
    if (action === "close") {
      closed.push(args!.hostID as string);
      return {};
    }
    if (action === "poll" && args!.hostID === "1") {
      try {
        return await oldPoll.promise;
      } finally {
        oldPollFinished.resolve();
      }
    }
    return { requests: [] };
  };
  const manager = new McpConnectionManager(
    {
      createAPI: (_id, _root, permissions) => {
        const api = {
          revoked: false,
          permissions,
          revoke() {
            this.revoked = true;
          },
          isCurrent() {
            return !this.revoked;
          },
          call: async () => ({}),
        };
        apis.push(api);
        return api;
      },
      paths: async () => ({ directory: "fixture", helperPath: "fixture/helper" }),
      control: control as typeof hostControl,
      schedule: () => {
        const timer = {} as ReturnType<typeof setTimeout>;
        timers.add(timer);
        return timer;
      },
      cancel: (timer) => {
        if (timer) timers.delete(timer);
      },
    },
    (next) => {
      state = next;
    },
  );
  const cleanup = async () => {
    openStarted.resolve();
    finishOpen.resolve();
    oldPoll.resolve({ requests: [] });
    oldPollFinished.resolve();
    await manager.closeAll();
  };
  cleanups.add(cleanup);
  return {
    manager,
    apis,
    closed,
    timers,
    openStarted,
    finishOpen,
    oldPoll,
    oldPollFinished,
    state: () => state,
    cleanup,
  };
}
const permissions = { configure: true, execute: true };

test("closing a project during native open revokes access and closes the late host", async () => {
  const f = fixture();
  const opening = f.manager.enable("project", "fixture", permissions);
  let closing: Promise<void> | undefined;
  try {
    await f.openStarted.promise;
    closing = f.manager.disable("project");
    expect(f.apis[0].revoked).toBe(true);
    f.finishOpen.resolve();
    await Promise.all([opening, closing]);
    expect(f.state().connections).toEqual({});
    expect(f.closed).toEqual(["1"]);
    expect(f.timers.size).toBe(0);
  } finally {
    await f.cleanup();
    await Promise.all([opening, closing]);
  }
}, 1000);

test("an old poll failure cannot revoke the replacement grant", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  try {
    await f.manager.enable("project", "fixture", permissions);
    await f.manager.enable("project", "fixture", permissions);
    f.oldPoll.reject(new Error("old host was closed"));
    await f.oldPollFinished.promise;
    // The native double settles first; let the pump consume that rejection.
    await Promise.resolve();
    expect(f.state().connections.project.hostID).toBe("2");
    expect(f.apis[1].revoked).toBe(false);
    expect(f.state().error).toBeNull();
    expect(f.closed).toEqual(["1"]);
  } finally {
    await f.cleanup();
  }
  expect(f.timers.size).toBe(0);
}, 1000);

test("closing all connections includes opens that have not published their configuration", async () => {
  const f = fixture();
  const opening = f.manager.enable("project", "fixture", permissions);
  let closing: Promise<void> | undefined;
  try {
    await f.openStarted.promise;
    closing = f.manager.closeAll();
    f.finishOpen.resolve();
    await Promise.all([opening, closing]);
    expect(f.closed).toEqual(["1"]);
    expect(f.apis[0].revoked).toBe(true);
    expect(f.state().connections).toEqual({});
  } finally {
    await f.cleanup();
    await Promise.all([opening, closing]);
  }
}, 1000);
