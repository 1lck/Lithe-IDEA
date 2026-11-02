import { afterEach, expect, test } from "bun:test";
import {
  openWebPanelSession,
  webPanelCleanup,
  type WebPanelLayout,
  type WebPanelPorts,
} from "./web-panel-session";

const sessions: ReturnType<typeof openWebPanelSession>[] = [];
const releases: Array<() => void> = [];
function gate<T>(fallback: T) {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  releases.push(() => resolve(fallback));
  return { promise, resolve };
}
function layout(x: number): WebPanelLayout {
  return { bounds: { x, y: 0, width: 100, height: 100 }, visible: true, focus: false };
}
function open(key: string, ports: WebPanelPorts, publish: (phase: string) => void = () => {}) {
  const session = openWebPanelSession(key, key, ports, publish);
  sessions.push(session);
  return session;
}
afterEach(async () => {
  for (const release of releases.splice(0)) release();
  await Promise.allSettled(sessions.splice(0).map((session) => session.dispose()));
  expect(webPanelCleanup.pending()).toEqual([]);
});

test("removal during native creation closes the returned receipt without making the late view visible", async () => {
  const started = gate(undefined);
  const opening = gate({ mountId: "native-late" });
  const events: string[] = [];
  const session = open("late", {
    mount: async () => {
      events.push("mount");
      started.resolve(undefined);
      return opening.promise;
    },
    layout: async () => {
      events.push("layout");
    },
    unmount: async (id) => {
      events.push(`close:${id}`);
    },
  });
  session.update(layout(1));
  await started.promise;
  const closing = session.dispose();
  opening.resolve({ mountId: "native-late" });
  await closing;
  expect(events).toEqual(["mount", "close:native-late"]);
}, 1000);

test("geometry keeps one in-flight command and replaces queued frames with the latest physical bounds", async () => {
  const first = gate(undefined),
    second = gate(undefined),
    release = gate(undefined);
  const calls: Array<{ id: string; revision: number; x: number }> = [];
  const session = open("geometry", {
    mount: async () => ({ mountId: "native-geometry" }),
    layout: async (id, revision, value) => {
      calls.push({ id, revision, x: value.bounds.x });
      if (calls.length === 1) {
        first.resolve(undefined);
        await release.promise;
      } else second.resolve(undefined);
    },
    unmount: async () => {},
  });
  await session.ready;
  session.update(layout(1));
  await first.promise;
  session.update(layout(2));
  session.update(layout(3));
  release.resolve(undefined);
  await second.promise;
  await session.dispose();
  expect(calls).toEqual([
    { id: "native-geometry", revision: 1, x: 1 },
    { id: "native-geometry", revision: 2, x: 3 },
  ]);
}, 1000);

for (const boundary of ["mount", "layout"] as const) {
  test(`keyboard focus survives later geometry while native ${boundary} is pending`, async () => {
    const opening = gate({ mountId: `focus-${boundary}` });
    const started = gate(undefined),
      release = gate(undefined),
      sent = gate(undefined);
    const calls: WebPanelLayout[] = [];
    const session = open(`focus-${boundary}`, {
      mount: () =>
        boundary === "mount" ? opening.promise : Promise.resolve({ mountId: "focus-layout" }),
      layout: async (_id, _revision, value) => {
        calls.push(value);
        if (boundary === "layout" && calls.length === 1) {
          started.resolve(undefined);
          await release.promise;
        } else sent.resolve(undefined);
      },
      unmount: async () => {},
    });
    if (boundary === "layout") {
      await session.ready;
      session.update(layout(0));
      await started.promise;
    }
    session.update({ ...layout(1), focus: true });
    session.update(layout(2));
    opening.resolve({ mountId: "focus-mount" });
    release.resolve(undefined);
    await sent.promise;
    await session.dispose();
    expect(calls[calls.length - 1]).toEqual({ ...layout(2), focus: true });
    expect(calls.filter((value) => value.focus)).toHaveLength(1);
  }, 1000);
}

