import { describe, expect, test } from "bun:test";

// Window scoping is mocked in run-host-api.test.ts for the full `bun test src/features/run` suite.
const { createRunStore } = await import("./run.store");
const { PRIMARY_SESSION_ID } = await import("../types/run.types");

describe("run output session lifecycle", () => {
  test("stop flushes a held prefix that never received a newline", async () => {
    const store = createRunStore();
    store.getState().actions.appendOutput(PRIMARY_SESSION_ID, "\u001b[32m");
    expect(store.getState().primaryOutput).toBe("");
    await store.getState().actions.stop(PRIMARY_SESSION_ID);
    expect(store.getState().primaryOutput).toBe("\u001b[32m");
    expect(store.getState().primaryRunning).toBe(false);
  });
});
