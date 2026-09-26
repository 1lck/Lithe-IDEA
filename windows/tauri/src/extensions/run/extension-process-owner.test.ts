import { expect, test } from "bun:test";
import { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";

test("disable waits for an in-flight start and stops the late process", async () => {
  const owner = new ExtensionProcessOwner();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let stops = 0;
  const start = owner.start(
    "run",
    "workspace",
    "sample.plugin",
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
  const owner = new ExtensionProcessOwner();
  const stopped: string[] = [];
  for (const id of ["a", "b", "finished"]) {
    await owner.start(
      id,
      id,
      "sample.plugin",
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

test("disabling one extension preserves another extension in the same workspace", async () => {
  const owner = new ExtensionProcessOwner();
  const stopped: string[] = [];
  for (const id of ["one", "two"])
    await owner.start(
      id,
      "same-workspace",
      id,
      async () => {},
      async () => {
        stopped.push(id);
      },
    );
  try {
    await owner.stop(undefined, "one");
    expect(stopped).toEqual(["one"]);
  } finally {
    await owner.stop();
  }
  expect(stopped).toEqual(["one", "two"]);
});
