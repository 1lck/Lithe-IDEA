#!/usr/bin/env node

import { mkdirSync, writeFileSync, createWriteStream } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { writeTestReportArtifacts } from "./generate-test-report.mjs";
import { positiveInteger, runProcess } from "./test-timing-lib.mjs";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");

export function parseSwiftTimingLine(line) {
  const plain = line.replace(/\u001B\[[0-9;]*m/g, "");
  const swiftStart = plain.match(/(?:^|\s)Test (?!run\b|case\b)(.+?) started\.$/);
  if (swiftStart) {
    return {
      name: swiftStart[1],
      event: "started",
      durationMs: null,
      caseCount: null,
    };
  }
  const swiftFinish = plain.match(
    /(?:^|\s)Test (?!run\b|case\b)(.+?)(?: with (\d+) test cases)? (passed|failed|skipped) after ([0-9.]+) seconds\.$/,
  );
  if (swiftFinish) {
    return {
      name: swiftFinish[1],
      event: swiftFinish[3],
      durationMs: Number(swiftFinish[4]) * 1000,
      caseCount: swiftFinish[2] ? Number(swiftFinish[2]) : null,
    };
  }
  const xctestStart = plain.match(/^Test Case '(.+)' started\.$/);
  if (xctestStart) {
    return { name: xctestStart[1], event: "started", durationMs: null, caseCount: null };
  }
  const xctestFinish = plain.match(/^Test Case '(.+)' (passed|failed) \(([0-9.]+) seconds\)\.$/);
  if (xctestFinish) {
    return {
      name: xctestFinish[1],
      event: xctestFinish[2],
      durationMs: Number(xctestFinish[3]) * 1000,
      caseCount: null,
    };
  }
  return null;
}

export function parseSwiftSuiteLine(line) {
  const plain = line.replace(/\u001B\[[0-9;]*m/g, "");
  const event = plain.match(/(?:^|\s)Suite (.+?) (started|passed|failed|skipped)(?: after [0-9.]+ seconds)?\.$/);
  if (!event) return null;
  return {
    name: event[1].replace(/^(["'])(.*)\1$/, "$2"),
    event: event[2],
  };
}

function parseArguments(arguments_) {
  const separator = arguments_.indexOf("--");
  if (separator < 0 || separator === arguments_.length - 1) {
    throw new Error("Provide the test command after --.");
  }
  const options = {
    warnMs: 1000,
    maxMs: 15000,
    stallTimeoutMs: 120000,
    suiteTimeoutMs: 600000,
    report: path.join(REPOSITORY_ROOT, ".artifacts/test-stability/macos-swift.json"),
    command: arguments_[separator + 1],
    commandArguments: arguments_.slice(separator + 2),
  };
  for (let index = 0; index < separator; index += 1) {
    const argument = arguments_[index];
    if (argument === "--warn-ms") options.warnMs = positiveInteger(arguments_[++index], "--warn-ms");
    else if (argument === "--max-ms") options.maxMs = positiveInteger(arguments_[++index], "--max-ms");
    else if (argument === "--stall-timeout-ms") {
      options.stallTimeoutMs = positiveInteger(arguments_[++index], "--stall-timeout-ms");
    } else if (argument === "--suite-timeout-ms") {
      options.suiteTimeoutMs = positiveInteger(arguments_[++index], "--suite-timeout-ms");
    } else if (argument === "--report") options.report = path.resolve(arguments_[++index]);
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (options.warnMs >= options.maxMs) throw new Error("--warn-ms must be lower than --max-ms.");
  return options;
}

export async function run(options, { runProcessImpl = runProcess } = {}) {
  mkdirSync(path.dirname(options.report), { recursive: true });
  const logPath = options.report.replace(/\.json$/i, ".log");
  const log = createWriteStream(logPath, { flags: "w" });
  const active = new Map();
  const records = [];
  let currentSuite = null;
  let stalled = false;
  let stallTimer = null;
  let terminateChild = () => {};
  let childPid = null;
  let lastOutputAt = null;
  let lastTestEventAt = null;
  let stallSamplePath = null;
  // Killing the runner from a per-test timer is unsound: swift test writes to a
  // block-buffered pipe, so a finish line can sit (or be split mid-line) in the
  // child's buffer long after the test completed, and the timer would blame an
  // innocent test. Instead, per-test budgets are enforced after the run from
  // the durations swift-testing itself reports, and this stall watchdog only
  // guards against the runner producing no output at all.
  const stallTimeoutMs = options.stallTimeoutMs ?? 120000;
  // Best-effort thread-stack snapshot of the hung runner, taken before the
  // SIGTERM destroys the evidence of where it was stuck.
  const captureStallSample = () => {
    if (process.platform !== "darwin" || !childPid) return;
    const samplePath = options.report.replace(/\.json$/i, ".stall-sample.txt");
    try {
      const sample = spawnSync("sample", [String(childPid), "2", "-file", samplePath], {
        stdio: "ignore",
        timeout: 15000,
      });
      if (sample.status === 0) stallSamplePath = samplePath;
    } catch {
      // Sampling is diagnostics only; never let it break termination.
    }
  };
  const armStallTimer = () => {
    if (stallTimer) clearTimeout(stallTimer);
    stallTimer = setTimeout(() => {
      stalled = true;
      captureStallSample();
      terminateChild();
    }, stallTimeoutMs);
  };

  const recordLine = (line, stream) => {
    lastOutputAt = new Date().toISOString();
    log.write(`${lastOutputAt} ${stream}: ${line}\n`);
    armStallTimer();
    const suiteEvent = parseSwiftSuiteLine(line);
    if (suiteEvent?.event === "started") currentSuite = suiteEvent.name;
    else if (suiteEvent && suiteEvent.name === currentSuite) currentSuite = null;
    const event = parseSwiftTimingLine(line);
    if (!event) return;
    lastTestEventAt = lastOutputAt;
    if (event.event === "started") {
      active.set(event.name, { startedAt: performance.now(), suite: currentSuite });
      return;
    }

    const activeTest = active.get(event.name);
    active.delete(event.name);
    records.push({
      name: event.name,
      ...(activeTest?.suite ? { suite: activeTest.suite } : {}),
      status: event.event,
      durationMs: Math.round(
        event.durationMs ?? (activeTest ? performance.now() - activeTest.startedAt : 0),
      ),
      ...(event.caseCount ? { caseCount: event.caseCount } : {}),
    });
  };

  const startedAt = new Date().toISOString();
  armStallTimer();
  const childPromise = runProcessImpl({
    command: options.command,
    args: options.commandArguments,
    cwd: REPOSITORY_ROOT,
    timeoutMs: options.suiteTimeoutMs,
    onSpawn: ({ pid, terminate }) => {
      childPid = pid ?? null;
      terminateChild = terminate;
    },
    onStdoutLine: (line) => recordLine(line, "stdout"),
    onStderrLine: (line) => recordLine(line, "stderr"),
    streamStdout: true,
    streamStderr: true,
  });

  // Clear the watchdog and settle the log stream even when spawn fails and the
  // await throws; a leaked ref'd timer would keep this process alive for the
  // full timeout, and an unsettled stream emits an unhandled error event.
  let result;
  let logError = null;
  try {
    result = await childPromise;
  } finally {
    if (stallTimer) clearTimeout(stallTimer);
    stallTimer = null;
    await new Promise((resolve) => {
      log.once("error", (error) => {
        logError ??= error;
        resolve();
      });
      log.end(resolve);
    });
  }
  if (logError) throw logError;

  // Tests still in `active` either never finished or had their finish line cut
  // off in the killed child's stdio buffer; report them without asserting that
  // any single one of them is the culprit.
  const unfinished = [...active.entries()];
  for (const [name, activeTest] of unfinished) {
    if (!records.some((record) => record.name === name)) {
      records.push({
        name,
        ...(activeTest.suite ? { suite: activeTest.suite } : {}),
        status: result.timedOut || stalled ? "timeout" : "incomplete",
        durationMs: Math.round(performance.now() - activeTest.startedAt),
      });
    }
  }
  if (stalled) {
    const unfinishedNames = unfinished.map(([name]) => name);
    records.push({
      name: "Swift test runner stall",
      suite: "Swift test runner",
      status: "timeout",
      durationMs: stallTimeoutMs,
      details:
        `The Swift runner produced no output for ${stallTimeoutMs}ms. ` +
        (unfinishedNames.length > 0
          ? `Tests without a reported result: ${unfinishedNames.join(", ")}. `
          : "Every parsed test had reported a result; the runner likely hung during teardown or exit. ") +
        `Last output at ${lastOutputAt ?? "never"}; last parsed test event at ${lastTestEventAt ?? "never"}.` +
        (stallSamplePath ? ` Thread-stack sample of the hung runner: ${stallSamplePath}.` : ""),
    });
  }
  if (result.timedOut && !records.some((record) => record.status === "timeout")) {
    records.push({
      name: "Swift test suite timeout",
      suite: "Swift test runner",
      status: "timeout",
      durationMs: options.suiteTimeoutMs,
      details: `Swift test suite exceeded the shared ${options.suiteTimeoutMs}ms deadline before reporting a test duration.`,
    });
  }

  const slow = records.filter((record) => record.durationMs >= options.warnMs);
  const overBudget = records.filter(
    (record) => record.durationMs >= options.maxMs || ["timeout", "incomplete"].includes(record.status),
  );
  const report = {
    schemaVersion: 1,
    runner: "swift",
    startedAt,
    command: [options.command, ...options.commandArguments],
    warnMs: options.warnMs,
    maxMs: options.maxMs,
    stallTimeoutMs,
    suiteTimeoutMs: options.suiteTimeoutMs,
    process: {
      exitCode: result.code,
      signal: result.signal,
      timedOut: result.timedOut,
      stalled,
      terminationConfirmed: result.terminationConfirmed,
      durationMs: Math.round(result.durationMs),
    },
    tests: records,
  };
  writeFileSync(options.report, `${JSON.stringify(report, null, 2)}\n`);
  writeTestReportArtifacts(options.report);

  console.log(`\nRecorded ${records.length} Swift test duration(s) in ${options.report}`);
  for (const record of [...slow].sort((left, right) => right.durationMs - left.durationMs).slice(0, 10)) {
    console.log(`SLOW ${record.durationMs}ms ${record.name}`);
  }

  if (result.timedOut) throw new Error(`Swift test suite exceeded ${options.suiteTimeoutMs}ms.`);
  if (stalled) {
    const unfinishedNames = unfinished.map(([name]) => name);
    throw new Error(
      `Swift test runner produced no output for ${stallTimeoutMs}ms` +
        (unfinishedNames.length > 0
          ? `; tests without a reported result: ${unfinishedNames.join(", ")}.`
          : "; every parsed test had reported a result, so the runner likely hung during teardown or exit."),
    );
  }
  if (records.length === 0) throw new Error("The Swift runner did not report any individual test durations.");
  if (overBudget.length > 0) throw new Error(`${overBudget.length} Swift test(s) exceeded the local budget.`);
  if (result.code !== 0) throw new Error(`Swift test command exited with code ${result.code}.`);
}

async function main() {
  try {
    await run(parseArguments(process.argv.slice(2)));
  } catch (error) {
    console.error(`Test timing failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) await main();
