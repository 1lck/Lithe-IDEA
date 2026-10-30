import { expect, test } from "bun:test";
import { sharedSlowRequestNotice, withSlowRequestNotice } from "./slow-request-notice";

function manualTimers() {
  const pending = new Map<number, () => void>();
  let next = 0;
  return {
    timers: {
      setTimeout: (callback: () => void) => {
        pending.set(++next, callback);
        return next;
      },
      clearTimeout: (handle: unknown) => {
        pending.delete(handle as number);
      },
    },
    elapse() {
      for (const [handle, callback] of [...pending]) {
        pending.delete(handle);
        callback();
      }
    },
    pending,
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

test("a fast request shows nothing and leaves no timer behind", async () => {
  const clock = manualTimers();
  const events: string[] = [];
  const result = await withSlowRequestNotice(
    Promise.resolve(42),
    { show: () => events.push("show"), dismiss: () => events.push("dismiss") },
    300,
    clock.timers,
  );
  expect(result).toBe(42);
  expect(events).toEqual([]);
  expect(clock.pending.size).toBe(0);
});

test("a slow request shows the notice and dismisses it when it settles", async () => {
  const clock = manualTimers();
  const request = deferred<string>();
  const events: string[] = [];
  const running = withSlowRequestNotice(
    request.promise,
    { show: () => events.push("show"), dismiss: () => events.push("dismiss") },
    300,
    clock.timers,
  );
  clock.elapse();
  expect(events).toEqual(["show"]);
  request.resolve("done");
  expect(await running).toBe("done");
  expect(events).toEqual(["show", "dismiss"]);
});

test("a failed slow request still dismisses the notice", async () => {
  const clock = manualTimers();
  const request = deferred<string>();
  const events: string[] = [];
  const running = withSlowRequestNotice(
    request.promise,
    { show: () => events.push("show"), dismiss: () => events.push("dismiss") },
    300,
    clock.timers,
  );
  clock.elapse();
  request.reject(new Error("timed out"));
  await expect(running).rejects.toThrow("timed out");
  expect(events).toEqual(["show", "dismiss"]);
});

test("overlapping slow requests close the shared notice after the last one", async () => {
  const clock = manualTimers();
  const events: string[] = [];
  const shared = sharedSlowRequestNotice(() => events.push("dismiss"));
  const notice = () => shared(() => events.push("show"));
  const first = deferred<string>();
  const second = deferred<string>();
  const running = [
    withSlowRequestNotice(first.promise, notice(), 300, clock.timers),
    withSlowRequestNotice(second.promise, notice(), 300, clock.timers),
  ];
  clock.elapse();
  first.resolve("first");
  await running[0];
  expect(events).toEqual(["show", "show"]);
  second.resolve("second");
  await running[1];
  expect(events).toEqual(["show", "show", "dismiss"]);
});

test("a fast request does not close a notice an earlier slow request shows", async () => {
  const clock = manualTimers();
  const events: string[] = [];
  const shared = sharedSlowRequestNotice(() => events.push("dismiss"));
  const notice = () => shared(() => events.push("show"));
  const slow = deferred<string>();
  const running = withSlowRequestNotice(slow.promise, notice(), 300, clock.timers);
  clock.elapse();
  await withSlowRequestNotice(Promise.resolve("fast"), notice(), 300, clock.timers);
  expect(events).toEqual(["show"]);
  slow.resolve("slow");
  await running;
  expect(events).toEqual(["show", "dismiss"]);
});
