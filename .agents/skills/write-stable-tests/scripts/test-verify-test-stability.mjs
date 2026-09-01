#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseAddedLines, scanFile } from "./verify-test-stability.mjs";
import { parseJUnitCases } from "./parse-junit-cases.mjs";
import { run as runBunTestsWithTiming } from "./run-bun-tests-with-timing.mjs";
import { run as runRustTestsWithTiming } from "./run-rust-tests-with-timing.mjs";
import {
  parseSwiftSuiteLine,
  parseSwiftTimingLine,
  run as runSwiftTestsWithTiming,
} from "./run-swift-tests-with-timing.mjs";
import { runProcess } from "./test-timing-lib.mjs";

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

const detachedViolations = scanFile(
  "macos/Tests/LitheTests/DetachedBlockingTests.swift",
  `Task.detached {
    operations
        .waitUntilBlocked()
}
`,
);
assert.deepEqual(detachedViolations.map((violation) => violation.rule), ["swift-detached-blocking"]);
assert.equal(detachedViolations[0].line, 3);

const multilineWaitContent = `gate.wait(
    timeout: .distantFuture
)
`;

const multilineWaitViolations = scanFile(
  "macos/Tests/LitheTests/MultilineWaitTests.swift",
  multilineWaitContent,
);

assert.deepEqual(
  multilineWaitViolations.map((violation) => violation.rule),
  ["swift-unbounded-wait"],
);

assert.equal(multilineWaitViolations[0].line, 1);

const selectedMultilineWaitViolations = scanFile(
  "macos/Tests/LitheTests/MultilineWaitTests.swift",
  multilineWaitContent,
  new Set([2]),
);

assert.deepEqual(
  selectedMultilineWaitViolations.map((violation) => violation.rule),
  ["swift-unbounded-wait"],
);

assert.equal(selectedMultilineWaitViolations[0].line, 2);

assert.match(
  selectedMultilineWaitViolations[0].source,
  /distantFuture/,
);

const bareMultilineWaitViolations = scanFile(
  "macos/Tests/LitheTests/MultilineWaitTests.swift",
  `gate.wait(
)
`,
);

assert.deepEqual(
  bareMultilineWaitViolations.map((violation) => violation.rule),
  ["swift-unbounded-wait"],
);

const finiteMultilineWaitViolations = scanFile(
  "macos/Tests/LitheTests/MultilineWaitTests.swift",
  `gate.wait(
    timeout: .now() + .seconds(timeoutSeconds())
)
`,
);

assert.deepEqual(finiteMultilineWaitViolations, []);

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

const bunTimeoutRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-bun-timeout-"));
try {
  const reportPath = path.join(bunTimeoutRoot, "bun-timeout.json");
  await assert.rejects(
    runBunTestsWithTiming(
      {
        workingDirectory: bunTimeoutRoot,
        warnMs: 50,
        maxMs: 200,
        suiteTimeoutMs: 500,
        report: reportPath,
        testArguments: [],
      },
      {
        runProcessImpl: async () => ({
          code: null,
          signal: "SIGTERM",
          timedOut: true,
          terminationConfirmed: true,
          durationMs: 500,
          stdout: "",
          stderr: "",
        }),
      },
    ),
    /Bun test suite exceeded 500ms/,
  );
  const timeoutReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.deepEqual(
    timeoutReport.tests.map(({ name, status }) => ({ name, status })),
    [{ name: "Bun test suite timeout", status: "timeout" }],
  );
  assert.match(readFileSync(reportPath.replace(/\.json$/, ".junit.xml"), "utf8"), /errors="1"/);
  assert.ok(existsSync(reportPath.replace(/\.json$/, ".html")));
} finally {
  rmSync(bunTimeoutRoot, { recursive: true, force: true });
}

const swiftTimeoutRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-swift-timeout-"));
try {
  const reportPath = path.join(swiftTimeoutRoot, "swift-timeout.json");
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        suiteTimeoutMs: 500,
        report: reportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        runProcessImpl: async ({ onSpawn }) => {
          onSpawn({ terminate: async () => true });
          return {
            code: null,
            signal: "SIGTERM",
            timedOut: true,
            terminationConfirmed: true,
            durationMs: 500,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /Swift test suite exceeded 500ms/,
  );
  const timeoutReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.deepEqual(
    timeoutReport.tests.map(({ name, status }) => ({ name, status })),
    [{ name: "Swift test suite timeout", status: "timeout" }],
  );
  assert.match(readFileSync(reportPath.replace(/\.json$/, ".junit.xml"), "utf8"), /errors="1"/);
  assert.ok(existsSync(reportPath.replace(/\.json$/, ".html")));
} finally {
  rmSync(swiftTimeoutRoot, { recursive: true, force: true });
}

// Regression coverage for the CI misattribution incident: block-buffered pipes
// can swallow a finish line, so a stall must be reported as runner silence with
// the unfinished tests listed, never as "test X exceeded the budget".
const swiftStallRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-swift-stall-"));
try {
  const reportPath = path.join(swiftStallRoot, "swift-stall.json");
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        stallTimeoutMs: 100,
        suiteTimeoutMs: 5000,
        report: reportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        runProcessImpl: async ({ onStdoutLine, onSpawn }) => {
          let resolveTerminated;
          const terminated = new Promise((resolve) => {
            resolveTerminated = resolve;
          });
          onSpawn({
            terminate: async () => {
              resolveTerminated();
              return true;
            },
          });
          onStdoutLine('◇ Suite "Keyboard shortcuts" started.');
          onStdoutLine("◇ Test fast() started.");
          onStdoutLine("✔ Test fast() passed after 0.001 seconds.");
          onStdoutLine("◇ Test truncatedFinishLine() started.");
          // The finish line for truncatedFinishLine() never arrives, as when the
          // runner's stdio buffer is lost; the stall watchdog must fire.
          await terminated;
          return {
            code: null,
            signal: "SIGTERM",
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 150,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /produced no output for 100ms; tests without a reported result: truncatedFinishLine\(\)/,
  );
  const stallReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.equal(stallReport.process.stalled, true);
  assert.deepEqual(
    stallReport.tests.map(({ name, status }) => ({ name, status })),
    [
      { name: "fast()", status: "passed" },
      { name: "truncatedFinishLine()", status: "timeout" },
      { name: "Swift test runner stall", status: "timeout" },
    ],
  );
} finally {
  rmSync(swiftStallRoot, { recursive: true, force: true });
}

// A stall after every test reported a result points at teardown/exit instead of
// blaming any test.
const swiftTeardownStallRoot = mkdtempSync(
  path.join(os.tmpdir(), "lithe-test-stability-swift-teardown-stall-"),
);
try {
  const reportPath = path.join(swiftTeardownStallRoot, "swift-teardown-stall.json");
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        stallTimeoutMs: 100,
        suiteTimeoutMs: 5000,
        report: reportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        runProcessImpl: async ({ onStdoutLine, onSpawn }) => {
          let resolveTerminated;
          const terminated = new Promise((resolve) => {
            resolveTerminated = resolve;
          });
          onSpawn({
            terminate: async () => {
              resolveTerminated();
              return true;
            },
          });
          onStdoutLine("◇ Test fast() started.");
          onStdoutLine("✔ Test fast() passed after 0.001 seconds.");
          await terminated;
          return {
            code: null,
            signal: "SIGTERM",
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 150,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /produced no output for 100ms; every parsed test had reported a result/,
  );
  const teardownReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.equal(teardownReport.process.stalled, true);
  assert.deepEqual(
    teardownReport.tests.map(({ name, status }) => ({ name, status })),
    [
      { name: "fast()", status: "passed" },
      { name: "Swift test runner stall", status: "timeout" },
    ],
  );
} finally {
  rmSync(swiftTeardownStallRoot, { recursive: true, force: true });
}

// The per-test budget is enforced from the durations swift-testing reports: a
// test that finishes over maxMs must fail the run even though the runner
// exited cleanly and no watchdog fired.
const swiftBudgetRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-swift-budget-"));
try {
  const reportPath = path.join(swiftBudgetRoot, "swift-budget.json");
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        stallTimeoutMs: 5000,
        suiteTimeoutMs: 10000,
        report: reportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        runProcessImpl: async ({ onStdoutLine, onSpawn }) => {
          onSpawn({ terminate: async () => true });
          onStdoutLine("◇ Test overBudget() started.");
          onStdoutLine("✔ Test overBudget() passed after 0.250 seconds.");
          return {
            code: 0,
            signal: null,
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 300,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /1 Swift test\(s\) exceeded the local budget/,
  );
  const budgetReport = JSON.parse(readFileSync(reportPath, "utf8"));
  assert.deepEqual(
    budgetReport.tests.map(({ name, status, durationMs }) => ({ name, status, durationMs })),
    [{ name: "overBudget()", status: "passed", durationMs: 250 }],
  );
} finally {
  rmSync(swiftBudgetRoot, { recursive: true, force: true });
}

// A spawn failure must reject promptly and clear the stall watchdog; a leaked
// ref'd timer would keep the harness process alive for the full stall timeout.
{
  const spawnFailureRoot = mkdtempSync(
    path.join(os.tmpdir(), "lithe-test-stability-swift-spawn-failure-"),
  );
  try {
    await assert.rejects(
      runSwiftTestsWithTiming(
        {
          warnMs: 50,
          maxMs: 200,
          stallTimeoutMs: 600000,
          suiteTimeoutMs: 10000,
          report: path.join(spawnFailureRoot, "swift-spawn-failure.json"),
          command: "swift",
          commandArguments: ["test"],
        },
        {
          runProcessImpl: async () => {
            throw new Error("spawn ENOENT");
          },
        },
      ),
      /spawn ENOENT/,
    );
    // If the watchdog leaked, the 600s timer would hold this test process open
    // long past its CI budget; reaching this line with a cleared event loop is
    // asserted implicitly by the suite finishing on time.
  } finally {
    rmSync(spawnFailureRoot, { recursive: true, force: true });
  }
}

const rustCompileFailureRoot = mkdtempSync(
  path.join(
    os.tmpdir(),
    "lithe-test-stability-rust-compile-failure-",
  ),
);

try {
  const reportPath = path.join(
    rustCompileFailureRoot,
    "rust-compile-failure.json",
  );

  await assert.rejects(
    runRustTestsWithTiming(
      {
        manifest: path.join(
          rustCompileFailureRoot,
          "Cargo.toml",
        ),
        package: null,
        warnMs: 50,
        maxMs: 200,
        buildTimeoutMs: 1000,
        suiteTimeoutMs: 2000,
        report: reportPath,
        keepGoing: false,
      },
      {
        runProcessImpl: async ({
          onStdoutLine = () => {},
        }) => {
          onStdoutLine(
            JSON.stringify({
              reason: "compiler-message",
              message: {
                rendered:
                  "error[E0425]: cannot find value `missing` in this scope\n",
              },
            }),
          );

          return {
            code: 101,
            signal: null,
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 12,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /Cargo test compilation exited with code 101/,
  );

  const compileFailureReport = JSON.parse(
    readFileSync(reportPath, "utf8"),
  );

  assert.deepEqual(
    compileFailureReport.tests.map(
      ({ name, status }) => ({ name, status }),
    ),
    [
      {
        name: "Cargo test compilation",
        status: "failed",
      },
    ],
  );

  assert.match(
    compileFailureReport.tests[0].details,
    /E0425/,
  );

  assert.match(
    readFileSync(
      reportPath.replace(/\.json$/, ".log"),
      "utf8",
    ),
    /E0425/,
  );

  assert.match(
    readFileSync(
      reportPath.replace(/\.json$/, ".junit.xml"),
      "utf8",
    ),
    /failures="1"/,
  );

  assert.ok(
    existsSync(
      reportPath.replace(/\.json$/, ".html"),
    ),
  );
} finally {
  rmSync(rustCompileFailureRoot, {
    recursive: true,
    force: true,
  });
}

if (process.platform !== "win32") {
  let rootPID = null;
  let descendantPID = null;
  const descendantSource = "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);";
  const rootSource = `
    const { spawn } = require("node:child_process");
    const descendant = spawn(process.execPath, ["-e", ${JSON.stringify(descendantSource)}], {
      stdio: "ignore",
    });
    console.log(descendant.pid);
    setInterval(() => {}, 1000);
  `;
  try {
    const result = await runProcess({
      command: process.execPath,
      args: ["-e", rootSource],
      timeoutMs: 100,
      terminationGraceMs: 100,
      forcedTerminationTimeoutMs: 1000,
      terminationPollIntervalMs: 10,
      onSpawn: ({ pid }) => {
        rootPID = pid;
      },
      onStdoutLine: (line) => {
        descendantPID = Number(line);
      },
    });
    assert.equal(result.timedOut, true);
    assert.equal(result.terminationConfirmed, true);
    assert.ok(Number.isInteger(descendantPID) && descendantPID > 0);
    assert.throws(() => process.kill(descendantPID, 0), { code: "ESRCH" });
  } finally {
    for (const pid of [descendantPID, rootPID]) {
      if (!Number.isInteger(pid) || pid <= 0) continue;
      try {
        process.kill(pid === rootPID ? -pid : pid, "SIGKILL");
      } catch {
        // The expected path already removed the process tree.
      }
    }
  }
}

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
