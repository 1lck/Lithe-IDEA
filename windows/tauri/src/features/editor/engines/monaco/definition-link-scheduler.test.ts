import { describe, expect, mock, test } from "bun:test";
import { DefinitionHoverScheduler } from "./definition-link-scheduler";

interface TestRequest {
  key: string;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

function timerHarness() {
  let nextID = 0;
  const callbacks = new Map<number, () => void>();

  return {
    schedule(callback: () => void) {
      const id = ++nextID;
      callbacks.set(id, callback);
      return id;
    },
    cancel(id: number) {
      callbacks.delete(id);
    },
    flush() {
      const scheduled = Array.from(callbacks.values());
      callbacks.clear();
      for (const callback of scheduled) callback();
    },
    count() {
      return callbacks.size;
    },
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

describe("definition hover scheduler", () => {
  test("publishes immediate feedback before delayed semantic resolution", () => {
    const timers = timerHarness();
    const events: string[] = [];
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: async () => {
        events.push("resolve");
        return "target";
      },
      onActiveRequest: () => events.push("active"),
      onActiveResult: () => events.push("result"),
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "symbol" });

    expect(events).toEqual(["active"]);
    expect(timers.count()).toBe(1);
  });

  test("debounces hover and resolves only the latest word", async () => {
    const timers = timerHarness();
    const resolveRequest = mock(async (request: TestRequest) => `target:${request.key}`);
    const onActiveResult = mock(() => undefined);
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: resolveRequest,
      onActiveResult,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "first" });
    scheduler.activate({ key: "second" });

    expect(timers.count()).toBe(1);
    expect(resolveRequest).toHaveBeenCalledTimes(0);

    timers.flush();
    await flushPromises();

    expect(resolveRequest).toHaveBeenCalledTimes(1);
    expect(resolveRequest).toHaveBeenCalledWith({ key: "second" });
    expect(onActiveResult).toHaveBeenCalledWith({ key: "second" }, "target:second");
  });

  test("keeps one request in flight and replaces queued hover work with the latest word", async () => {
    const timers = timerHarness();
    const pending = new Map<string, ReturnType<typeof deferred<string>>>();
    const calls: string[] = [];
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: (request) => {
        calls.push(request.key);
        const requestResult = deferred<string>();
        pending.set(request.key, requestResult);
        return requestResult.promise;
      },
      onActiveResult: () => undefined,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "first" });
    timers.flush();
    expect(calls).toEqual(["first"]);

    scheduler.activate({ key: "second" });
    timers.flush();
    scheduler.activate({ key: "third" });
    timers.flush();
    expect(calls).toEqual(["first"]);

    pending.get("first")?.resolve("target:first");
    await flushPromises();
    expect(calls).toEqual(["first", "third"]);
  });

  test("shares an in-flight click resolution and reuses its cached result", async () => {
    const timers = timerHarness();
    const requestResult = deferred<string>();
    const resolveRequest = mock(() => requestResult.promise);
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: resolveRequest,
      onActiveResult: () => undefined,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "shared" });
    timers.flush();
    const clickResult = scheduler.resolveNow({ key: "shared" });

    requestResult.resolve("target:shared");
    expect(await clickResult).toBe("target:shared");
    expect(await scheduler.resolveNow({ key: "shared" })).toBe("target:shared");
    expect(resolveRequest).toHaveBeenCalledTimes(1);
  });

  test("promotes a queued hover when a click reuses it", async () => {
    const timers = timerHarness();
    const pending = new Map<string, ReturnType<typeof deferred<string>>>();
    const calls: string[] = [];
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: (request) => {
        calls.push(request.key);
        const requestResult = deferred<string>();
        pending.set(request.key, requestResult);
        return requestResult.promise;
      },
      onActiveResult: () => undefined,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "in-flight" });
    timers.flush();
    scheduler.activate({ key: "clicked" });
    timers.flush();
    const clickResult = scheduler.resolveNow({ key: "clicked" });
    scheduler.activate({ key: "later-hover" });
    timers.flush();

    pending.get("in-flight")?.resolve("target:in-flight");
    await flushPromises();
    expect(calls).toEqual(["in-flight", "clicked"]);

    pending.get("clicked")?.resolve("target:clicked");
    expect(await clickResult).toBe("target:clicked");
    expect(calls).not.toContain("later-hover");
  });

  test("drops an in-flight result after the model is reset", async () => {
    const timers = timerHarness();
    const requestResult = deferred<string>();
    const resolveRequest = mock(() => requestResult.promise);
    const onActiveResult = mock(() => undefined);
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: resolveRequest,
      onActiveResult,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "stale" });
    timers.flush();
    scheduler.reset();
    requestResult.resolve("target:stale");
    await flushPromises();

    expect(onActiveResult).toHaveBeenCalledTimes(0);
    expect(await scheduler.resolveNow({ key: "stale" })).toBe("target:stale");
    expect(resolveRequest).toHaveBeenCalledTimes(2);
  });

  test("does not publish an in-flight result after disposal", async () => {
    const timers = timerHarness();
    const requestResult = deferred<string>();
    const onActiveResult = mock(() => undefined);
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: () => requestResult.promise,
      onActiveResult,
      scheduleTimer: (callback) => timers.schedule(callback),
      cancelTimer: (id) => timers.cancel(id as number),
    });

    scheduler.activate({ key: "closing-editor" });
    timers.flush();
    scheduler.dispose();
    requestResult.resolve("target:closing-editor");
    await flushPromises();

    expect(await scheduler.resolveNow({ key: "closing-editor" })).toBeUndefined();
    expect(onActiveResult).toHaveBeenCalledTimes(0);
  });

  test("evicts the least recently used cached result", async () => {
    const resolveRequest = mock(async (request: TestRequest) => `target:${request.key}`);
    const scheduler = new DefinitionHoverScheduler<TestRequest, string>({
      delayMilliseconds: 150,
      keyOf: (request) => request.key,
      resolve: resolveRequest,
      onActiveResult: () => undefined,
      cacheLimit: 2,
    });

    await scheduler.resolveNow({ key: "first" });
    await scheduler.resolveNow({ key: "second" });
    expect(await scheduler.resolveNow({ key: "first" })).toBe("target:first");
    expect(resolveRequest).toHaveBeenCalledTimes(2);
    await scheduler.resolveNow({ key: "third" });

    expect(await scheduler.resolveNow({ key: "first" })).toBe("target:first");
    expect(resolveRequest).toHaveBeenCalledTimes(3);
    expect(await scheduler.resolveNow({ key: "second" })).toBe("target:second");
    expect(resolveRequest).toHaveBeenCalledTimes(4);
  });
});
