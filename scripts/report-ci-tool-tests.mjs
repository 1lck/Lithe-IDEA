#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseJUnitCases } from "../.agents/skills/write-stable-tests/scripts/parse-junit-cases.mjs";
import { writeTestReportArtifacts } from "../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs";

export function toolReport(tests) {
  if (tests.length === 0) throw new Error("Missing CI tooling test results");
  return {
    runner: "node", warnMs: 1000, maxMs: 15000,
    tests: tests.map((test) => ({
      ...test,
      // This integration scenario compiles and launches real Rust binaries;
      // retain the Node test's 60-second local deadline in HTML/JUnit as well.
      ...(test.name.endsWith("real Rust binaries honor the filter, report selected timings and fail empty matches") ? { maxMs: 60000 } : {}),
    })),
  };
}

export function budgetFailures(report) {
  return report.tests.filter((test) => !["passed", "skipped"].includes(test.status)
    || !Number.isFinite(test.durationMs) || test.durationMs >= (test.maxMs ?? report.maxMs));
}

export function reportTools(directory) {
  let reports = 0;
  const failures = [];
  for (const name of ["ci-workflows", "sparkle-baseline"]) {
    const stem = resolve(directory, name);
    if (!existsSync(`${stem}.junit.xml`)) continue;
    const report = toolReport(parseJUnitCases(readFileSync(`${stem}.junit.xml`, "utf8")));
    writeFileSync(`${stem}.json`, JSON.stringify(report, null, 2) + "\n");
    writeTestReportArtifacts(`${stem}.json`);
    failures.push(...budgetFailures(report).map((test) => `${name}: ${test.name}`));
    reports++;
  }
  if (reports === 0) throw new Error("Missing CI tooling test results");
  // Write all available diagnostics before failing the classification job/gate.
  if (failures.length) throw new Error(`CI tooling tests failed or exceeded their budget:\n${failures.join("\n")}`);
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  try { reportTools(resolve(import.meta.dirname, "../.artifacts/test-stability")); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
