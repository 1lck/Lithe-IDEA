import { expect, test } from "bun:test";
import type { GitExecutionEvent } from "@/platform/git-execution-events";
import { updateGitFetchProgress, type GitFetchProgress } from "./git-fetch-progress";

const start = (operationId = "fetch-a", root = "C:/repo-a"): GitExecutionEvent => ({
  type: "requestStarted",
  action: "git_fetch",
  operationId,
  workingDirectory: root,
});
const transfer = (invocationId: number, percent: number): GitExecutionEvent => ({
  type: "output",
  operationId: "fetch-a",
  invocationId,
  progressDetails: { stage: "receiving", percent },
});

test("Fetch is visible throughout preflight, authentication and remote transitions", () => {
  let fetches = updateGitFetchProgress([], start());
  expect(fetches).toEqual([{ operationId: "fetch-a", root: "C:/repo-a" }]);
  fetches = updateGitFetchProgress(fetches, {
    type: "started",
    operationId: "fetch-a",
    invocationId: 1,
  });
  fetches = updateGitFetchProgress(fetches, transfer(1, 100));
  expect(fetches[0]?.phase?.percent).toBe(100);
  fetches = updateGitFetchProgress(fetches, {
    type: "finished",
    operationId: "fetch-a",
    invocationId: 1,
    exitCode: 0,
  });
  expect(fetches).toHaveLength(1);
  expect(fetches[0]?.phase).toBeUndefined();
  fetches = updateGitFetchProgress(fetches, {
    type: "started",
    operationId: "fetch-a",
    invocationId: 2,
  });
  fetches = updateGitFetchProgress(fetches, transfer(2, 35));
  fetches = updateGitFetchProgress(fetches, { type: "authentication", operationId: "fetch-a" });
  expect(fetches[0]?.phase).toBeUndefined();
  expect(
    updateGitFetchProgress(fetches, { type: "requestFinished", operationId: "fetch-a" }),
  ).toEqual([]);
});

test("Progress ignores unrelated queries and late output from a previous invocation", () => {
  const empty: GitFetchProgress[] = [];
  expect(updateGitFetchProgress(empty, { ...start(), action: "git.fetchPlan" })).toBe(empty);
  let fetches = updateGitFetchProgress(empty, start());
  expect(updateGitFetchProgress(fetches, start())).toBe(fetches);
  fetches = updateGitFetchProgress(fetches, {
    type: "started",
    operationId: "fetch-a",
    invocationId: 2,
  });
  fetches = updateGitFetchProgress(fetches, transfer(2, 20));
  expect(updateGitFetchProgress(fetches, transfer(1, 100))).toBe(fetches);
  expect(
    updateGitFetchProgress(fetches, { type: "finished", operationId: "fetch-a", invocationId: 1 }),
  ).toBe(fetches);
  expect(updateGitFetchProgress(fetches, { type: "requestFinished", operationId: "other" })).toBe(
    fetches,
  );
});

test("Concurrent repositories finish independently and late completion cannot clear a successor", () => {
  let fetches = updateGitFetchProgress([], start());
  fetches = updateGitFetchProgress(fetches, start("fetch-b", "C:/repo-b"));
  fetches = updateGitFetchProgress(fetches, { type: "requestFinished", operationId: "fetch-a" });
  expect(fetches).toEqual([{ operationId: "fetch-b", root: "C:/repo-b" }]);
  expect(updateGitFetchProgress(fetches, transfer(1, 50))).toBe(fetches);
  expect(updateGitFetchProgress(fetches, { type: "requestFinished", operationId: "fetch-a" })).toBe(
    fetches,
  );
});

test.each(["offline", "cancelled", "preflight failed"])(
  "%s removes the indicator at request completion",
  (message) => {
    const fetches = updateGitFetchProgress([], start());
    expect(
      updateGitFetchProgress(fetches, {
        type: "requestFinished",
        operationId: "fetch-a",
        error: { message },
      }),
    ).toEqual([]);
  },
);

for (const [input, expected] of [
  [120, 100],
  [-1, 0],
  [Number.NaN, null],
  [Number.POSITIVE_INFINITY, null],
] as const) {
  test(`Invalid percentage ${input} is normalized to ${expected}`, () => {
    let fetches = updateGitFetchProgress([], start());
    fetches = updateGitFetchProgress(fetches, {
      type: "started",
      operationId: "fetch-a",
      invocationId: 1,
    });
    expect(updateGitFetchProgress(fetches, transfer(1, input))[0]?.phase?.percent).toBe(expected);
  });
}
