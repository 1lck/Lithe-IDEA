import { expect, test } from "bun:test";
import type { WindowTitleContext } from "../utils/window-title-context";
import { startWindowTitleSync } from "./window-title-sync";

function context(fileName: string | null = "First.java"): WindowTitleContext {
  return {
    projects: [{ workspaceId: "demo", displayName: "demo", path: "C:/projects/demo" }],
    activeWorkspaceId: "demo",
    fileName,
  };
}

function harness() {
  let snapshot = context();
  const scheduled: Array<() => void> = [];
  const requests: Array<{
    context: WindowTitleContext;
    promise: Promise<void>;
    resolve: () => void;
    reject: (reason: unknown) => void;
  }> = [];
  const errors: unknown[] = [];
  let change: (() => void) | undefined;
  let focus: (() => void) | undefined;
  let cleanedUp = 0;
  const stop = startWindowTitleSync({
    readContext: () => snapshot,
    schedule: (callback) => scheduled.push(callback),
    subscribe: (listener) => {
      change = listener;
      return () => { change = undefined; cleanedUp++; };
    },
    subscribeFocus: (listener) => {
      focus = listener;
      return () => { focus = undefined; cleanedUp++; };
    },
    update: (value) => {
      let resolve!: () => void;
      let reject!: (reason: unknown) => void;
      const promise = new Promise<void>((complete, fail) => { resolve = complete; reject = fail; });
      requests.push({ context: value, promise, resolve, reject });
      return promise;
    },
    reportError: (error) => errors.push(error),
  });
  return {
    requests,
    errors,
    stop,
    change: (value = snapshot) => { snapshot = value; change?.(); },
    focus: () => focus?.(),
    flush: () => {
      while (scheduled.length) scheduled.shift()!();
    },
    cleanedUp: () => cleanedUp,
    dispose: async () => {
      stop();
      for (const request of requests) request.resolve();
      await Promise.allSettled(requests.map((request) => request.promise));
    },
  };
}

test("coalesces one synchronous workspace transition before reading its final state", async () => {
  const h = harness();
  try {
    h.change(context("Old.java"));
    h.change({ ...context("New.java"), projects: [{ workspaceId: "next", displayName: "next", path: "D:/next" }], activeWorkspaceId: "next" });
    h.flush();
    expect(h.requests).toHaveLength(1);
    expect(h.requests[0]!.context.activeWorkspaceId).toBe("next");
    expect(h.requests[0]!.context.fileName).toBe("New.java");
  } finally {
    await h.dispose();
  }
});

test("serializes native requests and sends only the latest pending file", async () => {
  const h = harness();
  try {
    h.flush();
    h.change(context("Second.java")); h.flush();
    h.change(context("Last.java")); h.flush();
    expect(h.requests).toHaveLength(1);
    h.requests[0]!.resolve();
    await Promise.resolve();
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.context.fileName).toBe("Last.java");
  } finally {
    await h.dispose();
  }
});

test("skips unchanged metadata but reapplies a successful context when focused", async () => {
  const h = harness();
  try {
    h.flush();
    h.requests[0]!.resolve();
    await Promise.resolve();
    h.change(context()); h.flush();
    expect(h.requests).toHaveLength(1);
    h.focus(); h.flush();
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.context).toEqual(h.requests[0]!.context);
  } finally {
    await h.dispose();
  }
});

test("focus refresh remains single flight and applies the latest state", async () => {
  const h = harness();
  try {
    h.flush();
    h.focus(); h.flush();
    h.change(context("Second.java")); h.flush();
    h.change(context()); h.flush();
    expect(h.requests).toHaveLength(1);
    h.requests[0]!.resolve();
    await Promise.resolve();
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.context.fileName).toBe("First.java");
  } finally {
    await h.dispose();
  }
});

test("drops a pending round trip back to the title that just succeeded", async () => {
  const h = harness();
  try {
    h.flush();
    h.change(context("Second.java")); h.flush();
    h.change(context()); h.flush();
    h.requests[0]!.resolve();
    await Promise.resolve();
    expect(h.requests).toHaveLength(1);
  } finally {
    await h.dispose();
  }
});

test("reports failure and retries unchanged context only after a focus event", async () => {
  const h = harness();
  try {
    h.flush();
    h.requests[0]!.reject(new Error("native unavailable"));
    await Promise.resolve();
    expect(h.errors).toHaveLength(1);
    h.change(context()); h.flush();
    expect(h.requests).toHaveLength(1);
    h.focus(); h.flush();
    expect(h.requests).toHaveLength(2);
  } finally {
    await h.dispose();
  }
});

test("recovers failed requests when project metadata changes", async () => {
  const h = harness();
  try {
    h.flush();
    h.requests[0]!.reject(new Error("temporary failure"));
    await Promise.resolve();
    h.change(context(null)); h.flush();
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.context.fileName).toBeNull();
  } finally {
    await h.dispose();
  }
});

test("failed B acknowledgement invalidates successful A cache before queued return to A", async () => {
  const h = harness();
  let nativeFile: string | null = null;
  try {
    h.flush(); nativeFile = h.requests[0]!.context.fileName;
    h.requests[0]!.resolve(); await Promise.resolve();
    h.change(context("B.java")); h.flush();
    nativeFile = h.requests[1]!.context.fileName;
    h.change(context()); h.flush();
    h.requests[1]!.reject(new Error("applied but acknowledgement failed"));
    await Promise.resolve();
    expect(h.requests).toHaveLength(3);
    nativeFile = h.requests[2]!.context.fileName;
    expect(nativeFile).toBe("First.java");
    h.requests[2]!.resolve(); await Promise.resolve();
    expect(h.errors).toHaveLength(1);
  } finally { await h.dispose(); }
});

test("disposal clears subscriptions and prevents scheduled or pending requests", async () => {
  const h = harness();
  try {
    h.flush();
    h.change(context("pending.java")); h.flush();
    h.change(context("scheduled.java"));
    h.stop();
    h.flush();
    h.requests[0]!.resolve();
    await Promise.resolve();
    h.focus(); h.change(context("after.java")); h.flush();
    expect(h.cleanedUp()).toBe(2);
    expect(h.requests).toHaveLength(1);
  } finally {
    await h.dispose();
  }
});
