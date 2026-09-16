import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { writeTestReportArtifacts } from "../../../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs";

const root = resolve(import.meta.dirname, "../../..");
const logicOnly = process.argv.includes("--logic-only");
const workbenchTests = process.argv.includes("--workbench-tests");
const resultPath = workbenchTests ? ".artifacts/monaco-workbench/test-results/result.json" : `.artifacts/monaco-probe/${logicOnly ? "logic/" : ""}result.json`;
const result = JSON.parse(readFileSync(resolve(root, resultPath), "utf8"));
const directory = resolve(root, ".artifacts/test-stability");
mkdirSync(directory, { recursive: true });
const report = {
  runner: "macOS WKWebView integration probe",
  warnMs: 10_000, maxMs: 15_000,
  tests: result.status === "passed" ? result.cases.map(test => ({
    ...test, suite: "Monaco native host", status: "passed", details: JSON.stringify(test.metrics ?? {}),
  })) : [{ name: "native host integration", suite: "Monaco native host", durationMs: 0, status: "failed", details: result.error }],
};
const path = resolve(directory, `macos-monaco-${workbenchTests ? "workbench" : logicOnly ? "probe-logic" : "probe"}.json`);
writeFileSync(path, JSON.stringify(report, null, 2));
writeTestReportArtifacts(path);
if (report.tests.some(test => test.status !== "passed" || test.durationMs >= report.maxMs)) process.exitCode = 1;
