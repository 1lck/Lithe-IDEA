#!/usr/bin/env node

import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { writeTestReportArtifacts } from "./generate-test-report.mjs";
import { positiveInteger, runProcess } from "./test-timing-lib.mjs";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");

function parseArguments(arguments_) {
  const options = {
    manifest: null,
    package: null,
    warnMs: 1000,
    maxMs: 15000,
    buildTimeoutMs: 1200000,
    report: null,
    keepGoing: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--manifest") options.manifest = arguments_[++index];
    else if (argument === "--package") options.package = arguments_[++index];
    else if (argument === "--warn-ms") options.warnMs = positiveInteger(arguments_[++index], "--warn-ms");
    else if (argument === "--max-ms") options.maxMs = positiveInteger(arguments_[++index], "--max-ms");
    else if (argument === "--build-timeout-ms") {
      options.buildTimeoutMs = positiveInteger(arguments_[++index], "--build-timeout-ms");
    } else if (argument === "--report") options.report = path.resolve(arguments_[++index]);
    else if (argument === "--keep-going") options.keepGoing = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (!options.manifest) throw new Error("--manifest is required.");
  options.manifest = path.resolve(REPOSITORY_ROOT, options.manifest);
  options.report ??= path.join(REPOSITORY_ROOT, ".artifacts/test-stability/rust-tests.json");
  if (options.warnMs >= options.maxMs) throw new Error("--warn-ms must be lower than --max-ms.");
  return options;
}

function artifactFromLine(line) {
  try {
    const value = JSON.parse(line);
    if (value.reason !== "compiler-artifact" || !value.profile?.test || !value.executable) return null;
    return {
      executable: value.executable,
      manifestPath: value.manifest_path,
      target: value.target?.name ?? path.basename(value.executable),
    };
  } catch {
    return null;
  }
}

export async function run(options) {
  mkdirSync(path.dirname(options.report), { recursive: true });
  const logPath = options.report.replace(/\.json$/i, ".log");
  writeFileSync(logPath, "");
  const artifacts = new Map();
  const cargoArguments = [
    "test",
    "--manifest-path",
    options.manifest,
    "--no-run",
    "--message-format=json",
  ];
  if (options.package) cargoArguments.push("--package", options.package);

  console.log(`Compiling Rust tests from ${options.manifest}`);
  const build = await runProcess({
    command: "cargo",
    args: cargoArguments,
    cwd: REPOSITORY_ROOT,
    timeoutMs: options.buildTimeoutMs,
    onStdoutLine: (line) => {
      const artifact = artifactFromLine(line);
      if (artifact) artifacts.set(artifact.executable, artifact);
    },
    streamStderr: true,
  });
  appendFileSync(logPath, build.stderr);
  if (build.timedOut) throw new Error(`Cargo test compilation exceeded ${options.buildTimeoutMs}ms.`);
  if (build.code !== 0) throw new Error(`Cargo test compilation exited with code ${build.code}.`);
  if (artifacts.size === 0) throw new Error("Cargo did not produce any test executables.");

  const records = [];
  let shouldStop = false;
  for (const artifact of artifacts.values()) {
    const cwd = path.dirname(artifact.manifestPath);
    const listed = await runProcess({
      command: artifact.executable,
      args: ["--list", "--color", "never"],
      cwd,
      timeoutMs: Math.min(Math.max(options.maxMs, 5000), 10000),
    });
    if (listed.timedOut || listed.code !== 0) {
      throw new Error(
        `Could not enumerate Rust tests in ${artifact.target}.\n${listed.stdout}${listed.stderr}`,
      );
    }
    const tests = listed.stdout
      .split(/\r?\n/)
      .map((line) => line.match(/^(.*): test$/)?.[1])
      .filter(Boolean);

    for (const testName of tests) {
      console.log(`RUN  ${artifact.target}::${testName}`);
      const result = await runProcess({
        command: artifact.executable,
        args: ["--exact", testName, "--test-threads", "1", "--color", "never"],
        cwd,
        timeoutMs: options.maxMs,
      });
      const status = result.timedOut
        ? "timeout"
        : result.code === 0 && /running 0 tests/.test(result.stdout)
          ? "skipped"
          : result.code === 0
            ? "passed"
            : "failed";
      const durationMs = Math.round(result.durationMs);
      records.push({
        target: artifact.target,
        name: testName,
        status,
        durationMs,
        ...(!["passed", "skipped"].includes(status)
          ? { details: `${result.stdout}${result.stderr}`.trim().slice(0, 8000) }
          : {}),
      });
      appendFileSync(
        logPath,
        `\n=== ${artifact.target}::${testName} (${status}, ${durationMs}ms) ===\n${result.stdout}${result.stderr}`,
      );
      const statusLabel = status === "passed" ? "PASS" : status === "skipped" ? "SKIP" : "FAIL";
      console.log(`${statusLabel} ${durationMs}ms ${artifact.target}::${testName}`);
      if (!["passed", "skipped"].includes(status) && !options.keepGoing) {
        shouldStop = true;
        break;
      }
    }
    if (shouldStop) break;
  }

  const report = {
    schemaVersion: 1,
    runner: "rust",
    manifest: options.manifest,
    package: options.package,
    warnMs: options.warnMs,
    maxMs: options.maxMs,
    buildDurationMs: Math.round(build.durationMs),
    tests: records,
  };
  writeFileSync(options.report, `${JSON.stringify(report, null, 2)}\n`);
  writeTestReportArtifacts(options.report);
  console.log(`Recorded ${records.length} Rust test duration(s) in ${options.report}`);
  for (const record of records
    .filter((value) => value.durationMs >= options.warnMs)
    .sort((left, right) => right.durationMs - left.durationMs)
    .slice(0, 10)) {
    console.log(`SLOW ${record.durationMs}ms ${record.target}::${record.name}`);
  }
  if (records.length === 0) throw new Error("No Rust tests were enumerated.");
  const failures = records.filter((record) => !["passed", "skipped"].includes(record.status));
  if (failures.length > 0) throw new Error(`${failures.length} Rust test(s) failed or exceeded ${options.maxMs}ms.`);
}

async function main() {
  try {
    await run(parseArguments(process.argv.slice(2)));
  } catch (error) {
    console.error(`Rust test timing failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) await main();
