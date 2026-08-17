import { describe, expect, test } from "bun:test";
import type { GitOperationState, GitPullPreflight, PullStrategy } from "../types/git.types";
import { GitPullWorkflow, type GitPullWorkflowDependencies } from "./git-pull-workflow";

const cleanPreflight = (overrides: Partial<GitPullPreflight> = {}): GitPullPreflight => ({
  upstream: "origin/main",
  ahead: 0,
  behind: 1,
  diverged: false,
  hasLocalChanges: false,
  ...overrides,
});

const operation = (kind: GitOperationState["kind"]): GitOperationState => ({
  kind,
  reference: "origin/main",
  step: null,
  total: null,
  conflictedPaths: ["src/conflict.ts"],
});

const createHarness = (overrides: Partial<GitPullWorkflowDependencies> = {}) => {
  const pullStrategies: PullStrategy[] = [];
  let refreshCount = 0;
  const dependencies: GitPullWorkflowDependencies = {
    fetch: async () => ({ success: true }),
    preflight: async () => cleanPreflight(),
    pull: async (_repoPath, strategy) => {
      pullStrategies.push(strategy);
      return { success: true };
    },
    operationState: async () => null,
    ...overrides,
  };
  const workflow = new GitPullWorkflow(dependencies);
  const options = {
    refresh: async () => {
      refreshCount += 1;
    },
  };
  return {
    workflow,
    options,
    pullStrategies,
    refreshCount: () => refreshCount,
  };
};

const waitForStrategyDialog = async (workflow: GitPullWorkflow) => {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (workflow.getSnapshot().pendingPreflight) return;
    await Promise.resolve();
  }
  throw new Error("Strategy dialog was not requested");
};