test("occlusion cancels queued keyboard focus instead of stealing a modal's focus later", async () => {
  const opening = gate({ mountId: "focus-hidden" }),
    sent = gate(undefined);
  const calls: WebPanelLayout[] = [];
  const session = open("focus-hidden", {
    mount: () => opening.promise,
    layout: async (_id, _revision, value) => {
      calls.push(value);
      sent.resolve(undefined);
    },
    unmount: async () => {},
  });
  session.update({ ...layout(1), focus: true });
  session.update({ ...layout(2), visible: false });
  session.update(layout(3));
  opening.resolve({ mountId: "focus-hidden" });
  await sent.promise;
  await session.dispose();
  expect(calls).toEqual([layout(3)]);
}, 1000);

test("failed cleanup remains visible and a replacement cannot bypass the previous native owner", async () => {
  let rejectClose = true;
  const previous = open("blocked", {
    mount: async () => ({ mountId: "previous" }),
    layout: async () => {},
    unmount: async () => {
      if (rejectClose) throw new Error("controlled close failure");
    },
  });
  try {
    await previous.ready;
    await expect(previous.dispose()).rejects.toThrow("controlled close failure");
    expect(webPanelCleanup.pending()).toContain(previous);
    let replacements = 0;
    const next = open("blocked", {
      mount: async () => {
        replacements++;
        return { mountId: "next" };
      },
      layout: async () => {},
      unmount: async () => {},
    });
    await expect(next.ready).rejects.toThrow("controlled close failure");
    expect(replacements).toBe(0);
    rejectClose = false;
    await previous.dispose();
    await next.dispose();
    expect(webPanelCleanup.pending()).not.toContain(previous);
    const reopened = open("blocked", {
      mount: async () => {
        replacements++;
        return { mountId: "reopened" };
      },
      layout: async () => {},
      unmount: async () => {},
    });
    await reopened.ready;
    expect(replacements).toBe(1);
  } finally {
    rejectClose = false;
  }
}, 1000);

test("a closed session cannot release the receipt of its replacement", async () => {
  const closed: string[] = [];
  const ports = (id: string): WebPanelPorts => ({
    mount: async () => ({ mountId: id }),
    layout: async () => {},
    unmount: async (receipt) => {
      closed.push(receipt);
    },
  });
  const old = open("replacement", ports("native-old"));
  await old.ready;
  const next = open("replacement", ports("native-new"));
  await next.ready;
  await old.dispose();
  expect(closed).toEqual(["native-old"]);
  await next.dispose();
  expect(closed).toEqual(["native-old", "native-new"]);
}, 1000);

test("a partial mount failure retains the native cleanup receipt rather than the submitted request id", async () => {
  let rejectClose = true;
  const ids: string[] = [];
  const session = open("partial", {
    mount: async () => {
      throw JSON.stringify({
        code: "plugin.web.cleanupFailed",
        mountId: "native-partial",
        message: "controlled",
      });
    },
    layout: async () => {},
    unmount: async (id) => {
      ids.push(id);
      if (rejectClose) throw new Error("close failed");
    },
  });
  try {
    await expect(session.ready).rejects.toThrow();
    await expect(session.dispose()).rejects.toThrow("close failed");
    expect(webPanelCleanup.pending()).toContain(session);
    rejectClose = false;
    await session.dispose();
    expect(ids).toEqual(["native-partial", "native-partial"]);
  } finally {
    rejectClose = false;
  }
}, 1000);

test("layout failure publishes an error and leaves the original receipt available for cleanup", async () => {
  const failed = gate(undefined);
  const closed: string[] = [];
  const session = open(
    "layout-error",
    {
      mount: async () => ({ mountId: "native-layout-error" }),
      layout: async () => {
        throw new Error("controlled layout failure");
      },
      unmount: async (id) => {
        closed.push(id);
      },
    },
    (phase) => {
      if (phase === "failed") failed.resolve(undefined);
    },
  );
  await session.ready;
  session.update(layout(1));
  await failed.promise;
  expect(session.phase).toBe("failed");
  await session.dispose();
  expect(closed).toEqual(["native-layout-error"]);
}, 1000);
