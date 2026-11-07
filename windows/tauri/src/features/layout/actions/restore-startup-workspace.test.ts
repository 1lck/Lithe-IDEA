import { expect, test } from "bun:test";
import { restoreStartupWorkspace } from "./restore-startup-workspace";

test.each([true, false])("startup clears its indicator when an already initialized switch returns %s", async (result) => {
  const indicators: boolean[] = [];
  const restored = await restoreStartupWorkspace("fixture", async (workspaceId) => {
    expect(workspaceId).toBe("fixture");
    expect(indicators).toEqual([true]);
    return result;
  }, (value) => indicators.push(value));
  expect(restored).toBe(result);
  expect(indicators).toEqual([true, false]);
});

test("startup releases its captured workspace indicator after a pending switch rejects", async () => {
  const original = { switching: false };
  const replacement = { switching: false };
  let active = original;
  const captured = active;
  let rejectSwitch!: (error: Error) => void;
  const gate = new Promise<boolean>((_resolve, reject) => { rejectSwitch = reject; });
  const failure = new Error("fixture initialization failed");
  const restored = restoreStartupWorkspace("fixture", () => gate, (value) => {
    captured.switching = value;
  });
  const observed = restored.then(() => null, (error: unknown) => error);
  try {
    expect(original.switching).toBe(true);
    active = replacement;
    rejectSwitch(failure);
    expect(await observed).toBe(failure);
    expect(original.switching).toBe(false);
    expect(active.switching).toBe(false);
  } finally {
    rejectSwitch(failure);
    await restored.catch(() => undefined);
  }
});
