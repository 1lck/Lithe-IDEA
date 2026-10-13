#!/usr/bin/env node

import assert from "node:assert/strict";
import { watch } from "node:fs";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { downloadSparkleBaseline, runDownload } from "./download-sparkle-baseline.mjs";

const name = "Lithe-0.5.10-arm64.zip";
const success = { code: 0, stderr: "", timedOut: false };
const failure = (stderr) => ({ code: 1, stderr, timedOut: false });
const scheduleDeadline = globalThis.setTimeout;
const clearDeadline = globalThis.clearTimeout;

async function fixture(t, archive = name) {
  const archives = await mkdtemp(path.join(os.tmpdir(), "lithe-baseline-test-"));
  t.after(() => rm(archives, { recursive: true, force: true }));
  return { repository: "example/lithe", tag: "v0.5.10", name: archive, archives };
}

function downloader(outcomes, { beforeResult } = {}) {
  const calls = [];
  const waits = [];
  return {
    calls, waits,
    sleep: async (ms) => { waits.push(ms); },
    log: () => {},
    run: async (command, args, options) => {
      const staging = args.at(-1);
      assert.deepEqual(await readdir(staging), [], "Every attempt must start empty");
      const index = calls.length;
      calls.push({ command, args, options, staging });
      const result = outcomes[index];
      assert.ok(result, "No attempts beyond the supplied outcomes");
      await writeFile(path.join(staging, args[args.indexOf("--pattern") + 1]),
        result.code === 0 ? "complete archive" : "partial archive");
      await beforeResult?.(index);
      return result;
    },
  };
}

test("transient HTTP failures retry in clean staging and promote only the complete archive", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const stub = downloader([failure("HTTP 500 (GitHub asset)"), failure("HTTP 503"), success]);
  await downloadSparkleBaseline(input, stub);
  assert.equal(await readFile(path.join(input.archives, name), "utf8"), "complete archive");
  assert.deepEqual(await readdir(input.archives), [name]);
  assert.deepEqual(stub.waits, [2000, 4000]);
  assert.equal(new Set(stub.calls.map((call) => call.staging)).size, 3);
  for (const call of stub.calls) {
    assert.equal(call.command, "gh");
    assert.deepEqual(call.args.slice(0, -1), ["release", "download", "v0.5.10", "--repo", "example/lithe", "--pattern", name, "--dir"]);
    assert.equal(call.options.timeoutMs, 120_000);
  }
});

test("exhausted failures stay fatal with three attempts and no partial inputs", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const stub = downloader(Array(3).fill(failure("HTTP 500")));
  await assert.rejects(downloadSparkleBaseline(input, stub), /failed after 3 attempt\(s\): HTTP 500/);
  assert.equal(stub.calls.length, 3);
  assert.deepEqual(stub.waits, [2000, 4000]);
  assert.deepEqual(await readdir(input.archives), []);
});

for (const stderr of ["HTTP 401", "HTTP 403", "HTTP 404", "no assets match the release", "unknown failure"]) {
  test(`${stderr} fails immediately without fallback`, { timeout: 5000 }, async (t) => {
    const input = await fixture(t);
    const stub = downloader([failure(stderr)]);
    await assert.rejects(downloadSparkleBaseline(input, stub), /failed after 1 attempt/);
    assert.equal(stub.calls.length, 1);
    assert.deepEqual(stub.waits, []);
    assert.deepEqual(await readdir(input.archives), []);
  });
}

for (const result of [failure("HTTP 408"), failure("HTTP 429"), failure("read: connection reset by peer"),
  { ...failure(""), timedOut: true }]) {
  test(`${result.stderr || "attempt timeout"} can recover`, { timeout: 5000 }, async (t) => {
    const input = await fixture(t, "Lithe-preview-45.1-x86_64.zip");
    const stub = downloader([result, success]);
    await downloadSparkleBaseline(input, stub);
    assert.equal(stub.calls.length, 2);
    assert.deepEqual(await readdir(input.archives), [input.name]);
  });
}

test("timeouts are bounded even if a killed command reports exit zero", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const stub = downloader(Array(3).fill({ ...success, timedOut: true }));
  await assert.rejects(downloadSparkleBaseline(input, stub), /failed after 3 attempt\(s\): download timed out/);
  assert.deepEqual(await readdir(input.archives), []);
});

test("an empty or missing successful download fails without publishing", { timeout: 5000 }, async (t) => {
  for (const empty of [true, false]) {
    const input = await fixture(t);
    const run = async (_command, args) => {
      if (empty) await writeFile(path.join(args.at(-1), name), "");
      return success;
    };
    await assert.rejects(downloadSparkleBaseline(input, { run }), empty ? /Empty Sparkle baseline/ : /ENOENT/);
    assert.deepEqual(await readdir(input.archives), []);
  }
});

test("cancellation before promotion cleans the attempt and never retries", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const cancellation = new AbortController();
  const stub = downloader([success], { beforeResult: () => cancellation.abort(new Error("cancelled")) });
  await assert.rejects(downloadSparkleBaseline(input, { ...stub, signal: cancellation.signal }), /cancelled/);
  assert.deepEqual(stub.waits, []);
  assert.deepEqual(await readdir(input.archives), []);
});

