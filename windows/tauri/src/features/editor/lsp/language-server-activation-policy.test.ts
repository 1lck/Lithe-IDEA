import { afterEach, expect, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/lsp/activation-policy-v1.json";
import { LanguageServerActivationHistory } from "./language-server-activation-policy";

let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
});

/** Answers each request with the shared fixture case that has the same request. */
function replayFixture(requests: unknown[]) {
  const spy = spyOn(core, "invoke").mockImplementation((async (command, args) => {
    expect(command).toBe("lsp.activationPolicy");
    requests.push(args);
    const match = fixture.cases.find((entry) => Bun.deepEquals(entry.request, args));
    if (!match) throw new Error(`No fixture case for ${JSON.stringify(args)}`);
    return match.response;
  }) as typeof core.invoke);
  restore = () => spy.mockRestore();
}

test("stores Core state per server and sends the monotonic clock", async () => {
  const requests: unknown[] = [];
  replayFixture(requests);
  let now = 1000.9;
  const history = new LanguageServerActivationHistory(() => now);

  expect((await history.apply("C:/w:server-a", "startFailed")).decision).toBe("wait");
  now = 5999;
  const waiting = await history.apply("C:/w:server-a", "automaticStart");
  expect(waiting).toEqual({ state: { consecutiveFailures: 1, lastFailureAtMs: 1000 }, decision: "wait", retryAfterMs: 1 });
  now = 1000;
  // Another workspace keeps its own history.
  expect((await history.apply("C:/other:server-a", "automaticStart")).decision).toBe("allow");

  expect(requests).toEqual([
    { state: null, event: "startFailed", nowMs: 1000 },
    { state: { consecutiveFailures: 1, lastFailureAtMs: 1000 }, event: "automaticStart", nowMs: 5999 },
    { state: null, event: "automaticStart", nowMs: 1000 },
  ]);
});

test("a cleared or released history is not sent again", async () => {
  const requests: unknown[] = [];
  replayFixture(requests);
  let now = 1000;
  const history = new LanguageServerActivationHistory(() => now);
  // Seed two failures through the fixture's own transitions.
  await history.apply("k", "startFailed");
  now = 7000;
  await history.apply("k", "startFailed");
  now = 8000;
  expect((await history.apply("k", "ready")).state).toBeNull();
  now = 1000;
  await history.apply("k", "startFailed");
  history.release("k");
  await history.apply("k", "automaticStart");

  expect(requests[requests.length - 1]).toEqual({ state: null, event: "automaticStart", nowMs: 1000 });
});
