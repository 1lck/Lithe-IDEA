import { expect, test } from "bun:test";
import { PhpProcessOwner } from "@lithe/php/process-owner";

test("disable waits for an in-flight start and stops the late process", async () => {
  const owner = new PhpProcessOwner();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let stops = 0;
  const start = owner.start(
    "run",
    "workspace",
    () => gate,
    async () => {
      stops++;
    },
  );
  const stopping = owner.stop();
  try {
    expect(stops).toBe(0);
  } finally {
    release();
    await Promise.all([start, stopping]);
  }
  expect(stops).toBe(1);
});

test("closing one workspace preserves other plugin sessions and finished runs", async () => {
  const owner = new PhpProcessOwner();
  const stopped: string[] = [];
  for (const id of ["a", "b", "finished"]) {
    await owner.start(
      id,
      id,
      async () => {},
      async () => {
        stopped.push(id);
      },
    );
  }
  owner.finished("finished");
  try {
    await owner.stop("a");
    expect(stopped).toEqual(["a"]);
  } finally {
    await owner.stop();
  }
  expect(stopped).toEqual(["a", "b"]);
});
