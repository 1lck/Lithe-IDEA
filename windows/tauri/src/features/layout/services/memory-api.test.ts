import { describe, expect, mock, test } from "bun:test";
import { ApplicationMemoryPoller, type ApplicationMemoryUsage } from "./memory-api";

const SAMPLE: ApplicationMemoryUsage = {
  litheBytes: 10,
  totalBytes: 30,
};

describe("application memory polling", () => {
  test("publishes nothing until the first successful sample", async () => {
    const consume = mock(() => {});
    let attempt = 0;
    const poller = new ApplicationMemoryPoller(
      consume,
      async () => {
        attempt += 1;
        if (attempt === 1) throw new Error("snapshot failed");
        return SAMPLE;
      },
    );

    poller.start();
    await poller.poll();
    expect(consume).not.toHaveBeenCalled();

    await poller.poll();
    expect(consume).toHaveBeenCalledWith(SAMPLE);
  });

  test("keeps the last successful sample when a later poll fails", async () => {
    const consume = mock(() => {});
    let attempt = 0;
    const poller = new ApplicationMemoryPoller(
      consume,
      async () => {
        attempt += 1;
        if (attempt === 1) return SAMPLE;
        throw new Error("snapshot failed");
      },
    );

    poller.start();
    await poller.poll();
    await poller.poll();

    expect(consume).toHaveBeenCalledTimes(1);
    expect(consume).toHaveBeenCalledWith(SAMPLE);
  });

  test("does not publish a sample after polling stops", async () => {
    const consume = mock(() => {});
    let resolveSample: ((usage: ApplicationMemoryUsage) => void) | undefined;
    const poller = new ApplicationMemoryPoller(
      consume,
      () =>
        new Promise((resolve) => {
          resolveSample = resolve;
        }),
    );

    poller.start();
    const pendingPoll = poller.poll();
    poller.stop();
    resolveSample?.(SAMPLE);
    await pendingPoll;

    expect(consume).not.toHaveBeenCalled();
  });
});
