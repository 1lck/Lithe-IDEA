#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseArguments as parseGateArguments,
  parseAddedLines,
  parseDiff,
  reconcile,
  run as runGate,
  scanFile,
} from "./verify-test-stability.mjs";
import { parseArguments as parseRustTimingArguments, run as runRustTestsWithTiming } from "./run-rust-tests-with-timing.mjs";
import { runProcess } from "./test-timing-lib.mjs";
import "./test-stability-source-classification.mjs";

const rustViolations = scanFile(
  "rust/crates/core/src/example.rs",
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

const diff = `diff --git a/rust/crates/core/src/example.rs b/rust/crates/core/src/example.rs
--- a/rust/crates/core/src/example.rs
+++ b/rust/crates/core/src/example.rs
@@ -2,0 +3,2 @@
+let gate = receiver;
+gate.recv();
`;
const added = parseAddedLines(diff);
assert.deepEqual([...added.get("rust/crates/core/src/example.rs")], [3, 4]);

const selectedViolations = scanFile(
  "rust/crates/core/src/example.rs",
  "#[test]\nfn waits() {\nthread::sleep(Duration::from_millis(1));\nlet added = true;\ngate.recv();\n}\n",
  new Set([4, 5]),
);
assert.deepEqual(selectedViolations.map((violation) => violation.rule), ["rust-unbounded-receive"]);

// Deleted files are part of the base revision even though no head path remains.
const deletingDiff = `diff --git a/rust/crates/core/src/old.rs b/rust/crates/core/src/old.rs
--- a/rust/crates/core/src/old.rs
+++ /dev/null
@@ -1,3 +0,0 @@
-#[test]
-fn moved() {}
`;
const parsedDeletion = parseDiff(deletingDiff);
assert.deepEqual([...parsedDeletion.basePaths], ["rust/crates/core/src/old.rs"]);
assert.equal(parsedDeletion.added.size, 0);

// A sleep that moves with its test between files is pre-existing, not new.
const movedTest = `#[cfg(test)]
mod tests {
    #[test]
    fn waits_for_the_worker() {
        thread::sleep(Duration::from_millis(5));
    }
}
`;
const movedAcrossFiles = reconcile({
  headFiles: new Map([["rust/crates/core/src/new.rs", { content: movedTest, addedLines: null }]]),
  baseFiles: new Map([["rust/crates/core/src/old.rs", movedTest]]),
});
assert.deepEqual(movedAcrossFiles, { violations: [], moved: 1 });

// The same statement inside a different test is new: identity includes the
// enclosing declaration.
const renamedTest = movedTest.replace("waits_for_the_worker", "waits_for_another_worker");
const movedIntoAnotherTest = reconcile({
  headFiles: new Map([["rust/crates/core/src/new.rs", { content: renamedTest, addedLines: null }]]),
  baseFiles: new Map([["rust/crates/core/src/old.rs", movedTest]]),
});
assert.equal(movedIntoAnotherTest.moved, 0);
assert.deepEqual(movedIntoAnotherTest.violations.map(({ line, declaration }) => ({ line, declaration })), [
  { line: 5, declaration: "waits_for_another_worker" },
]);

// A duplicate of an existing sleep cannot hide behind the original: the
// unchanged line claims the base entry first.
const duplicatedSleep = movedTest.replace(
  "        thread::sleep(Duration::from_millis(5));\n",
  "        thread::sleep(Duration::from_millis(5));\n        thread::sleep(Duration::from_millis(5));\n",
);
const duplicated = reconcile({
  headFiles: new Map([["rust/crates/core/src/old.rs", { content: duplicatedSleep, addedLines: new Set([6]) }]]),
  baseFiles: new Map([["rust/crates/core/src/old.rs", movedTest]]),
});
assert.equal(duplicated.moved, 0);
assert.deepEqual(duplicated.violations.map(({ line }) => line), [6]);

// Dropping the annotation of a moved sleep makes it a new violation, because
// the annotated base line never counted as one.
const annotatedTest = movedTest.replace(
  "        thread::sleep",
  "        // test-stability: allow(rust-real-sleep) reason: the native boundary offers no completion signal\n        thread::sleep",
);
const unannotatedMove = reconcile({
  headFiles: new Map([["rust/crates/core/src/new.rs", { content: movedTest, addedLines: null }]]),
  baseFiles: new Map([["rust/crates/core/src/old.rs", annotatedTest]]),
});
assert.equal(unannotatedMove.moved, 0);
assert.equal(unannotatedMove.violations.length, 1);

assert.throws(() => parseGateArguments(["--head", "abc"]), /--head requires --base/);

// End to end against a real repository: a committed move passes in revision
// mode, and a duplicate in the working tree fails in working-tree mode.
const gateRepository = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-gate-"));
try {
  const gitIn = (...args) => {
    const result = spawnSync("git", args, { cwd: gateRepository, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const sourceDirectory = path.join(gateRepository, "rust", "crates", "core", "src");
  mkdirSync(sourceDirectory, { recursive: true });
  gitIn("init", "-q");
  gitIn("config", "user.email", "tests@example.invalid");
  gitIn("config", "user.name", "Test Stability");
  gitIn("config", "commit.gpgsign", "false");
  writeFileSync(path.join(sourceDirectory, "old.rs"), movedTest);
  gitIn("add", "-A");
  gitIn("commit", "-q", "-m", "base");
  const base = gitIn("rev-parse", "HEAD");
  rmSync(path.join(sourceDirectory, "old.rs"));
  writeFileSync(path.join(sourceDirectory, "new.rs"), movedTest);
  // An unrelated large text diff exceeded the gate's bounded git buffer
  // before path filtering, even though the Rust move itself is tiny.
  writeFileSync(path.join(gateRepository, "unrelated.txt"), "x".repeat(65 * 1024 * 1024));
  gitIn("add", "-A");
  gitIn("commit", "-q", "-m", "move");
  const head = gitIn("rev-parse", "HEAD");
  assert.deepEqual(runGate({ root: gateRepository, base, head, platform: "all" }), { violations: [], moved: 1 });

  writeFileSync(path.join(sourceDirectory, "new.rs"), duplicatedSleep);
  const workingTree = runGate({ root: gateRepository, platform: "all" });
  assert.equal(workingTree.moved, 0);
  assert.deepEqual(workingTree.violations.map(({ file, line }) => ({ file, line })), [
    { file: "rust/crates/core/src/new.rs", line: 6 },
  ]);
  // Revision mode reads committed content, so the dirty working tree is invisible to it.
  assert.deepEqual(runGate({ root: gateRepository, base, head, platform: "all" }), { violations: [], moved: 1 });

  // A newly committed Rust test is still visible to the filtered diff.
  writeFileSync(path.join(sourceDirectory, "new.rs"), movedTest);
  writeFileSync(path.join(sourceDirectory, "another.rs"), renamedTest);
  gitIn("add", "-A");
  gitIn("commit", "-q", "-m", "add tests");
  const withTests = runGate({ root: gateRepository, base, head: gitIn("rev-parse", "HEAD"), platform: "all" });
  assert.deepEqual(withTests.violations.map(({ file }) => file), ["rust/crates/core/src/another.rs"]);

} finally {
  rmSync(gateRepository, { recursive: true, force: true });
}

const partialEvents = [];
const partialProcess = await runProcess({
  command: process.execPath, args: ["-e", 'process.stdout.write("partial")'], timeoutMs: 2000,
  onOutputChunk: (chunk, stream) => partialEvents.push(["chunk", stream, chunk.toString()]),
  onStdoutLine: (line) => partialEvents.push(["line", "stdout", line]),
});
assert.equal(partialProcess.code, 0);
assert.equal(partialProcess.stdout, "partial");
assert.deepEqual(partialEvents, [["chunk", "stdout", "partial"], ["line", "stdout", "partial"]]);

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
  // A test process may detach its helper into a separate process group. The
  // timeout owner must still discover and terminate that descendant.
  const descendantSource = "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);";
  const rootSource = `
    const { spawn } = require("node:child_process");
    const descendant = spawn(process.execPath, ["-e", ${JSON.stringify(descendantSource)}], {
      detached: true,
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
  assert.match(result.stderr, /test tests::z_hangs/, "failure details must survive report replacement in the CI log");
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
        testBudgets: [{ prefix: "tests::second", maxMs: 2000 }],
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

const budgetFixtureRoot = mkdtempSync(path.join(os.tmpdir(), "lithe-test-stability-budget-"));
try {
  const linkedWorktree = "watch_context_distinguishes_linked_worktree_git_and_common_directories";
  const linkedBudget = `${linkedWorktree}=30000`;
  const report = path.join(budgetFixtureRoot, "budget.json");
  const options = parseRustTimingArguments([
    "--manifest", path.join(budgetFixtureRoot, "Cargo.toml"), "--report", report,
    "--warn-ms", "10", "--max-ms", "100", "--test-budget", "tests::native_=300",
    "--test-budget", "tests::native=250",
    "--test-budget", linkedBudget,
    "--no-default-features", "--features", "client,server",
  ]);
  assert.equal(options.features, "client,server");
  assert.equal(options.noDefaultFeatures, true);
  assert.throws(() => parseRustTimingArguments(["--manifest", "Cargo.toml", "--features"]));
  assert.throws(() => parseRustTimingArguments(["--manifest", "Cargo.toml", "--features", "--no-default-features"]));
  for (const budget of ["=300", "tests::native_=0", "tests::native_=5", "invalid"]) {
    assert.throws(() => parseRustTimingArguments(["--manifest", "Cargo.toml", "--test-budget", budget]));
  }
  let currentTime = 0;
  const runProcessImpl = async ({ args, onStdoutLine, timeoutMs }) => {
    let stdout = "";
    let durationMs = 0;
    let timedOut = false;
    if (onStdoutLine) {
      assert.ok(args.includes("--no-default-features"));
      assert.equal(args[args.indexOf("--features") + 1], "client,server");
      onStdoutLine(JSON.stringify({ reason: "compiler-artifact", profile: { test: true },
        executable: path.join(budgetFixtureRoot, "fake-tests"), manifest_path: options.manifest,
        target: { name: "budget-fixture" } }));
    } else if (args[0] === "--list") {
      stdout = `tests::unit: test\ntests::native_pass: test\n${linkedWorktree}: test\ntests::native_hang: test\n`;
    } else {
      assert.equal(timeoutMs, args[1] === linkedWorktree ? 30000 : args[1] === "tests::unit" ? 100 : 300);
      timedOut = args[1] === "tests::native_hang";
      durationMs = args[1] === linkedWorktree ? 16000 : args[1] === "tests::unit" ? 30 : timedOut ? 300 : 150;
      stdout = "running 1 test\n";
    }
    currentTime += durationMs;
    return { code: timedOut ? null : 0, timedOut, durationMs, stdout, stderr: "" };
  };
  await assert.rejects(runRustTestsWithTiming(options, { runProcessImpl, now: () => currentTime }), /1 Rust test/);
  const result = JSON.parse(readFileSync(report, "utf8"));
  assert.equal(result.features, "client,server");
  assert.equal(result.noDefaultFeatures, true);
  assert.deepEqual(result.tests.map(({ status, maxMs }) => ({ status, maxMs })), [
    { status: "passed", maxMs: 100 }, { status: "passed", maxMs: 300 },
    { status: "passed", maxMs: 30000 }, { status: "timeout", maxMs: 300 },
  ]);
  // The native pass exceeds the ordinary budget but must remain a passing case
  // in both HTML and JUnit. The hung native case still fails at its own deadline.
  const junit = readFileSync(report.replace(".json", ".junit.xml"), "utf8");
  assert.match(junit, /failures="0"/);
  assert.match(junit, /errors="1"/);
  assert.doesNotMatch(junit, /Performance budget exceeded: 150ms/);
  assert.doesNotMatch(junit, /Performance budget exceeded: 16000ms/);
  assert.match(readFileSync(report.replace(".json", ".html"), "utf8"),
    /<tr data-status="warning" data-search="[^"\n]*tests::native_pass"/);
} finally {
  rmSync(budgetFixtureRoot, { recursive: true, force: true });
}

console.log("Test stability verifier tests passed.");
