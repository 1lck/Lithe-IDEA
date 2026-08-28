#!/usr/bin/env node

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { writeTestReportArtifacts } from "./generate-test-report.mjs";
import { parseJUnitCases } from "./parse-junit-cases.mjs";
import { positiveInteger, runProcess } from "./test-timing-lib.mjs";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");

function parseArguments(arguments_) {
  const separator = arguments_.indexOf("--");
  const options = {
    workingDirectory: path.join(REPOSITORY_ROOT, "windows/tauri"),
    warnMs: 1000,
    maxMs: 15000,
    suiteTimeoutMs: 600000,
    report: path.join(REPOSITORY_ROOT, ".artifacts/test-stability/windows-frontend.json"),
    testArguments: separator >= 0 ? arguments_.slice(separator + 1) : [],
  };
  const limit = separator >= 0 ? separator : arguments_.length;
  for (let index = 0; index < limit; index += 1) {
    const argument = arguments_[index];
    if (argument === "--working-directory") options.workingDirectory = path.resolve(arguments_[++index]);
    else if (argument === "--warn-ms") options.warnMs = positiveInteger(arguments_[++index], "--warn-ms");
    else if (argument === "--max-ms") options.maxMs = positiveInteger(arguments_[++index], "--max-ms");
    else if (argument === "--suite-timeout-ms") {
      options.suiteTimeoutMs = positiveInteger(arguments_[++index], "--suite-timeout-ms");
    } else if (argument === "--report") options.report = path.resolve(arguments_[++index]);
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (options.warnMs >= options.maxMs) throw new Error("--warn-ms must be lower than --max-ms.");
  return options;
}

export { parseJUnitCases } from "./parse-junit-cases.mjs";

function writeReport(options, result, tests) {
  const report = {
    schemaVersion: 1,
    runner: "bun",
    warnMs: options.warnMs,
    maxMs: options.maxMs,
    suiteTimeoutMs: options.suiteTimeoutMs,
    processDurationMs: Math.round(result.durationMs),
    tests,
  };
  writeFileSync(options.report, `${JSON.stringify(report, null, 2)}\n`);
  writeTestReportArtifacts(options.report);
}

export async function run(options, { runProcessImpl = runProcess } = {}) {
  mkdirSync(path.dirname(options.report), { recursive: true });
  const junitPath = options.report.replace(/\.json$/i, ".junit.xml");
  rmSync(junitPath, { force: true });
  const arguments_ = [
    "test",
    ...options.testArguments,
    "--timeout",
    String(options.maxMs),
    "--reporter=junit",
    `--reporter-outfile=${junitPath}`,
  ];
  const result = await runProcessImpl({
    command: "bun",
    args: arguments_,
    cwd: options.workingDirectory,
    timeoutMs: options.suiteTimeoutMs,
    streamStdout: true,
    streamStderr: true,
  });
  let tests = [];
  try {
    tests = parseJUnitCases(readFileSync(junitPath, "utf8"));
  } catch (error) {
    if (!result.timedOut) {
      throw new Error(`Bun did not produce a readable JUnit report: ${error.message}`);
    }
  }
  if (result.timedOut) {
    tests.push({
      name: "Bun test suite timeout",
      suite: "Bun test runner",
      status: "timeout",
      durationMs: options.suiteTimeoutMs,
      details: `Bun test suite exceeded the shared ${options.suiteTimeoutMs}ms deadline.`,
    });
  }
  writeReport(options, result, tests);
  console.log(`Recorded ${tests.length} Bun test duration(s) in ${options.report}`);
  for (const test of tests
    .filter((value) => value.durationMs >= options.warnMs)
    .sort((left, right) => right.durationMs - left.durationMs)
    .slice(0, 10)) {
    console.log(`SLOW ${test.durationMs}ms ${test.name}`);
  }
  if (result.timedOut) throw new Error(`Bun test suite exceeded ${options.suiteTimeoutMs}ms.`);
  if (tests.length === 0) throw new Error("The Bun runner did not report any individual test durations.");
  if (result.code !== 0) throw new Error(`Bun test command exited with code ${result.code}.`);
  const overBudget = tests.filter((test) => test.durationMs >= options.maxMs || test.status === "failed");
  if (overBudget.length > 0) throw new Error(`${overBudget.length} Bun test(s) failed or exceeded the local budget.`);
}

async function main() {
  try {
    await run(parseArguments(process.argv.slice(2)));
  } catch (error) {
    console.error(`Bun test timing failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) await main();
