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
  isSwiftTestCompletionFragment,
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
  parseSwiftTimingLine("✘ Test runBeforeTheSnapshot() failed after 30.259 seconds with 3 issues."),
  { name: "runBeforeTheSnapshot()", event: "failed", durationMs: 30259, caseCount: null },
);
assert.deepEqual(
  parseSwiftSuiteLine('◇ Suite "App localization" started.'),
  { name: "App localization", event: "started" },
);
assert.equal(
  isSwiftTestCompletionFragment(
    "✔ Test catalogHa",
    "catalogHasStableUniqueCommandsAndConflictFreeDefaults()",
  ),
  true,
);
assert.equal(
  isSwiftTestCompletionFragment(
    "◇ Test catalogHasStableUniqueCommandsAndConflictFreeDefaults() started.",
    "catalogHasStableUniqueCommandsAndConflictFreeDefaults()",
  ),
  false,
);
assert.equal(
  isSwiftTestCompletionFragment("✔ Test anotherTest", "catalogHasStableUniqueCommands"),
  false,
);
assert.equal(
  isSwiftTestCompletionFragment(
    "✘ Test runBeforeTheSnapshot() recorded an issue at RunEntryPointTests.swift:35:9",
    "runBeforeTheSnapshot()",
  ),
  false,
);
assert.equal(
  isSwiftTestCompletionFragment(
    "✘ Test runBeforeTheSnapshot() failed after 30.259 seconds with 3 issues.",
    "runBeforeTheSnapshot()",
  ),
  true,
);

let observedPartialLine = null;
const partialLineResult = await runProcess({
  command: process.execPath,
  args: ["-e", "process.stdout.write('✔ Test catalogHa')"],
  timeoutMs: 1000,
  onStdoutPartialLine: (line) => {
    observedPartialLine = line;
  },
});
assert.equal(partialLineResult.code, 0);
assert.equal(observedPartialLine, "✔ Test catalogHa");

const swiftFragmentRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-swift-fragment-"));
try {
  const reportPath = path.join(swiftFragmentRoot, "swift-fragment.json");
  const timeoutToken = Symbol("swift-test-timeout");
  let timeoutCleared = false;
  let childTerminated = false;
  await runSwiftTestsWithTiming(
    {
      warnMs: 50,
      maxMs: 200,
      suiteTimeoutMs: 500,
      report: reportPath,
      command: "swift",
      commandArguments: ["test"],
    },
    {
      setTimeoutImpl: (callback) => {
        assert.equal(typeof callback, "function");
        return timeoutToken;
      },
      clearTimeoutImpl: (token) => {
        assert.equal(token, timeoutToken);
        timeoutCleared = true;
      },
      runProcessImpl: async ({ onSpawn, onStdoutLine, onStdoutPartialLine }) => {
        onSpawn({
          terminate: async () => {
            childTerminated = true;
            return true;
          },
        });
        onStdoutLine('◇ Suite "Keyboard shortcuts" started.');
        onStdoutLine(
          "◇ Test catalogHasStableUniqueCommandsAndConflictFreeDefaults() started.",
        );
        onStdoutPartialLine("✔ Test catalogHa");
        assert.equal(timeoutCleared, true);
        onStdoutLine(
          "✔ Test catalogHasStableUniqueCommandsAndConflictFreeDefaults() passed after 0.001 seconds.",
        );
        onStdoutLine('✔ Suite "Keyboard shortcuts" passed after 0.001 seconds.');
        return {
          code: 0,
          signal: null,
          timedOut: false,
          terminationConfirmed: true,
          durationMs: 1,
          stdout: "",
          stderr: "",
        };
      },
    },
  );
  assert.equal(childTerminated, false);
  assert.deepEqual(
    JSON.parse(readFileSync(reportPath, "utf8")).tests.map(({ name, status }) => ({
      name,
      status,
    })),
    [
      {
        name: "catalogHasStableUniqueCommandsAndConflictFreeDefaults()",
        status: "passed",
      },
    ],
  );

  const issueReportPath = path.join(swiftFragmentRoot, "swift-issue-fragment.json");
  let issueTimeout = null;
  let issueTimerCleared = false;
  let issueChildTerminated = false;
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        suiteTimeoutMs: 500,
        report: issueReportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        setTimeoutImpl: (callback) => {
          issueTimeout = callback;
          return timeoutToken;
        },
        clearTimeoutImpl: () => {
          issueTimerCleared = true;
        },
        runProcessImpl: async ({ onSpawn, onStdoutLine, onStdoutPartialLine }) => {
          onSpawn({
            terminate: async () => {
              issueChildTerminated = true;
              return true;
            },
          });
          onStdoutLine('◇ Suite "Run entry points" started.');
          onStdoutLine("◇ Test runBeforeTheSnapshot() started.");
          onStdoutPartialLine(
            "✘ Test runBeforeTheSnapshot() recorded an issue at RunEntryPointTests.swift:35:9",
          );
          assert.equal(issueTimerCleared, false);
          issueTimeout();
          assert.equal(issueChildTerminated, true);
          return {
            code: null,
            signal: "SIGTERM",
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 200,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /Swift test exceeded 200ms: runBeforeTheSnapshot\(\)/,
  );
  assert.deepEqual(
    JSON.parse(readFileSync(issueReportPath, "utf8")).tests.map(({ name, status }) => ({
      name,
      status,
    })),
    [{ name: "runBeforeTheSnapshot()", status: "timeout" }],
  );

  const interleavedReportPath = path.join(swiftFragmentRoot, "swift-interleaved.json");
  const scheduledTimers = new Map();
  let nextTimerID = 0;
  let interleavedChildTerminated = false;
  await assert.rejects(
    runSwiftTestsWithTiming(
      {
        warnMs: 50,
        maxMs: 200,
        suiteTimeoutMs: 500,
        report: interleavedReportPath,
        command: "swift",
        commandArguments: ["test"],
      },
      {
        setTimeoutImpl: (callback) => {
          const timerID = ++nextTimerID;
          scheduledTimers.set(timerID, callback);
          return timerID;
        },
        clearTimeoutImpl: (timerID) => {
          assert.equal(scheduledTimers.delete(timerID), true);
        },
        runProcessImpl: async ({ onSpawn, onStdoutLine }) => {
          onSpawn({
            terminate: async () => {
              interleavedChildTerminated = true;
              return true;
            },
          });
          onStdoutLine('◇ Suite "Interleaved tests" started.');
          onStdoutLine("◇ Test firstTest() started.");
          onStdoutLine("◇ Test secondTest() started.");
          const firstTimer = 1;
          const secondTimer = 2;
          assert.deepEqual([...scheduledTimers.keys()], [firstTimer, secondTimer]);

          onStdoutLine("✔ Test secondTest() passed after 0.001 seconds.");
          assert.equal(scheduledTimers.has(secondTimer), false);
          assert.equal(scheduledTimers.has(firstTimer), true);

          const firstTimeout = scheduledTimers.get(firstTimer);
          scheduledTimers.delete(firstTimer);
          firstTimeout();
          assert.equal(interleavedChildTerminated, true);
          return {
            code: null,
            signal: "SIGTERM",
            timedOut: false,
            terminationConfirmed: true,
            durationMs: 200,
            stdout: "",
            stderr: "",
          };
        },
      },
    ),
    /Swift test exceeded 200ms: firstTest\(\)/,
  );
  assert.deepEqual(
    JSON.parse(readFileSync(interleavedReportPath, "utf8")).tests.map(({ name, status }) => ({
      name,
      status,
    })),
    [
      { name: "secondTest()", status: "passed" },
      { name: "firstTest()", status: "timeout" },
    ],
  );
} finally {
  rmSync(swiftFragmentRoot, { recursive: true, force: true });
}

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
