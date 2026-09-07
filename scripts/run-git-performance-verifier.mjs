#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runProcess } from "../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "..");

function parseArguments(arguments_) {
  const separator = arguments_.indexOf("--");
  if (separator < 0 || separator === arguments_.length - 1) {
    throw new Error("Provide the verifier command after --.");
  }
  const options = {
    benchmark: path.join(REPOSITORY_ROOT, ".artifacts/performance/git-graph-baseline.json"),
    report: path.join(REPOSITORY_ROOT, ".artifacts/test-stability/macos-git-performance-release.json"),
    log: path.join(REPOSITORY_ROOT, ".artifacts/test-stability/macos-git-performance-release.log"),
    timeoutMs: 300_000,
    command: arguments_[separator + 1],
    commandArguments: arguments_.slice(separator + 2),
  };
  for (let index = 0; index < separator; index += 1) {
    const argument = arguments_[index];
    if (argument === "--benchmark") options.benchmark = path.resolve(arguments_[++index]);
    else if (argument === "--report") options.report = path.resolve(arguments_[++index]);
    else if (argument === "--log") options.log = path.resolve(arguments_[++index]);
    else if (argument === "--timeout-seconds") options.timeoutMs = Number(arguments_[++index]) * 1000;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs <= 0) {
    throw new Error("--timeout-seconds must be a positive integer.");
  }
  return options;
}

function writeReport(options, tests) {
  mkdirSync(path.dirname(options.report), { recursive: true });
  writeFileSync(options.report, JSON.stringify({
    schemaVersion: 1,
    runner: "swift",
    startedAt: new Date().toISOString(),
    command: [options.command, ...options.commandArguments],
    warnMs: 1000,
    maxMs: 60000,
    tests,
  }, null, 2) + "\n");
}

function writeFailureReport(options, status, details, durationMs) {
  writeReport(options, [{
    name: "Git graph Release verifier",
    suite: "Git graph Release baseline",
    status,
    durationMs: Math.round(durationMs),
    details,
  }]);
}

function writeSuccessReport(options, benchmark, durationMs) {
  const scenarios = Array.isArray(benchmark.scenarios) ? benchmark.scenarios : [];
  const expectedCommitCounts = [1_000, 5_000];
  if (
    benchmark.schemaVersion !== 1
    || benchmark.benchmark !== "git-graph-layout"
    || benchmark.configuration !== "release"
    || benchmark.warmupCount !== 3
    || benchmark.sampleCount !== 21
    || scenarios.length !== expectedCommitCounts.length
  ) {
    throw new Error("benchmark does not contain Git graph scenarios");
  }
  for (const [index, scenario] of scenarios.entries()) {
    const samples = Array.isArray(scenario.samplesMs) ? scenario.samplesMs : [];
    const timings = [scenario.medianMs, scenario.p95Ms, scenario.minimumMs, scenario.maximumMs, ...samples];
    if (
      scenario.commitCount !== expectedCommitCounts[index]
      || samples.length !== benchmark.sampleCount
      || timings.some((value) => !Number.isFinite(value) || value < 0)
      || !/^0x[0-9a-f]{16}$/.test(scenario.signature)
      || !Number.isInteger(scenario.structureBaseline?.maximumLaneCount)
      || scenario.renderBenchmark?.rowCount !== scenario.commitCount
      || scenario.renderBenchmark?.legacyCanvasInstances !== scenario.commitCount
      || scenario.renderBenchmark?.nativeViewInstances !== 1
      || scenario.renderBenchmark?.legacyViewportDrawCalls !== Math.min(40, scenario.commitCount)
      || scenario.renderBenchmark?.nativeViewportDrawCalls !== 1
    ) {
      throw new Error(`benchmark scenario ${index} is incomplete or invalid`);
    }
  }
  writeReport(options, scenarios.map((scenario) => ({
    name: `merge-heavy-${scenario.commitCount}`,
    suite: "Git graph Release baseline",
    status: "passed",
    durationMs: Number(scenario.medianMs),
    details: `median=${Number(scenario.medianMs).toFixed(3)}ms, p95=${Number(scenario.p95Ms).toFixed(3)}ms, renderInstances=${scenario.renderBenchmark.legacyCanvasInstances}->${scenario.renderBenchmark.nativeViewInstances}, viewportDrawCalls=${scenario.renderBenchmark.legacyViewportDrawCalls}->${scenario.renderBenchmark.nativeViewportDrawCalls}, samples=${benchmark.sampleCount}, warmups=${benchmark.warmupCount}, lanes=${scenario.structureBaseline.maximumLaneCount}, signature=${scenario.signature}, verifier=${Math.round(durationMs)}ms`,
  })));
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const previousBenchmark = existsSync(options.benchmark)
    ? readFileSync(options.benchmark, "utf8")
    : null;
  let result;
  try {
    result = await runProcess({
      command: options.command,
      args: options.commandArguments,
      cwd: REPOSITORY_ROOT,
      timeoutMs: options.timeoutMs,
      streamStdout: true,
      streamStderr: true,
    });
  } catch (error) {
    writeFailureReport(options, "error", error.message, 0);
    throw error;
  }
  mkdirSync(path.dirname(options.log), { recursive: true });
  writeFileSync(options.log, `${result.stdout}${result.stderr}`);

  if (result.timedOut) {
    writeFailureReport(options, "timeout", `Release verifier exceeded local ${options.timeoutMs / 1000}s deadline; process cleanup confirmed=${result.terminationConfirmed}`, result.durationMs);
    process.exitCode = 1;
  } else if (result.code !== 0) {
    writeFailureReport(options, "failed", `Release verifier exited with code ${result.code ?? "null"}${result.signal ? ` (${result.signal})` : ""}`, result.durationMs);
    process.exitCode = 1;
  } else {
    try {
      const benchmarkText = readFileSync(options.benchmark, "utf8");
      if (benchmarkText === previousBenchmark) {
        throw new Error("benchmark was not refreshed");
      }
      const benchmark = JSON.parse(benchmarkText);
      writeSuccessReport(options, benchmark, result.durationMs);
    } catch (error) {
      writeFailureReport(options, "incomplete", `Release verifier exited successfully but its benchmark is unavailable: ${error.message}`, result.durationMs);
      process.exitCode = 1;
    }
  }
}

main().catch((error) => {
  console.error(`Git performance verifier runner failed: ${error.message}`);
  const arguments_ = process.argv.slice(2);
  try {
    const options = parseArguments(arguments_);
    writeFailureReport(options, "error", error.message, 0);
  } catch {
    // Argument parsing errors may prevent resolving a safe report path.
  }
  process.exitCode = 1;
});
