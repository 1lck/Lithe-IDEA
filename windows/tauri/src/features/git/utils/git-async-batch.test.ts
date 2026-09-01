import { describe, expect, test } from "bun:test";
import { mapGitReadsInBatches } from "./git-async-batch";

function createDeferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

describe("mapGitReadsInBatches", () => {
  test("bounds concurrent reads and yields between batches", async () => {
    let active = 0;
    let peak = 0;
    let yields = 0;
    const starts = Array.from({ length: 5 }, createDeferred);
    const releases = Array.from({ length: 5 }, createDeferred);
    const operation = async (value: number, index: number) => {
      active += 1;
      peak = Math.max(peak, active);
      starts[index].resolve();
      try {
        await releases[index].promise;
        return value * 2;
      } finally {
        active -= 1;
      }
    };

    const resultPromise = mapGitReadsInBatches([1, 2, 3, 4, 5], operation, {
      batchSize: 2,
      yieldControl: async () => {
        yields += 1;
      },
    });
    try {
      await Promise.all(starts.slice(0, 2).map((gate) => gate.promise));
      expect(active).toBe(2);
      releases[0].resolve();
      releases[1].resolve();

      await Promise.all(starts.slice(2, 4).map((gate) => gate.promise));
      expect(active).toBe(2);
      releases[2].resolve();
      releases[3].resolve();

      await starts[4].promise;
      expect(active).toBe(1);
      releases[4].resolve();

      await expect(resultPromise).resolves.toEqual([2, 4, 6, 8, 10]);
      expect(peak).toBe(2);
      expect(yields).toBe(2);
    } finally {
      releases.forEach((gate) => gate.resolve());
      await resultPromise.catch(() => undefined);
    }
  }, 2_000);
});
