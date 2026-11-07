import assert from "node:assert/strict";
import test from "node:test";
import { hashFileSet } from "./hash-file-set.mjs";

function gate() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

test("hashing bounds active streams and preserves file order across reversed completion", { timeout: 1000 }, async () => {
  const first = gate(), second = gate(), started = gate();
  let active = 0, peak = 0;
  const calls = [];
  const result = hashFileSet(["a", "b", "c", "d"], { concurrency: 2, hash: async file => {
    calls.push(file); peak = Math.max(peak, ++active);
    if (calls.length === 2) started.resolve();
    try { if (file === "a") await first.promise; else if (file === "b") await second.promise; return `hash-${file}`; }
    finally { active--; }
  } });
  try {
    await started.promise;
    assert.deepEqual(calls, ["a", "b"]);
    second.resolve();
  } finally { first.resolve(); second.resolve(); }
  assert.deepEqual(await result, ["hash-a", "hash-b", "hash-c", "hash-d"]);
  assert.equal(peak, 2);
  assert.equal(active, 0);
});

test("hash failure stops new reads and waits for every started stream before rejecting", { timeout: 1000 }, async () => {
  const fail = gate(), reading = gate(), started = gate();
  const calls = [];
  let settled = false;
  const result = hashFileSet(["bad", "held", "untouched"], { concurrency: 2, hash: async file => {
    calls.push(file);
    if (calls.length === 2) started.resolve();
    if (file === "bad") { await fail.promise; throw new Error("read failed"); }
    await reading.promise; return "held-hash";
  } });
  const observed = result.then(() => { settled = true; }, error => { settled = true; throw error; });
  // Install the rejection observer before releasing the controlled failure.
  const rejected = assert.rejects(observed, /read failed/);
  try {
    await started.promise;
    fail.resolve();
    await Promise.resolve(); await Promise.resolve();
    assert.equal(settled, false);
    assert.deepEqual(calls, ["bad", "held"]);
  } finally { fail.resolve(); reading.resolve(); }
  await rejected;
  assert.equal(settled, true);
});

test("invalid concurrency is rejected before starting a filesystem operation", async () => {
  let touched = false;
  for (const concurrency of [0, 9, Infinity, 1.5])
    await assert.rejects(hashFileSet(["file"], { concurrency, hash: async () => { touched = true; return "hash"; } }), /integer from 1 to 8/);
  assert.equal(touched, false);
  assert.deepEqual(await hashFileSet([]), []);
});
