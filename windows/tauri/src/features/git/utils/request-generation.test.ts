import { describe, expect, test } from "bun:test";
import { createRequestGeneration } from "./request-generation";

function createDeferred<Value>() {
  let resolve!: (value: Value) => void;
  const promise = new Promise<Value>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

describe("request generation", () => {
  test("rejects a slower result after a newer request completes", async () => {
    const generation = createRequestGeneration();
    const slow = createDeferred<string>();
    const fast = createDeferred<string>();
    const accepted: string[] = [];

    const run = async (request: Promise<string>) => {
      const requestGeneration = generation.begin();
      const result = await request;
      if (generation.isCurrent(requestGeneration)) accepted.push(result);
    };

    const slowRequest = run(slow.promise);
    const fastRequest = run(fast.promise);

    fast.resolve("fast");
    await fastRequest;
    expect(accepted).toEqual(["fast"]);

    slow.resolve("slow");
    await slowRequest;
    expect(accepted).toEqual(["fast"]);
  });
});
