import { expect, test } from "bun:test";
import { prepareNativeBuildTool } from "./build-tool-preparation";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}

test("an already cancelled tool preparation never allocates a native owner", async () => {
  const controller = new AbortController(); controller.abort(new Error("closed"));
  let called = false;
  await expect(prepareNativeBuildTool({ begin: async () => { called = true; return "owner"; },
    resolve: async () => "result", cancel: async () => {} }, controller.signal)).rejects.toThrow("closed");
  expect(called).toBe(false);
}, 5000);

test("abort during registration cancels its returned owner before dispatch", async () => {
  const controller = new AbortController(), registration = deferred<string>();
  const calls: string[] = [];
  const completion = prepareNativeBuildTool({ begin: () => registration.promise,
    resolve: async () => { calls.push("resolve"); return "result"; },
    cancel: async id => { calls.push(`cancel:${id}`); } }, controller.signal).catch(error => error.message);
  try {
    controller.abort(new Error("closed")); registration.resolve("late-owner");
    expect(await completion).toBe("closed"); expect(calls).toEqual(["cancel:late-owner"]);
  } finally { registration.resolve("late-owner"); await completion; }
}, 5000);

test("abort reaches the native owner while the caller still drains its worker", async () => {
  const controller = new AbortController(), entered = deferred<void>(), worker = deferred<string>();
  const cancelled = deferred<void>(), calls: string[] = [];
  const completion = prepareNativeBuildTool({ begin: async () => "owner",
    resolve: async id => { calls.push(`resolve:${id}`); entered.resolve(); return await worker.promise; },
    cancel: async id => { calls.push(`cancel:${id}`); cancelled.resolve(); } }, controller.signal).catch(error => error.message);
  try {
    await entered.promise; controller.abort(new Error("revoked")); await cancelled.promise;
    expect(calls).toEqual(["resolve:owner", "cancel:owner"]);
    worker.resolve("late result"); expect(await completion).toBe("revoked");
    expect(calls).toHaveLength(2);
  } finally { worker.resolve("cleanup"); await completion; }
}, 5000);

test("completed and failed dispatch both retire the pending native registration", async () => {
  for (const fail of [false, true]) {
    const calls: string[] = [];
    const completion = prepareNativeBuildTool({ begin: async () => "owner",
      resolve: async () => { if (fail) throw new Error("dispatch failed"); return "result"; },
      cancel: async id => { calls.push(id); } }).catch(error => error.message);
    expect(await completion).toBe(fail ? "dispatch failed" : "result"); expect(calls).toEqual(["owner"]);
  }
}, 5000);

test("a failed cancellation acknowledgement remains an observable cleanup failure", async () => {
  await expect(prepareNativeBuildTool({ begin: async () => "owner", resolve: async () => "result",
    cancel: async () => { throw new Error("native cleanup rejected"); } })).rejects.toThrow("native cleanup rejected");
}, 5000);
