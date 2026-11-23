#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { classifySource, run, runWithCoverage, scanFile } from "./verify-test-stability.mjs";

const scannerSource = readFileSync(new URL("./verify-test-stability.mjs", import.meta.url), "utf8");
const goSource = "package sample\nfunc TestWait(t *testing.T) { time.Sleep(time.Second) }\n";
const rustSource = "#[test]\nfn waits() { thread::sleep(Duration::from_secs(1)); }\n";

function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), "lithe-stability-coverage-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const put = (relative, content) => {
    const target = path.join(root, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, content);
    return target;
  };
  const script = put(".agents/skills/write-stable-tests/scripts/verify-test-stability.mjs", scannerSource);
  const git = (...args) => {
    const result = spawnSync("git", args, { cwd: root, encoding: "utf8", timeout: 5_000 });
    assert.equal(result.error, undefined, String(result.error));
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const cli = (...args) => {
    const result = spawnSync(process.execPath, [script, ...args], {
      cwd: root, encoding: "utf8", timeout: 5_000,
    });
    assert.equal(result.error, undefined, String(result.error));
    assert.equal(result.signal, null, result.stderr);
    return result;
  };
  return { root, put, git, cli };
}

await test("source classification distinguishes Rust rules from uncovered desktop Go tests", { timeout: 5_000 }, () => {
  assert.equal(classifySource("rust/crates/core/src/lib.rs"), "rust");
  for (const source of ["desktop/search_test.go", "desktop/internal/run/run_windows_test.go", "desktop/internal/run/run_darwin_test.go"]) {
    assert.equal(classifySource(source), "uncovered-go");
  }
  for (const source of ["desktop/search.go", "other/sample_test.go", "macos/Tests/Old.swift", "Plugins/mac/Tests/Old.swift", "windows/tauri/src/example.test.ts"]) {
    assert.equal(classifySource(source), null);
    assert.deepEqual(scanFile(source, "gate.wait(); setTimeout(work, 1);"), []);
  }
  assert.deepEqual(scanFile("rust/crates/core/src/lib.rs", rustSource).map(({ rule }) => rule), ["rust-real-sleep"]);
  assert.deepEqual(scanFile("rust/crates/core/src/lib.rs", rustSource, null, "windows").map(({ rule }) => rule), ["rust-real-sleep"]);
});

await test("all platform invocations expose missing Go coverage without changing run's result shape", { timeout: 5_000 }, (t) => {
  const f = fixture(t);
  f.put("desktop/internal/example_test.go", goSource);
  f.put("desktop/internal/editor/textmate/testdata/sample.rs", "#[test]\nfn sample() { assert_eq!(1, 1); }\n");
  f.put("rust/crates/core/src/main.rs", "fn main() {}\n");
  for (const platform of ["all", "macos", "windows"]) {
    const options = { root: f.root, all: true, platform };
    assert.deepEqual(run(options), { violations: [], moved: 0 });
    assert.deepEqual(runWithCoverage(options), {
      violations: [], moved: 0,
      coverage: { rustFiles: [], uncoveredGoFiles: ["desktop/internal/example_test.go"] },
    });
    const result = f.cli("--all", "--platform", platform);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /coverage unavailable for 1 desktop Go test file/);
    assert.match(result.stdout, /DesktopGo timing and race checks/);
    assert.match(result.stdout, /static scan N\/A/);
    assert.doesNotMatch(result.stdout, /check passed/);
  }
});

await test("revision and working-tree classification include tracked and untracked Go tests accurately", { timeout: 10_000 }, (t) => {
  const f = fixture(t);
  f.git("init", "-q");
  f.git("config", "user.name", "Stability Test");
  f.git("config", "user.email", "test@example.invalid");
  f.git("config", "commit.gpgSign", "false");
  f.git("add", ".");
  f.git("commit", "-qm", "baseline");
  const base = f.git("rev-parse", "HEAD");
  f.put("desktop/example_test.go", goSource);
  f.git("add", ".");
  f.git("commit", "-qm", "tracked Go regression");
  const head = f.git("rev-parse", "HEAD");
  f.put("desktop/internal/other_test.go", goSource);
  const revision = runWithCoverage({ root: f.root, base, head, platform: "windows" });
  assert.deepEqual(revision.coverage, { rustFiles: [], uncoveredGoFiles: ["desktop/example_test.go"] });
  const working = runWithCoverage({ root: f.root, platform: "macos" });
  assert.deepEqual(working.coverage, { rustFiles: [], uncoveredGoFiles: ["desktop/internal/other_test.go"] });
});

await test("zero applicable sources are N/A and real Rust violations still fail the CLI", { timeout: 5_000 }, (t) => {
  const f = fixture(t);
  f.put("README.md", "No applicable source files.\n");
  f.put("desktop/internal/editor/textmate/testdata/sample.rs", "#[test]\nfn sample() { assert_eq!(1, 1); }\n");
  const empty = f.cli("--all");
  assert.equal(empty.status, 0, empty.stderr);
  assert.match(empty.stdout, /static scan N\/A/);
  assert.doesNotMatch(empty.stdout, /check passed/);

  // Excluding a data-only sample from coverage must not exempt its patterns.
  f.put("desktop/internal/editor/textmate/testdata/sample.rs", rustSource);
  const sampleFailure = f.cli("--all");
  assert.equal(sampleFailure.status, 1);
  assert.match(sampleFailure.stderr, /\[rust-real-sleep\]/);
  f.put("desktop/internal/editor/textmate/testdata/sample.rs", "fn main() {}\n");

  f.put("desktop/example_test.go", goSource);
  f.put("rust/crates/core/src/lib.rs", rustSource);
  const failed = f.cli("--all");
  assert.equal(failed.status, 1);
  assert.match(failed.stdout, /coverage unavailable for 1 desktop Go test file/);
  assert.match(failed.stderr, /\[rust-real-sleep\]/);
  assert.doesNotMatch(failed.stdout, /check passed/);
});

await test("symlinked CLI invocation executes the scanner instead of exiting 0", { timeout: 5_000 }, (t) => {
  const f = fixture(t);
  f.put("desktop/example_test.go", goSource);
  f.put("rust/crates/core/src/lib.rs", rustSource);
  const link = path.join(f.root, "verify-link.mjs");
  try {
    symlinkSync(path.join(f.root, ".agents/skills/write-stable-tests/scripts/verify-test-stability.mjs"), link);
  } catch (error) {
    if (process.platform === "win32" && ["EPERM", "ENOTSUP"].includes(error.code)) {
      t.skip(`symlinks unavailable on this host (${error.code})`);
      return;
    }
    throw error;
  }
  const result = spawnSync(process.execPath, [link, "--all"], { cwd: f.root, encoding: "utf8", timeout: 5_000 });
  assert.equal(result.error, undefined, String(result.error));
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /\[rust-real-sleep\]/);
  assert.match(result.stdout, /coverage unavailable for 1 desktop Go test file/);
});
