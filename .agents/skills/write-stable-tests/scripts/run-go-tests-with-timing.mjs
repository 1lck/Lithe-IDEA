#!/usr/bin/env node

import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { writeTestReportArtifacts } from "./generate-test-report.mjs";
import { positiveInteger, runProcess } from "./test-timing-lib.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "../../../..");
// runProcess collects stdout and stderr, so stop a broken/noisy test before its
// output consumes unbounded memory. A single diagnostic is also kept bounded.
const outputLimit = 64 * 1024 * 1024;
const diagnosticLimit = 8192;

function parseArguments(args) {
  const separator = args.indexOf("--");
  if (separator < 0 || separator === args.length - 1) throw new Error("Provide the Go test command after --.");
  const options = {
    warnMs: 1000, maxMs: 15000, suiteTimeoutMs: 600000,
    report: path.join(repositoryRoot, ".artifacts/test-stability/desktop-go.json"),
    command: args[separator + 1], commandArguments: args.slice(separator + 2),
  };
  for (let index = 0; index < separator; index += 1) {
    const argument = args[index];
    if (argument === "--warn-ms") options.warnMs = positiveInteger(args[++index], argument);
    else if (argument === "--max-ms") options.maxMs = positiveInteger(args[++index], argument);
    else if (argument === "--suite-timeout-ms") options.suiteTimeoutMs = positiveInteger(args[++index], argument);
    else if (argument === "--report" && args[index + 1]) options.report = path.resolve(args[++index]);
    else throw new Error(`Unknown or incomplete argument: ${argument}`);
  }
  if (options.warnMs >= options.maxMs) throw new Error("--warn-ms must be lower than --max-ms.");
  if (!options.report.endsWith(".json")) throw new Error("Report path must end in .json.");
  return options;
}

// Go's own elapsed seconds, not time between buffered lines, determines each
// completed test's duration. Package and test identify subtests across packages.
export function parseGoTimingLine(line) {
  let event;
  try { event = JSON.parse(line); } catch { return null; }
  if (!event || typeof event !== "object" || typeof event.Action !== "string") return null;
  return event;
}

export async function run(options, { runProcessImpl = runProcess, outputLimitBytes = outputLimit } = {}) {
  mkdirSync(path.dirname(options.report), { recursive: true });
  const startedAt = new Date().toISOString();
  const active = new Map();
  const records = [];
  const packageFailures = new Set();
  let malformed = 0;
  let outputBytes = 0;
  let overflow = false;
  let terminate = () => {};
  const keyFor = (event) => `${event.Package}\u0000${event.Test}`;
  const onLine = (line) => {
    const event = parseGoTimingLine(line);
    if (!event) { malformed += 1; return; }
    if (typeof event.Package !== "string") return;
    if (typeof event.Test !== "string") {
      if (event.Action === "fail") packageFailures.add(event.Package);
      return;
    }
    const key = keyFor(event);
    if (event.Action === "run") {
      active.set(key, { started: performance.now(), output: "" });
      return;
    }
    const running = active.get(key);
    if (event.Action === "output" && running && typeof event.Output === "string") {
      running.output = (running.output + event.Output).slice(-diagnosticLimit);
      return;
    }
    if (!["pass", "fail", "skip"].includes(event.Action)) return;
    if (!running || !Number.isFinite(event.Elapsed) || event.Elapsed < 0) {
      malformed += 1;
      return;
    }
    active.delete(key);
    records.push({
      name: event.Test, suite: event.Package,
      status: { pass: "passed", fail: "failed", skip: "skipped" }[event.Action],
      durationMs: Math.round(event.Elapsed * 1000),
      ...(event.Action === "fail" && running.output ? { details: running.output } : {}),
    });
  };

  let result;
  try {
    result = await runProcessImpl({
      command: options.command, args: options.commandArguments, cwd: repositoryRoot,
      timeoutMs: options.suiteTimeoutMs,
      maxCapturedBytes: outputLimitBytes,
      onSpawn: (child) => { terminate = child.terminate; },
      onOutputChunk: (chunk) => {
        outputBytes += chunk.length;
        if (outputBytes > outputLimitBytes && !overflow) { overflow = true; void terminate(); }
      },
      onStdoutLine: onLine,
    });
  } catch (error) {
    result = { code: null, signal: null, timedOut: false, terminationConfirmed: true,
      durationMs: 0, stdout: "", stderr: String(error) };
  }
  writeFileSync(options.report.replace(/\.json$/i, ".log"), `${result.stdout}\n${result.stderr}`);
  for (const [key, running] of active) {
    const [suite, name] = key.split("\u0000");
    records.push({ name, suite, status: result.timedOut || overflow ? "timeout" : "incomplete",
      durationMs: Math.round(performance.now() - running.started), details: running.output });
  }
  for (const suite of packageFailures) {
    if (!records.some((record) => record.suite === suite && record.status === "failed")) {
      records.push({ name: "Go package failure", suite, status: "error", durationMs: 0,
        details: "The package failed without an individual test failure; inspect the raw log." });
    }
  }
  if (records.length === 0 || malformed || result.timedOut || overflow || result.code !== 0 || !result.terminationConfirmed) {
    records.push({ name: "Go test runner", suite: "Go test runner", status: "error", durationMs: 0,
      details: `exit=${result.code} signal=${result.signal} timeout=${result.timedOut} outputLimit=${overflow} malformed=${malformed} terminationConfirmed=${result.terminationConfirmed}` });
  }
  const report = { schemaVersion: 1, runner: "go", platform: process.platform, startedAt,
    command: [options.command, ...options.commandArguments], warnMs: options.warnMs, maxMs: options.maxMs,
    suiteTimeoutMs: options.suiteTimeoutMs,
    process: { exitCode: result.code, signal: result.signal, timedOut: result.timedOut,
      terminationConfirmed: result.terminationConfirmed, durationMs: Math.round(result.durationMs) }, tests: records };
  writeFileSync(options.report, `${JSON.stringify(report, null, 2)}\n`);
  writeTestReportArtifacts(options.report);
  const issues = records.filter((record) => ["failed", "error", "timeout", "incomplete"].includes(record.status) || record.durationMs >= options.maxMs);
  console.log(`Recorded ${records.length} Go test result(s) in ${options.report}`);
  for (const record of [...records].filter((item) => item.durationMs >= options.warnMs).sort((a, b) => b.durationMs - a.durationMs).slice(0, 10)) {
    console.log(`SLOW ${record.durationMs}ms ${record.suite} / ${record.name}`);
  }
  if (issues.length) throw new Error(`${issues.length} Go test result(s) failed or exceeded the local budget.`);
  return report;
}

async function main() {
  try { await run(parseArguments(process.argv.slice(2))); }
  catch (error) { console.error(`Go test timing failed: ${error.message}`); process.exitCode = 1; }
}
if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) await main();
