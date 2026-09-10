import { describe, expect, mock, test } from "bun:test";
import { createGitRefreshQueue } from "./git-operation-coordinator";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("Git scoped refresh coordination", () => {
  test("coalesces requests before the read starts", async () => {
    const queue = createGitRefreshQueue();
    const refresh = mock(async () => {});
    await Promise.all([
      queue.run("repo:working-tree", refresh),
      queue.run("repo:working-tree", refresh),
      queue.run("repo:working-tree", refresh),
    ]);
    expect(refresh).toHaveBeenCalledTimes(1);
  }, 1000);

  test("reads again after writes during an in-flight snapshot and publishes the final index", async () => {
    const queue = createGitRefreshQueue();
    const started = deferred();
    const release = deferred();
    let index = 0;
    let displayed = -1;
    let reads = 0;
    const refresh = async () => {
      const snapshot = index;
      if (++reads === 1) {
        started.resolve();
        await release.promise;
      }
      displayed = snapshot;
    };
    const operations = [queue.run("repo:working-tree", refresh)];
    try {
      await started.promise;
      index = 1;
      operations.push(queue.run("repo:working-tree", refresh));
      index = 2;
      operations.push(queue.run("repo:working-tree", refresh));
      release.resolve();
      await Promise.all(operations);
      expect(reads).toBe(2);
      expect(displayed).toBe(2);
    } finally {
      release.resolve();
      await Promise.allSettled(operations);
    }
  }, 1000);

  test("working-tree reads do not wait for a pending full refresh", async () => {
    const queue = createGitRefreshQueue();
    const releaseHistory = deferred();
    const full = queue.run("repo:*", () => releaseHistory.promise);
    const workingTree = mock(async () => {});
    try {
      await queue.run("repo:working-tree", workingTree);
      expect(workingTree).toHaveBeenCalledTimes(1);
    } finally {
      releaseHistory.resolve();
      await full;
    }
  }, 1000);

  test("releases a failed refresh so the next action can synchronize", async () => {
    const queue = createGitRefreshQueue();
    const failure = new Error("status unavailable");
    await expect(queue.run("repo:working-tree", async () => { throw failure; }))
      .rejects.toBe(failure);
    const refresh = mock(async () => {});
    await queue.run("repo:working-tree", refresh);
    expect(refresh).toHaveBeenCalledTimes(1);
  }, 1000);
});
