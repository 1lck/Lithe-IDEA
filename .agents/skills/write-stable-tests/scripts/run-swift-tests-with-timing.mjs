#!/usr/bin/env node

import { mkdirSync, writeFileSync, createWriteStream } from "node:fs";
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
    suiteTimeoutMs: 600000,
    report: path.join(REPOSITORY_ROOT, ".artifacts/test-stability/macos-swift.json"),
    command: arguments_[separator + 1],
    commandArguments: arguments_.slice(separator + 2),
  };
  for (let index = 0; index < separator; index += 1) {
    const argument = arguments_[index];
    if (argument === "--warn-ms") options.warnMs = positiveInteger(arguments_[++index], "--warn-ms");
    else if (argument === "--max-ms") options.maxMs = positiveInteger(arguments_[++index], "--max-ms");
    else if (argument === "--suite-timeout-ms") {
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
  let timedOutTest = null;
  let testTimer = null;
  let terminateChild = () => {};

  const recordLine = (line, stream) => {
    log.write(`${stream}: ${line}\n`);
    const suiteEvent = parseSwiftSuiteLine(line);
    if (suiteEvent?.event === "started") currentSuite = suiteEvent.name;
    else if (suiteEvent && suiteEvent.name === currentSuite) currentSuite = null;
    const event = parseSwiftTimingLine(line);
    if (!event) return;
    if (event.event === "started") {
      const startedAt = performance.now();
      active.set(event.name, { startedAt, suite: currentSuite });
      if (testTimer) clearTimeout(testTimer);
      testTimer = setTimeout(() => {
        timedOutTest = { name: event.name, suite: currentSuite };
        terminateChild();
      }, options.maxMs);
      return;
    }

    const activeTest = active.get(event.name);
    active.delete(event.name);
    if (testTimer) {
      clearTimeout(testTimer);
      testTimer = null;
    }
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
  const childPromise = runProcessImpl({
    command: options.command,
    args: options.commandArguments,
    cwd: REPOSITORY_ROOT,
    timeoutMs: options.suiteTimeoutMs,
    onSpawn: ({ terminate }) => {
      terminateChild = terminate;
    },
    onStdoutLine: (line) => recordLine(line, "stdout"),
    onStderrLine: (line) => recordLine(line, "stderr"),
    streamStdout: true,
    streamStderr: true,
  });

  const result = await childPromise;
  if (testTimer) clearTimeout(testTimer);
  await new Promise((resolve, reject) => {
    log.once("error", reject);
    log.end(resolve);
  });

  if (timedOutTest && !records.some((record) => record.name === timedOutTest.name)) {
    records.push({
      name: timedOutTest.name,
      ...(timedOutTest.suite ? { suite: timedOutTest.suite } : {}),
      status: "timeout",
      durationMs: options.maxMs,
    });
  }
  for (const [name, activeTest] of active) {
    if (!records.some((record) => record.name === name)) {
      records.push({
        name,
        ...(activeTest.suite ? { suite: activeTest.suite } : {}),
        status: result.timedOut ? "timeout" : "incomplete",
        durationMs: options.maxMs,
      });
    }
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
    suiteTimeoutMs: options.suiteTimeoutMs,
    process: {
      exitCode: result.code,
      signal: result.signal,
      timedOut: result.timedOut,
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

  if (timedOutTest) {
    throw new Error(`Swift test exceeded ${options.maxMs}ms: ${timedOutTest.name}`);
  }
  if (result.timedOut) throw new Error(`Swift test suite exceeded ${options.suiteTimeoutMs}ms.`);
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
