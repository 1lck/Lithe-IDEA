import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { deliverGitExecution } from "@/platform/git-execution-events";
import { clearGitConsole, useGitConsoleStore } from "./git-console.store";

let flushScheduledOutput: (() => void) | undefined;
const spies: Array<{ mockRestore: () => void }> = [];
const operationId = "fetch-status-integration";

beforeEach(() => {
  spies.push(
    spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void) => {
      flushScheduledOutput = callback;
      return 1 as unknown as ReturnType<typeof setTimeout>;
    }) as typeof setTimeout),
    spyOn(globalThis, "clearTimeout").mockImplementation(() => {
      flushScheduledOutput = undefined;
    }),
  );
});

afterEach(() => {
  try {
    deliverGitExecution({ type: "requestFinished", operationId });
    clearGitConsole();
  } finally {
    flushScheduledOutput = undefined;
    for (const spy of spies.splice(0)) spy.mockRestore();
  }
});

test("Application event listener publishes Fetch immediately, batches output and removes it on completion", () => {
  deliverGitExecution({
    type: "requestStarted",
    action: "git_fetch",
    operationId,
    workingDirectory: "C:/repo",
  });
  expect(useGitConsoleStore.getState().fetches).toEqual([{ operationId, root: "C:/repo" }]);
  deliverGitExecution({
    type: "started",
    operationId,
    invocationId: 1,
    workingDirectory: "C:/repo",
    arguments: ["fetch"],
  });
  deliverGitExecution({
    type: "output",
    operationId,
    invocationId: 1,
    progress: true,
    text: "Receiving objects: 42%",
    progressDetails: { stage: "receiving", percent: 42 },
  });
  expect(useGitConsoleStore.getState().fetches[0]?.phase).toBeUndefined();
  const flush = flushScheduledOutput;
  expect(flush).toBeDefined();
  flush!();
  expect(useGitConsoleStore.getState().fetches[0]?.phase?.percent).toBe(42);
  deliverGitExecution({ type: "finished", operationId, invocationId: 1, exitCode: 0 });
  deliverGitExecution({ type: "requestFinished", operationId });
  expect(useGitConsoleStore.getState().fetches).toEqual([]);
  const records = useGitConsoleStore.getState().records;
  expect(records[records.length - 1]?.exitCode).toBe(0);
  expect(flushScheduledOutput).toBeUndefined();
});

test("Clearing Console preserves Fetch tracking until the whole request terminates", () => {
  deliverGitExecution({
    type: "requestStarted",
    action: "git_fetch",
    operationId,
    workingDirectory: "C:/repo",
  });
  clearGitConsole();
  expect(useGitConsoleStore.getState().fetches).toHaveLength(1);
  deliverGitExecution({
    type: "started",
    operationId,
    invocationId: 1,
    workingDirectory: "C:/repo",
    arguments: ["fetch"],
  });
  deliverGitExecution({
    type: "output",
    operationId,
    invocationId: 1,
    progressDetails: { stage: "receiving", percent: 35 },
  });
  flushScheduledOutput!();
  expect(useGitConsoleStore.getState().records).toEqual([]);
  expect(useGitConsoleStore.getState().fetches[0]?.phase?.percent).toBe(35);
  deliverGitExecution({ type: "requestFinished", operationId, error: { message: "cancelled" } });
  expect(useGitConsoleStore.getState().fetches).toEqual([]);
});