test("cancellation during backoff never starts another attempt", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const cancellation = new AbortController();
  const stub = downloader([failure("HTTP 500")]);
  await assert.rejects(downloadSparkleBaseline(input, {
    ...stub, signal: cancellation.signal,
    sleep: async () => { cancellation.abort(new Error("cancelled during backoff")); },
  }), /cancelled during backoff/);
  assert.equal(stub.calls.length, 1);
  assert.deepEqual(await readdir(input.archives), []);
});

for (const termination of [{ terminationSignal: "SIGTERM" }, { code: 130 }, { code: 143 }]) {
test(`cancelled commands (${JSON.stringify(termination)}) are fatal even with transient stderr`, { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  const stub = downloader([{ ...failure("HTTP 500"), ...termination }]);
  await assert.rejects(downloadSparkleBaseline(input, stub), /failed after 1 attempt/);
  assert.deepEqual(stub.waits, []);
  assert.deepEqual(await readdir(input.archives), []);
});
}

test("spawn errors clean staging and never retry", { timeout: 5000 }, async (t) => {
  const input = await fixture(t);
  await assert.rejects(downloadSparkleBaseline(input, { run: async () => { throw new Error("spawn failed"); } }), /spawn failed/);
  assert.deepEqual(await readdir(input.archives), []);
});

test("unsafe archive paths are rejected before spawning", { timeout: 5000 }, async (t) => {
  const input = await fixture(t, "../baseline.zip");
  await assert.rejects(downloadSparkleBaseline(input, { run: () => assert.fail("must not spawn") }), /Invalid Sparkle baseline/);
  assert.deepEqual(await readdir(input.archives), []);
});

async function blockedDownload(t) {
  const archives = await mkdtemp(path.join(os.tmpdir(), "lithe-baseline-process-test-"));
  const readyFile = path.join(archives, "ready");
  const cancellation = new AbortController();
  let pid;
  let watcher;
  let deadline;
  // Readiness is an atomic file event, not a speed-dependent sleep. Teardown
  // can kill the fixture independently if the production cancellation regresses.
  const ready = new Promise((resolve, reject) => {
    deadline = scheduleDeadline(() => reject(new Error("Download fixture did not become ready")), 3000);
    watcher = watch(archives, async (_event, filename) => {
      if (filename !== "ready") return;
      try {
        pid = Number(await readFile(readyFile, "utf8"));
        watcher.close();
        clearDeadline(deadline);
        resolve();
      } catch (error) { reject(error); }
    });
    watcher.on("error", reject);
  });
  t.after(async () => {
    cancellation.abort(new Error("Test cleanup"));
    watcher.close();
    clearDeadline(deadline);
    if (!pid) pid = Number(await readFile(readyFile, "utf8").catch(() => "0"));
    if (pid) {
      try { process.kill(-pid, "SIGKILL"); }
      catch (error) { if (error.code !== "ESRCH") throw error; }
    }
    await rm(archives, { recursive: true, force: true });
  });
  const script = "const fs = require('node:fs'); const file = process.argv[1]; " +
    "fs.writeFileSync(file + '.tmp', String(process.pid)); fs.renameSync(file + '.tmp', file); setInterval(() => {}, 1000);";
  const result = runDownload(process.execPath, ["-e", script, readyFile],
    { timeoutMs: 120_000, signal: cancellation.signal });
  result.catch(() => {}); // The assertion consumes it after fixture readiness.
  await ready;
  return { result, cancellation };
}

test("the real subprocess deadline kills and reaps a stuck download", { timeout: 5000 }, async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { result } = await blockedDownload(t);
  t.mock.timers.tick(120_000);
  const completed = await result;
  assert.equal(completed.timedOut, true);
  assert.equal(completed.terminationSignal, "SIGKILL");
});

test("the real subprocess is stopped and reaped on cancellation", { timeout: 5000 }, async (t) => {
  const { result, cancellation } = await blockedDownload(t);
  cancellation.abort(new Error("cancelled subprocess"));
  await assert.rejects(result, /cancelled subprocess/);
});

test("stable release budgets leave room beyond compilation and bound Sparkle", { timeout: 5000 }, async () => {
  const workflow = await readFile(new URL("../.github/workflows/release-macos.yml", import.meta.url), "utf8");
  assert.match(workflow, /name: Build \$\{\{ matrix.architecture \}\} release[\s\S]*?timeout-minutes: 75/);
  assert.match(workflow, /name: Build and package the App\n\s+timeout-minutes: 35/);
  assert.match(workflow, /name: Generate signed Sparkle updates\n\s+timeout-minutes: 30/);
  const packaging = await readFile(new URL("./create-sparkle-update.sh", import.meta.url), "utf8");
  assert.match(packaging, /node scripts\/download-sparkle-baseline\.mjs "\$GITHUB_REPOSITORY" "\$tag" "\$name" "\$archives"/);
});
