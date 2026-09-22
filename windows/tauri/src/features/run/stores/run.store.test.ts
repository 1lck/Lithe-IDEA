import { describe, expect, test } from "bun:test";

const { createRunStore } = await import("./run.store");
const { PRIMARY_SESSION_ID } = await import("../types/run.types");

describe("run output session lifecycle", () => {
  test("stop flushes a held prefix that never received a newline", async () => {
    // Keep this test independent of module-mock ordering in other files.
    const store = createRunStore("test-workspace", { stopRunProcess: async () => {} });
    store.getState().actions.appendOutput(PRIMARY_SESSION_ID, "\u001b[32m");
    expect(store.getState().primaryOutput).toBe("");
    await store.getState().actions.stop(PRIMARY_SESSION_ID);
    expect(store.getState().primaryOutput).toBe("\u001b[32m");
    expect(store.getState().primaryRunning).toBe(false);
  });
});
