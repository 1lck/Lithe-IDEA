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

test("cancellable preparation is revoked before stop waits and failed-start cleanup can be retried", async () => {
  const owner = new ExtensionProcessOwner(); let reject!: (error: unknown) => void, stopFails = true, cancellations = 0, stops = 0;
  const preparation = new Promise<void>((_resolve, failed) => { reject = failed; });
  const starting = owner.start("provider", "workspace", "declarative:sample", () => preparation,
    async () => { stops++; if (stopFails) throw new Error("native stop failed"); },
    { cancel: () => { cancellations++; reject(new Error("revoked")); }, stopOnFailedStart: true }).catch(() => "cancelled");
  try {
    await expect(owner.stop(undefined, "declarative:sample")).rejects.toThrow("native stop failed");
    expect(await starting).toBe("cancelled"); expect(cancellations).toBe(1); expect(stops).toBe(1);
    stopFails = false; await owner.stop(undefined, "declarative:sample"); expect(stops).toBe(2);
  } finally { stopFails = false; reject(new Error("released")); await starting; await owner.stop(); }
}, 5000);

test("a failed stop waits for the other owned cleanup before reporting and cannot delete a replacement", async () => {
  const owner = new ExtensionProcessOwner(); let release!: () => void, entered!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; }), cleaning = new Promise<void>(resolve => { entered = resolve; });
  let returned = false, fail = true, replacementStops = 0;
  await owner.start("failing", "workspace", "sample", async () => {}, async () => { if (fail) throw new Error("failed"); });
  await owner.start("old", "workspace", "sample", async () => {}, async () => { entered(); await gate; });
  const stopping = owner.stop().catch(error => { returned = true; return error.message; });
  try {
    await cleaning; expect(returned).toBe(false);
    await owner.start("old", "workspace", "replacement", async () => {}, async () => { replacementStops++; });
    release(); expect(await stopping).toBe("failed"); fail = false;
    await owner.stop(); expect(replacementStops).toBe(1);
  } finally { release(); fail = false; await stopping; await owner.stop(); }
}, 5000);
