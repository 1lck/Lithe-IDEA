import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { parseGoTimingLine, run } from "./run-go-tests-with-timing.mjs";
import { runProcess, terminateProcessTree } from "./test-timing-lib.mjs";

function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), "lithe-go-timing-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return { warnMs: 1000, maxMs: 15000, suiteTimeoutMs: 2000,
    report: path.join(directory, "desktop-go.json"), command: "fixture", commandArguments: [] };
}
function fake(events, result = {}) {
  return async ({ onSpawn, onStdoutLine }) => {
    onSpawn({ terminate() {} });
    for (const event of events) onStdoutLine(typeof event === "string" ? event : JSON.stringify(event));
    return { code: 0, signal: null, timedOut: false, terminationConfirmed: true,
      durationMs: 12, stdout: "", stderr: "", ...result };
  };
}

test("Go timing uses reported test duration and keeps package identities", { timeout: 5000 }, async (t) => {
  const options = fixture(t);
  const events = [
    { Action: "run", Package: "one", Test: "TestExample" },
    { Action: "run", Package: "one", Test: "TestExample/nested" },
    { Action: "pass", Package: "one", Test: "TestExample/nested", Elapsed: 0.125 },
    { Action: "pass", Package: "one", Test: "TestExample", Elapsed: 0.2 },
    { Action: "run", Package: "two", Test: "TestExample" },
    { Action: "skip", Package: "two", Test: "TestExample", Elapsed: 0 },
  ];
  const report = await run(options, { runProcessImpl: fake(events) });
  assert.deepEqual(report.tests.map(({ suite, name, status, durationMs }) => [suite, name, status, durationMs]), [
    ["one", "TestExample/nested", "passed", 125], ["one", "TestExample", "passed", 200],
    ["two", "TestExample", "skipped", 0],
  ]);
  assert.match(readFileSync(options.report.replace(/\.json$/, ".junit.xml"), "utf8"), /TestExample\/nested/);
  const html = readFileSync(path.join(path.dirname(options.report), "index.html"), "utf8");
  assert.match(html, /TestExample/);
  assert.match(html, /Go 父子测试耗时重叠，不等于墙钟时间/);
});

test("Go timing fails closed on zero matches, malformed output and incomplete tests", { timeout: 5000 }, async (t) => {
  for (const events of [[], ["not-json"], [{ Action: "run", Package: "one", Test: "TestHung" }]]) {
    const options = fixture(t);
    await assert.rejects(run(options, { runProcessImpl: fake(events) }), /failed or exceeded/);
    const report = JSON.parse(readFileSync(options.report, "utf8"));
    assert.ok(report.tests.some(({ status }) => status === "error" || status === "incomplete"));
  }
});

test("Go timing reports failures, package failures and budgets without hiding them", { timeout: 5000 }, async (t) => {
  const options = fixture(t);
  const events = [
    { Action: "run", Package: "one", Test: "TestBad" },
    { Action: "output", Package: "one", Test: "TestBad", Output: "failure details\n" },
    { Action: "fail", Package: "one", Test: "TestBad", Elapsed: 0.5 },
    { Action: "fail", Package: "one" },
    { Action: "run", Package: "two", Test: "TestSlow" },
    { Action: "pass", Package: "two", Test: "TestSlow", Elapsed: 16 },
    { Action: "fail", Package: "three" },
  ];
  await assert.rejects(run(options, { runProcessImpl: fake(events, { code: 1 }) }), /failed or exceeded/);
  const report = JSON.parse(readFileSync(options.report, "utf8"));
  assert.match(report.tests.find(({ name }) => name === "TestBad").details, /failure details/);
  assert.equal(report.tests.find(({ name }) => name === "TestSlow").durationMs, 16000);
  assert.ok(report.tests.some(({ suite, name }) => suite === "three" && name === "Go package failure"));
  assert.equal(report.tests.filter(({ suite, name }) => suite === "one" && name === "Go package failure").length, 0);
});

