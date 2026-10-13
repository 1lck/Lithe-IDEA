import { expect, mock, test } from "bun:test";
import {
  registerDebugSessionCleanup,
  releaseDebugSessionResources,
} from "./debug-session-resources";

test("releases each debug session resource owner at most once", async () => {
  const cleanup = mock(async () => undefined);
  registerDebugSessionCleanup("session-1", cleanup);

  await releaseDebugSessionResources("session-1");
  await releaseDebugSessionResources("session-1");

  expect(cleanup).toHaveBeenCalledTimes(1);
});

test("Stop and session-ended await the same in-flight cleanup before a restart", async () => {
  let finish!: () => void;
  const gate = new Promise<void>((resolve) => {
    finish = resolve;
  });
  let completed = false;
  const cleanup = mock(() => gate);
  registerDebugSessionCleanup("overlap", cleanup);
  const first = releaseDebugSessionResources("overlap");
  const second = releaseDebugSessionResources("overlap").then(() => {
    completed = true;
  });
  try {
    await Promise.resolve();
    expect(cleanup).toHaveBeenCalledTimes(1);
    expect(completed).toBe(false);
  } finally {
    finish();
    await Promise.all([first, second]);
  }
  expect(completed).toBe(true);
});