describe("GitPullWorkflow", () => {
  test("stops when Fetch fails and still refreshes", async () => {
    let preflightCalls = 0;
    const harness = createHarness({
      fetch: async () => ({ success: false, error: "offline" }),
      preflight: async () => {
        preflightCalls += 1;
        return cleanPreflight();
      },
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toEqual({
      status: "failed",
      stage: "fetch",
      message: "Fetch failed: offline",
    });
    expect(preflightCalls).toBe(0);
    expect(harness.refreshCount()).toBe(1);
  });

  test("blocks a branch without an upstream", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ upstream: null, behind: 0 }),
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result.status).toBe("blocked");
    expect(result).toMatchObject({ reason: "no-upstream" });
    expect(harness.pullStrategies).toEqual([]);
    expect(harness.refreshCount()).toBe(1);
  });

  test("fails closed when preflight cannot inspect the branch", async () => {
    const harness = createHarness({
      preflight: async () => {
        throw new Error("Core unavailable");
      },
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toEqual({
      status: "failed",
      stage: "preflight",
      message: "Pull safety check failed: Core unavailable",
    });
    expect(harness.pullStrategies).toEqual([]);
    expect(harness.refreshCount()).toBe(1);
  });

  test("does not pull when the upstream has nothing new", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 2, behind: 0 }),
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toMatchObject({ status: "blocked", reason: "up-to-date" });
    expect(harness.pullStrategies).toEqual([]);
  });

  test("uses ffOnly when only the remote is ahead", async () => {
    const harness = createHarness();

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toMatchObject({ status: "pulled", strategy: "ffOnly" });
    expect(harness.pullStrategies).toEqual(["ffOnly"]);
  });

  test("blocks a dirty working tree before choosing or pulling", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ hasLocalChanges: true }),
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toMatchObject({ status: "blocked", reason: "dirty" });
    expect(result.message).toContain("Commit or stash");
    expect(harness.pullStrategies).toEqual([]);
  });

  test("uses Merge only after an explicit divergent-history choice", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 2, behind: 3, diverged: true }),
    });

    const resultPromise = harness.workflow.run("C:/repo", harness.options);
    await waitForStrategyDialog(harness.workflow);
    harness.workflow.chooseStrategy("merge");
    const result = await resultPromise;

    expect(result).toMatchObject({ status: "pulled", strategy: "merge" });
    expect(harness.pullStrategies).toEqual(["merge"]);
  });

  test("uses Rebase only after an explicit divergent-history choice", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 1, behind: 4, diverged: true }),
    });

    const resultPromise = harness.workflow.run("C:/repo", harness.options);
    await waitForStrategyDialog(harness.workflow);
    harness.workflow.chooseStrategy("rebase");
    const result = await resultPromise;

    expect(result).toMatchObject({ status: "pulled", strategy: "rebase" });
    expect(harness.pullStrategies).toEqual(["rebase"]);
  });

  test("blocks when the working tree becomes dirty while choosing a strategy", async () => {
    let preflightCalls = 0;
    const harness = createHarness({
      preflight: async () => {
        preflightCalls += 1;
        return cleanPreflight({
          ahead: 1,
          behind: 1,
          diverged: true,
          hasLocalChanges: preflightCalls > 1,
        });
      },
    });

    const resultPromise = harness.workflow.run("C:/repo", harness.options);
    await waitForStrategyDialog(harness.workflow);
    harness.workflow.chooseStrategy("merge");
    const result = await resultPromise;

    expect(result).toMatchObject({ status: "blocked", reason: "dirty" });
    expect(preflightCalls).toBe(2);
    expect(harness.pullStrategies).toEqual([]);
  });

  test("blocks when the upstream state changes while choosing a strategy", async () => {
    let preflightCalls = 0;
    const harness = createHarness({
      preflight: async () => {
        preflightCalls += 1;
        return cleanPreflight({
          upstream: preflightCalls === 1 ? "origin/main" : "origin/release",
          ahead: 1,
          behind: 1,
          diverged: true,
        });
      },
    });

    const resultPromise = harness.workflow.run("C:/repo", harness.options);
    await waitForStrategyDialog(harness.workflow);
    harness.workflow.chooseStrategy("rebase");
    const result = await resultPromise;

    expect(result).toMatchObject({ status: "blocked", reason: "state-changed" });
    expect(preflightCalls).toBe(2);
    expect(harness.pullStrategies).toEqual([]);
  });

  test("Cancel is the safe divergent-history default", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 1, behind: 1, diverged: true }),
    });

    const resultPromise = harness.workflow.run("C:/repo", harness.options);
    await waitForStrategyDialog(harness.workflow);
    harness.workflow.chooseStrategy(null);
    const result = await resultPromise;

    expect(result.status).toBe("cancelled");
    expect(harness.pullStrategies).toEqual([]);
    expect(harness.refreshCount()).toBe(1);
  });

  test("reports an ordinary Pull failure after confirming no operation remains", async () => {
    let operationStateCalls = 0;
    const harness = createHarness({
      pull: async () => ({ success: false, error: "authentication failed" }),
      operationState: async () => {
        operationStateCalls += 1;
        return null;
      },
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toEqual({
      status: "failed",
      stage: "pull",
      message: "Pull failed: authentication failed",
    });
    expect(operationStateCalls).toBe(1);
    expect(harness.refreshCount()).toBe(1);
  });

  test("hands a conflicted Pull to the existing operation banner", async () => {
    const mergeOperation = operation("merge");
    const harness = createHarness({
      pull: async () => ({ success: false, error: "CONFLICT" }),
      operationState: async () => mergeOperation,
    });

    const result = await harness.workflow.run("C:/repo", harness.options);

    expect(result).toEqual({
      status: "conflict",
      operation: mergeOperation,
      message: "Merge stopped for conflict resolution.",
    });
    expect(harness.refreshCount()).toBe(1);
  });

  test("ignores a duplicate click while the first Pull is running", async () => {
    let releaseFetch: ((result: { success: boolean }) => void) | undefined;
    const harness = createHarness({
      fetch: () =>
        new Promise((resolve) => {
          releaseFetch = resolve;
        }),
      preflight: async () => cleanPreflight({ behind: 0 }),
    });

    const first = harness.workflow.run("C:/repo", harness.options);
    const duplicate = await harness.workflow.run("C:/repo", harness.options);

    expect(duplicate.status).toBe("duplicate");
    releaseFetch?.({ success: true });
    await first;
    expect(harness.refreshCount()).toBe(1);
  });
});
