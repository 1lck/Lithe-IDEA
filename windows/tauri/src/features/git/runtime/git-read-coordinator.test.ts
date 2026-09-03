import { expect, test } from "bun:test";
import { invalidateGitCaches } from "./git-cache-registry";
import { runGitRead } from "./git-read-coordinator";

test("does not replay a non-repeatable read after repository invalidation", async () => {
  const repoPath = "C:/non-repeatable-history-page";
  let resolveRead: ((value: string) => void) | undefined;
  let callCount = 0;
  const request = runGitRead(
    repoPath,
    "history-page:cursor-1",
    () => {
      callCount += 1;
      return new Promise<string>((resolve) => {
        resolveRead = resolve;
      });
    },
    { retryOnInvalidation: false },
  );

  invalidateGitCaches({ repoPath, scopes: ["history"] });
  resolveRead?.("page-2");

  expect(await request).toBe("page-2");
  expect(callCount).toBe(1);
});
