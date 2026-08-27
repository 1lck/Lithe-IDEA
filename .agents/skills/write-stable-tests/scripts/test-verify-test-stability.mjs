#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseAddedLines, scanFile } from "./verify-test-stability.mjs";
import { parseJUnitCases } from "./parse-junit-cases.mjs";
import { run as runRustTestsWithTiming } from "./run-rust-tests-with-timing.mjs";
import { parseSwiftSuiteLine, parseSwiftTimingLine } from "./run-swift-tests-with-timing.mjs";

const swiftViolations = scanFile(
  "macos/Tests/LitheTests/BlockingTests.swift",
  `import Testing
private let gate = DispatchSemaphore(value: 0)
gate.wait()
gate.wait(timeout: .distantFuture)
gate.wait(timeout: DispatchTime.distantFuture)
gate.wait(timeout: .now() + .seconds(1))
// test-stability: allow(swift-real-sleep) reason: verifies a native synchronous timeout boundary
try await Task.sleep(for: .milliseconds(1))
`,
);
assert.deepEqual(
  swiftViolations.map((violation) => violation.rule),
  ["swift-unbounded-wait", "swift-unbounded-wait", "swift-unbounded-wait"],
);

const typescriptViolations = scanFile(
  "windows/tauri/src/example.test.ts",
  `test("bad timer", async () => {
  await new Promise((resolve) => setTimeout(resolve, 10));
});
`,
);
assert.deepEqual(typescriptViolations.map((violation) => violation.rule), ["typescript-real-timer"]);

const rustViolations = scanFile(
  "rust/lithe-core/src/example.rs",
  `use std::thread;
fn production_backoff() { thread::sleep(Duration::from_millis(1)); }
#[cfg(test)]
mod tests {
    #[test]
    fn blocks() {
        thread::sleep(Duration::from_millis(1));
    }
}
`,
);
assert.deepEqual(rustViolations.map((violation) => violation.rule), ["rust-real-sleep"]);
assert.equal(rustViolations[0].line, 7);

const diff = `diff --git a/macos/Tests/LitheTests/Example.swift b/macos/Tests/LitheTests/Example.swift
--- a/macos/Tests/LitheTests/Example.swift
+++ b/macos/Tests/LitheTests/Example.swift
@@ -2,0 +3,2 @@
+let gate = DispatchSemaphore(value: 0)
+gate.wait()
`;
const added = parseAddedLines(diff);
assert.deepEqual([...added.get("macos/Tests/LitheTests/Example.swift")], [3, 4]);

const selectedViolations = scanFile(
  "macos/Tests/LitheTests/Example.swift",
  "let unchanged = true\nThread.sleep(forTimeInterval: 1)\nlet added = true\ngate.wait()\n",
  new Set([3, 4]),
);
assert.deepEqual(selectedViolations.map((violation) => violation.rule), ["swift-unbounded-wait"]);

assert.deepEqual(
  parseSwiftTimingLine("✔ Test deterministicGate() passed after 0.024 seconds."),
  { name: "deterministicGate()", event: "passed", durationMs: 24, caseCount: null },
);
assert.deepEqual(
  parseSwiftTimingLine("Test Case '-[LitheTests.Legacy testValue]' failed (1.250 seconds)."),
  { name: "-[LitheTests.Legacy testValue]", event: "failed", durationMs: 1250, caseCount: null },
);
assert.equal(
  parseSwiftTimingLine("◇ Test case passing 1 argument value → 1 to parameterized(_:) started."),
  null,
);
assert.deepEqual(
  parseSwiftTimingLine("✔ Test parameterized(_:) with 4 test cases passed after 0.125 seconds."),
  { name: "parameterized(_:)", event: "passed", durationMs: 125, caseCount: 4 },
);
assert.deepEqual(
  parseSwiftSuiteLine('◇ Suite "App localization" started.'),
  { name: "App localization", event: "started" },
);

assert.deepEqual(
  parseJUnitCases(
    '<testsuite><testcase classname="scheduler" name="fires &amp; clears" time="0.125"/><testcase name="skips" time="0"><skipped/></testcase></testsuite>',
  ),
  [
    { name: "scheduler / fires & clears", status: "passed", durationMs: 125 },
    { name: "skips", status: "skipped", durationMs: 0 },
  ],
);

const fixtureRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-rust-"));
try {
  mkdirSync(path.join(fixtureRoot, "src"));
  writeFileSync(
    path.join(fixtureRoot, "Cargo.toml"),
    '[package]\nname = "timing-fixture"\nversion = "0.1.0"\nedition = "2021"\n',
  );
  writeFileSync(
    path.join(fixtureRoot, "src/lib.rs"),
    `#[cfg(test)]
mod tests {
    #[test]
    fn a_quick() { assert_eq!(2 + 2, 4); }

    #[test]
    fn z_hangs() { std::thread::sleep(std::time::Duration::from_secs(5)); }
}
`,
  );
  const reportPath = path.join(fixtureRoot, "timing.json");
  const runnerPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "run-rust-tests-with-timing.mjs");
  const result = spawnSync(
    process.execPath,
    [
      runnerPath,
      "--manifest", path.join(fixtureRoot, "Cargo.toml"),
      "--warn-ms", "50",
      "--max-ms", "200",
      "--build-timeout-ms", "30000",
      "--suite-timeout-ms", "30000",
      "--report", reportPath,
    ],
    { encoding: "utf8", timeout: 60000 },
  );
  assert.notEqual(result.status, 0, "the Rust timing runner must reject a hanging test");
  assert.ok(
    existsSync(reportPath),
    `the Rust timing runner did not write a report\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
  const timingReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.deepEqual(
    timingReport.tests.map(({ name, status }) => ({ name, status })),
    [
      { name: "tests::a_quick", status: "passed" },
      { name: "tests::z_hangs", status: "timeout" },
    ],
  );
  const html = readFileSync(path.join(fixtureRoot, "timing.html"), "utf8");
  const junit = readFileSync(path.join(fixtureRoot, "timing.junit.xml"), "utf8");
  assert.match(html, /问题与性能优化队列/);
  assert.match(html, /tests::z_hangs/);
  assert.match(html, /over budget|timeout/);
  assert.match(junit, /errors="1"/);
  assert.match(junit, /tests::z_hangs/);
  assert.ok(existsSync(path.join(fixtureRoot, "index.html")));
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}

const deadlineFixtureRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-deadline-"));
try {
  const reportPath = path.join(deadlineFixtureRoot, "deadline.json");
  const manifestPath = path.join(deadlineFixtureRoot, "Cargo.toml");
  const executablePath = path.join(deadlineFixtureRoot, "fake-tests");
  let currentTime = 0;
  let invocation = 0;
  const runProcessImpl = async ({ args, onStdoutLine = () => {}, timeoutMs }) => {
    invocation += 1;
    if (invocation === 1) {
      assert.equal(timeoutMs, 1000);
      currentTime = 400;
      onStdoutLine(JSON.stringify({
        reason: "compiler-artifact",
        profile: { test: true },
        executable: executablePath,
        manifest_path: manifestPath,
        target: { name: "deadline-fixture" },
      }));
      return { code: 0, signal: null, timedOut: false, durationMs: 400, stdout: "", stderr: "" };
    }
    if (args[0] === "--list") {
      assert.equal(timeoutMs, 600);
      currentTime = 500;
      return {
        code: 0,
        signal: null,
        timedOut: false,
        durationMs: 100,
        stdout: "tests::first: test\ntests::second: test\n",
        stderr: "",
      };
    }
    if (args[1] === "tests::first") {
      assert.equal(timeoutMs, 500);
      currentTime = 800;
      return {
        code: 0,
        signal: null,
        timedOut: false,
        durationMs: 300,
        stdout: "running 1 test\ntest tests::first ... ok\n",
        stderr: "",
      };
    }
    assert.deepEqual(args.slice(0, 2), ["--exact", "tests::second"]);
    assert.equal(timeoutMs, 200);
    currentTime = 1000;
    return {
      code: null,
      signal: "SIGTERM",
      timedOut: true,
      durationMs: 200,
      stdout: "running 1 test\n",
      stderr: "",
    };
  };

  await assert.rejects(
    runRustTestsWithTiming(
      {
        manifest: manifestPath,
        package: null,
        warnMs: 50,
        maxMs: 500,
        buildTimeoutMs: 5000,
        suiteTimeoutMs: 1000,
        report: reportPath,
        keepGoing: false,
      },
      { runProcessImpl, now: () => currentTime },
    ),
    /Rust test suite exceeded 1000ms during test deadline-fixture::tests::second/,
  );
  const deadlineReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.deepEqual(deadlineReport.suite, {
    timedOut: true,
    stage: "test deadline-fixture::tests::second",
    durationMs: 1000,
  });
  assert.deepEqual(
    deadlineReport.tests.map(({ name, status }) => ({ name, status })),
    [
      { name: "tests::first", status: "passed" },
      { name: "tests::second", status: "timeout" },
    ],
  );
  assert.match(deadlineReport.tests[1].details, /shared suite deadline expired/);
  assert.ok(existsSync(path.join(deadlineFixtureRoot, "deadline.html")));
  assert.ok(existsSync(path.join(deadlineFixtureRoot, "deadline.junit.xml")));
} finally {
  rmSync(deadlineFixtureRoot, { recursive: true, force: true });
}

console.log("Test stability verifier tests passed.");
