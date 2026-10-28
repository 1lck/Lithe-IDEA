import { afterEach, expect, test } from "bun:test";
import { McpConnectionManager, type McpConnectionState } from "./mcp-lifecycle";
import type { hostControl, IdeRequest } from "./ide-capabilities";

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
  const claimStarted = deferred<void>();
  const finishClaim = deferred<void>();
  const closed: string[] = [];
  const calls: string[] = [];
  const responses: string[] = [];
  const apis: { revoked: boolean }[] = [];
  const receivers = new Map<
    string,
    (event: { hostID: string; requestID: string }) => Promise<void>
  >();
  const requests = new Map<string, IdeRequest>();
  let failClaim = false;
  let failRespond = false;
  let sequence = 0;
  let now = 0;
  const control = async (action: string, args?: Record<string, unknown>): Promise<unknown> => {
    if (action === "close") {
      closed.push(args!.hostID as string);
      return {};
    }
    if (action === "claim") {
      claimStarted.resolve();
      await finishClaim.promise;
      if (failClaim) throw new Error("Transient IPC failure");
      const id = String(args!.requestID);
      const request = requests.get(id) ?? null;
      requests.delete(id);
      return { request: request ? { ...request, remainingMilliseconds: 1000 } : null };
    }
    if (action === "respond") {
      if (failRespond) throw new Error("Response delivery unknown");
      responses.push(String(args!.requestID));
      return { delivered: true };
    }
    throw new Error(`Unexpected action ${action}: no polling is allowed`);
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
          call: async (name: string) => {
            calls.push(name);
            return {};
          },
        };
        apis.push(api);
        return api;
      },
      paths: async () => ({ directory: "fixture", helperPath: "fixture/helper" }),
      control: control as typeof hostControl,
      now: () => now,
      open: async (_args, receive) => {
        const hostID = String(++sequence);
        receivers.set(hostID, receive);
        openStarted.resolve();
        if (hostID === "1") await finishOpen.promise;
        return { hostID, configuration: { hostID } };
      },
    },
    (next) => {
      state = next;
    },
  );
  const cleanup = async () => {
    finishOpen.resolve();
    finishClaim.resolve();
    await manager.closeAll();
    receivers.clear();
    requests.clear();
  };
  cleanups.add(cleanup);
  return {
    manager,
    apis,
    closed,
    calls,
    responses,
    openStarted,
    finishOpen,
    claimStarted,
    finishClaim,
    state: () => state,
    cleanup,
    setTime: (value: number) => {
      now = value;
    },
    failClaim: (value: boolean) => {
      failClaim = value;
    },
    failRespond: (value: boolean) => {
      failRespond = value;
    },
    queue: (id: string) =>
      requests.set(id, {
        requestID: id,
        name: "lithe_run_start",
        arguments: { configurationID: "fixture" },
      }),
    receive: (hostID: string, requestID: string) => receivers.get(hostID)!({ hostID, requestID }),
  };
}
const permissions = { configure: true, execute: true };

test("closing during open revokes access and closes the late native host", async () => {
  const f = fixture();
  const opening = f.manager.enable("project", "fixture", permissions);
  await f.openStarted.promise;
  const closing = f.manager.disable("project");
  expect(f.apis[0].revoked).toBe(true);
  f.finishOpen.resolve();
  await Promise.all([opening, closing]);
  expect(f.state().connections).toEqual({});
  expect(f.closed).toEqual(["1"]);
}, 1000);

test("closing all includes opens that have not published configuration", async () => {
  const f = fixture();
  const opening = f.manager.enable("project", "fixture", permissions);
  await f.openStarted.promise;
  const closing = f.manager.closeAll();
  f.finishOpen.resolve();
  await Promise.all([opening, closing]);
  expect(f.closed).toEqual(["1"]);
  expect(f.apis[0].revoked).toBe(true);
  expect(f.state().connections).toEqual({});
}, 1000);

test("native notification before open completes waits for the owning grant", async () => {
  const f = fixture();
  const opening = f.manager.enable("project", "fixture", permissions);
  await f.openStarted.promise;
  f.queue("request");
  f.finishClaim.resolve();
  const receiving = f.receive("1", "request");
  expect(f.calls).toEqual([]);
  f.finishOpen.resolve();
  await Promise.all([opening, receiving]);
  expect(f.calls).toEqual(["lithe_run_start"]);
  expect(f.state().connections.project.status).toBe("active");
}, 1000);

test("expired and duplicate native notifications never execute an operation", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  f.finishClaim.resolve();
  await f.manager.enable("project", "fixture", permissions);
  await f.receive("1", "expired");
  expect(f.calls).toEqual([]);
  f.queue("live");
  await f.receive("1", "live");
  const previousSnapshot = f.state().connections.project;
  await f.receive("1", "live");
  expect(f.calls).toEqual(["lithe_run_start"]);
  f.queue("next");
  await f.receive("1", "next");
  expect(f.state().connections.project).not.toBe(previousSnapshot);
}, 1000);

test("a failed claim preserves authorization and the next request recovers without reopening", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  f.finishClaim.resolve();
  await f.manager.enable("project", "fixture", permissions);
  f.failClaim(true);
  f.queue("failed");
  await f.receive("1", "failed");
  expect(f.state().connections.project.status).toBe("failed");
  expect(f.closed).toEqual([]);
  expect(f.apis[0].revoked).toBe(false);
  f.failClaim(false);
  f.queue("next");
  await f.receive("1", "next");
  expect(f.state().connections.project.status).toBe("active");
  expect(f.state().connections.project.error).toBeNull();
  expect(f.calls).toEqual(["lithe_run_start"]);
  expect(f.apis.length).toBe(1);
}, 1000);

test("an ambiguous response failure never repeats an accepted mutation", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  f.finishClaim.resolve();
  await f.manager.enable("project", "fixture", permissions);
  f.queue("mutation");
  f.failRespond(true);
  await f.receive("1", "mutation");
  expect(f.state().connections.project.status).toBe("failed");
  f.failRespond(false);
  await f.receive("1", "mutation");
  expect(f.calls).toEqual(["lithe_run_start"]);
  expect(f.responses).toEqual([]);
}, 1000);

test("closing or replacing a grant while claim is pending prevents late execution", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  await f.manager.enable("project", "fixture", permissions);
  f.queue("old");
  const receiving = f.receive("1", "old");
  await f.claimStarted.promise;
  await f.manager.enable("project", "fixture", permissions);
  f.finishClaim.resolve();
  await receiving;
  await f.receive("1", "late");
  expect(f.calls).toEqual([]);
  expect(f.state().connections.project.hostID).toBe("2");
  expect(f.state().connections.project.status).toBe("waiting");
  expect(f.apis[1].revoked).toBe(false);
  expect(f.closed).toEqual(["1"]);
}, 1000);

test("suspending during claim delivery cannot start an expired mutation", async () => {
  const f = fixture();
  f.finishOpen.resolve();
  await f.manager.enable("project", "fixture", permissions);
  f.queue("old");
  const receiving = f.receive("1", "old");
  await f.claimStarted.promise;
  f.setTime(2000);
  f.finishClaim.resolve();
  await receiving;
  expect(f.calls).toEqual([]);
  expect(f.state().connections.project.status).toBe("failed");
  expect(f.state().connections.project.error).toContain("expired");
  f.queue("new");
  await f.receive("1", "new");
  expect(f.calls).toEqual(["lithe_run_start"]);
}, 1000);