test("Go event parser refuses non-events", { timeout: 5000 }, () => {
  assert.equal(parseGoTimingLine("{"), null);
  assert.equal(parseGoTimingLine("[]"), null);
  assert.deepEqual(parseGoTimingLine('{"Action":"run","Package":"p","Test":"T"}'), { Action: "run", Package: "p", Test: "T" });
});

test("Go timing stops a runner that exceeds its output budget", { timeout: 5000 }, async (t) => {
  const options = fixture(t);
  let stopped = false;
  const runProcessImpl = async ({ onSpawn, onOutputChunk }) => {
    onSpawn({ terminate: () => { stopped = true; } });
    onOutputChunk(Buffer.from("too much output"), "stdout");
    return { code: 1, signal: null, timedOut: false, terminationConfirmed: true,
      durationMs: 1, stdout: "", stderr: "" };
  };
  await assert.rejects(run(options, { runProcessImpl, outputLimitBytes: 4 }), /failed or exceeded/);
  assert.equal(stopped, true);
  const report = JSON.parse(readFileSync(options.report, "utf8"));
  assert.match(report.tests.at(-1).details, /outputLimit=true/);
});

test("process capture retains only the configured combined byte limit", { timeout: 5000 }, async () => {
  const result = await runProcess({ command: process.execPath,
    args: ["-e", 'process.stdout.write("x".repeat(10000)); process.stderr.write("y".repeat(10000));'],
    timeoutMs: 3000, maxCapturedBytes: 32 });
  assert.equal(result.code, 0);
  assert.equal(Buffer.byteLength(result.stdout) + Buffer.byteLength(result.stderr), 32);
});

test("Go timing terminates a stuck runner and records the unfinished test", { timeout: 10000 }, async (t) => {
  const options = fixture(t);
  options.command = process.execPath;
  // The interval deliberately keeps the fixture alive; the deadline under
  // test, not this interval, is responsible for ending the process tree.
  const pidFile = path.join(path.dirname(options.report), "fixture.pid");
  options.commandArguments = ["-e", 'require("node:fs").writeFileSync(process.argv[1], String(process.pid)); process.stdout.write(JSON.stringify({Action:"run",Package:"p",Test:"TestStuck"})+"\\n"); setInterval(()=>{},60000);', pidFile];
  options.suiteTimeoutMs = 1000;
  await assert.rejects(run(options), /failed or exceeded/);
  const report = JSON.parse(readFileSync(options.report, "utf8"));
  assert.equal(report.process.timedOut, true);
  assert.equal(report.process.terminationConfirmed, true);
  assert.ok(report.tests.some(({ name, status }) => name === "TestStuck" && status === "timeout"));
  const pid = Number(readFileSync(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), (error) => error.code === "ESRCH", "the timed-out child must have exited");
});

test("Windows process cleanup reports a failed taskkill", { timeout: 10000, skip: process.platform !== "win32" }, async (t) => {
  const child = spawn(process.execPath, ["-e", "setInterval(()=>{},60000)"]);
  await once(child, "spawn");
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill();
    if (child.exitCode === null && child.signalCode === null) await once(child, "close");
  });
  const stopped = await terminateProcessTree(child, { spawnSyncImpl: () => ({ status: 1 }) });
  assert.equal(stopped, false, "a failed taskkill cannot prove process-tree cleanup");
});

test("a failed tree cleanup does not leave the timing runner waiting forever", { timeout: 10000 }, async () => {
  for (const terminateProcessTreeImpl of [async () => false, async () => { throw new Error("fixture failure"); }]) {
    let pid;
    const result = await runProcess({
      command: process.execPath,
      args: ["-e", "setInterval(()=>{},60000)"],
      timeoutMs: 500,
      forcedTerminationTimeoutMs: 1000,
      onSpawn: (child) => { pid = child.pid; },
      terminateProcessTreeImpl,
    });
    assert.equal(result.timedOut, true);
    assert.equal(result.terminationConfirmed, false);
    assert.throws(() => process.kill(pid, 0), (error) => error.code === "ESRCH", "fallback must stop the direct child");
  }
});
