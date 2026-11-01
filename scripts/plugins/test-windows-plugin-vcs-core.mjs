#!/usr/bin/env node

// Explicit native integration with a controlled Provider over real Core stdio.
// This does not verify an installed production plugin or the system SVN client.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArguments, run } from "../../.agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs";
import { runProcess } from "../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";

const REPOSITORY_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const TEST_NAME = "plugin_host::vcs::session::core_tests::real_core_stdio_optional_writes_use_only_the_frozen_typed_arguments";
// Four operations each bound request work to 5s and owner cleanup to 13s.
// The case watchdog includes those paths plus fixture setup; the suite stays bounded.
const TEST_BUDGET_MS = 90000;

async function runVcsCoreProcess(request) {
  if (request.args.includes("--list")) {
    const listed = await runProcess(request);
    return {
      ...listed,
      stdout: listed.stdout
        .split(/\r?\n/)
        .filter((line) => line === `${TEST_NAME}: test`)
        .join("\n"),
    };
  }
  if (request.args[0] === "--exact" && request.args[1] === TEST_NAME) {
    return runProcess({
      ...request,
      args: [...request.args, "--ignored"],
      env: { ...(request.env ?? process.env), LITHE_VCS_TEST_NODE: process.execPath },
    });
  }
  return runProcess(request);
}

async function main() {
  const arguments_ = process.argv.slice(2);
  if (
    arguments_.length !== 0 &&
    (arguments_.length !== 2 ||
      arguments_[0] !== "--report" ||
      !arguments_[1] ||
      arguments_[1].startsWith("--") ||
      !arguments_[1].toLowerCase().endsWith(".json"))
  ) {
    throw new Error("Usage: node scripts/plugins/test-windows-plugin-vcs-core.mjs [--report <path.json>]");
  }
  const options = parseArguments([
    "--manifest", path.join(REPOSITORY_ROOT, "windows/tauri/src-tauri/Cargo.toml"),
    "--report", path.join(REPOSITORY_ROOT, ".artifacts/test-stability/windows-plugin-vcs-core.json"),
    "--test-budget", `${TEST_NAME}=${TEST_BUDGET_MS}`,
    ...arguments_,
  ]);
  // Keep the shared runner's 20-minute suite/build budgets, report formats,
  // per-case timing and process-tree watchdog. Only this case opts into ignored.
  await run(options, { runProcessImpl: runVcsCoreProcess });
  const report = JSON.parse(readFileSync(options.report, "utf8"));
  if (
    report.tests?.length !== 1 ||
    report.tests[0].name !== TEST_NAME ||
    report.tests[0].status !== "passed" ||
    report.tests[0].maxMs !== TEST_BUDGET_MS
  ) {
    throw new Error("The real Core VCS stdio integration must report exactly one passed case; skipped tests do not verify it.");
  }
}

try {
  await main();
} catch (error) {
  console.error(`Windows plugin VCS Core integration failed: ${error.message}`);
  process.exitCode = 1;
}
