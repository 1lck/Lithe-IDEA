import { describe, expect, test } from "bun:test";
import type {
  GitOperationState,
  GitPullPreflight,
  GitReference,
  PullStrategy,
} from "../types/git.types";
import { stubGitUpdatePlan } from "@/test-utils/git-update-plan-stub";
import { GitPullWorkflow, type GitPullWorkflowDependencies } from "./git-pull-workflow";

const remoteReference = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  peelsToCommit: true,
  isCurrent: false,
});

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

const deferred = <Value>() => {
  let resolve!: (value: Value | PromiseLike<Value>) => void;
  const promise = new Promise<Value>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
};

const createHarness = (overrides: Partial<GitPullWorkflowDependencies> = {}) => {
  const pullStrategies: PullStrategy[] = [];
  const pullReferences: Array<GitReference | undefined> = [];
  let refreshCount = 0;
  const dependencies: GitPullWorkflowDependencies = {
    fetch: async () => ({ success: true }),
    preflight: async () => cleanPreflight(),
    pull: async (_repoPath, strategy, reference) => {
      pullStrategies.push(strategy);
      pullReferences.push(reference);
      return { success: true };
    },
    operationState: async () => null,
    plan: async (input) => stubGitUpdatePlan({ stage: "inspect", ...input }),
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
    pullReferences,
    refreshCount: () => refreshCount,
  };
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
      error: "offline",
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
      error: "Core unavailable",
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
    expect(harness.pullStrategies).toEqual([]);
  });

  test("pulls a dialog-selected strategy on divergent history without prompting", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 2, behind: 3, diverged: true }),
    });

    const result = await harness.workflow.run("C:/repo", {
      ...harness.options,
      strategy: "rebase",
    });

    expect(result).toMatchObject({ status: "pulled", strategy: "rebase" });
    expect(harness.pullStrategies).toEqual(["rebase"]);
  });

  test("asks for a strategy when a fast-forward meets divergent history", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ ahead: 1, behind: 1, diverged: true }),
    });

    const result = await harness.workflow.run("C:/repo", {
      ...harness.options,
      strategy: "ffOnly",
    });

    expect(result).toEqual({ status: "needs-strategy" });
    expect(harness.pullStrategies).toEqual([]);
    expect(harness.refreshCount()).toBe(1);
  });

  test("a non-interactive update fails on divergence instead of asking", async () => {
    const harness = createHarness({ preflight: async () => cleanPreflight({ ahead: 1, behind: 1, diverged: true }) });
    const result = await harness.workflow.run("C:/worktree", {
      ...harness.options, interactive: false,
    });
    expect(result).toMatchObject({ status: "failed", stage: "pull" });
    expect(harness.pullStrategies).toEqual([]);
    expect(harness.workflow.getSnapshot()).toEqual({ isPulling: false, isPullLocked: false });
    expect(harness.refreshCount()).toBe(1);
  });

  test("Git configuration chooses the strategy when the user chose none", async () => {
    const harness = createHarness({
      preflight: async () =>
        cleanPreflight({ ahead: 1, behind: 1, diverged: true, configuredStrategy: "rebase" }),
    });

    const result = await harness.workflow.run("C:/repo", { ...harness.options, interactive: false });

    expect(result).toMatchObject({ status: "pulled", strategy: "rebase" });
    expect(harness.pullStrategies).toEqual(["rebase"]);
  });

  test("pulls a chosen remote branch into the current branch with the selected strategy", async () => {
    const reference = remoteReference("origin/release");
    const harness = createHarness({
      // The current branch has no upstream, but the dialog chose a branch, so the
      // pull is not blocked and skips the up-to-date short-circuit.
      preflight: async () => cleanPreflight({ upstream: null, ahead: 0, behind: 0 }),
    });

    const result = await harness.workflow.run("C:/repo", {
      ...harness.options,
      strategy: "merge",
      reference,
    });

    expect(result).toMatchObject({ status: "pulled", strategy: "merge" });
    expect(harness.pullStrategies).toEqual(["merge"]);
    expect(harness.pullReferences).toEqual([reference]);
  });

  test("still blocks a dirty worktree before pulling a chosen remote branch", async () => {
    const harness = createHarness({
      preflight: async () => cleanPreflight({ hasLocalChanges: true }),
    });

    const result = await harness.workflow.run("C:/repo", {
      ...harness.options,
      strategy: "merge",
      reference: remoteReference("origin/release"),
    });

    expect(result).toMatchObject({ status: "blocked", reason: "dirty" });
    expect(harness.pullStrategies).toEqual([]);
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
      error: "authentication failed",
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

  test("retains the Pull lock until a slow refresh completes", async () => {
    const pullStarted = deferred<void>();
    const releasePull = deferred<{
      success: boolean;
    }>();
    const refreshStarted = deferred<void>();
    const releaseRefresh = deferred<void>();
    const harness = createHarness({
      pull: async () => {
        pullStarted.resolve();
        return releasePull.promise;
      },
    });
    const runPromise = harness.workflow.run("C:/repo", {
      refresh: async () => {
        refreshStarted.resolve();
        await releaseRefresh.promise;
      },
    });

    try {
      await pullStarted.promise;
      releasePull.resolve({ success: true });
      await refreshStarted.promise;

      expect(harness.workflow.getSnapshot()).toEqual({
        isPulling: false,
        isPullLocked: true,
      });
      await expect(harness.workflow.run("C:/repo", harness.options)).resolves.toEqual({
        status: "duplicate",
      });
    } finally {
      // Release every deferred boundary so a failed assertion cannot leave the
      // workflow promise pending after the test has finished.
      releasePull.resolve({ success: true });
      releaseRefresh.resolve();
    }

    await expect(runPromise).resolves.toMatchObject({
      status: "pulled",
      strategy: "ffOnly",
    });
    expect(harness.workflow.getSnapshot()).toEqual({
      isPulling: false,
      isPullLocked: false,
    });
  }, 2_000);
});
