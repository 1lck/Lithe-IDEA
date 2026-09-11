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
