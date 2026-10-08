#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

const repository = resolve(import.meta.dirname, "..");
function fixture(t) {
  const root = mkdtempSync(resolve(tmpdir(), "lithe-matrix-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(resolve(root, "scripts"));
  for (const name of ["generate-platform-feature-matrix.mjs", "verify-platform-feature-matrix-change.mjs", "classify-ci-changes.sh"]) {
    cpSync(resolve(repository, "scripts", name), resolve(root, "scripts", name));
  }
  const directory = resolve(root, "shared/platform-feature-matrix");
  mkdirSync(resolve(directory, "features"), { recursive: true });
  cpSync(resolve(repository, "shared/platform-feature-matrix/metadata.json"), resolve(directory, "metadata.json"));
  writeFileSync(resolve(root, "evidence.txt"), "fixture");
  const entry = { implementationStatus: "implemented", verificationStatus: "pending", evidence: ["evidence.txt"] };
  const feature = { id: "sample", area: "Test", group: "Test", capability: "Sample", owner: "Test", verification: "Run fixture", macos: entry, windows: entry };
  const save = (value = feature, name = "sample") => writeFileSync(resolve(directory, "features", `${name}.json`), JSON.stringify(value, null, 2) + "\n");
  save();
  const run = (script, args = [], env = {}) => spawnSync(process.execPath, [resolve(root, "scripts", script), ...args], {
    cwd: root, encoding: "utf8", timeout: 5_000, env: { ...process.env, MATRIX_UPDATE_EXEMPT: "false", ...env },
  });
  const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8", timeout: 5_000 });
  return { root, directory, feature, save, run, git };
}
const succeeded = (result) => {
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
};
const failed = (result, message) => {
  assert.ifError(result.error);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, message);
};

// Reuse the classifier assertions, but expose each regression as a timed Node
// test so the matrix workflow and local JUnit reports show individual cases.
for (const name of [
  "feature-record", "add-feature-record", "delete-feature-record", "feature-metadata",
  "nested-feature-record", "unknown-shared-path", "swift-and-feature-record",
  "windows-and-feature-record", "rust-and-feature-record", "fixture-and-feature-record",
  "rename-feature-record", "rename-feature-to-fixture", "rename-fixture-to-feature",
  "delete-shared-fixture",
  "shared-editor", "macos-editor", "editor-build", "editor-boundary-verifier",
  "web-workspace", "bun-lock", "bun-config", "windows-worker-build",
  "windows-worker-verifier", "unknown-frontend", "update-source", "process-runner",
  "rollback-test", "shared-test-gate", "editor-and-rust", "editor-and-database",
  "swift-and-database",
  "windows-java-view", "macos-java-view", "java-documentation", "jdt-transport",
  "real-jdt-test", "java-comment", "rename-swift-source", "rename-windows-to-swift",
  "rename-to-unknown", "macos-ci",
  "windows-selector", "windows-selector-test", "windows-suite-registry", "ci-report-tool", "ci-orchestration-test",
]) {
  test(`CI classifier: ${name}`, { timeout: 15_000 }, () => {
    succeeded(spawnSync("bash", [resolve(repository, "scripts/test-classify-ci-changes.sh"), name], {
      cwd: repository, encoding: "utf8", timeout: 10_000,
    }));
  });
}

test("macOS CI runs the selected rollback disk image suite once", { timeout: 5_000 }, () => {
  const workflow = readFileSync(resolve(repository, ".github/workflows/ci-macos.yml"), "utf8");
  assert.ok(workflow.includes("macos_rollback: ${{ steps.classify.outputs.macos_rollback }}"));
  assert.ok(workflow.includes('echo "macos_rollback=true"'));
  assert.equal((workflow.match(/--filter StableRollbackDiskImageIntegrationTests/g) ?? []).length, 1);
  assert.equal((workflow.match(/--filter fullSignedDiskImageStagesWithoutChangingInstalledApp/g) ?? []).length, 0);
  assert.match(workflow, /name: Run stable rollback disk image integration tests\n\s+if: needs\.changes\.outputs\.macos_rollback == 'true'/);
  // The broad unit invocation must continue excluding the integration suite;
  // otherwise a conditional dedicated step still leaves an unconditional copy.
  assert.ok(workflow.includes("--skip StableRollbackDiskImageIntegrationTests"));
});

test("macOS classification rejects missing and invalid selection outputs", { timeout: 15_000 }, (t) => {
  const root = mkdtempSync(resolve(tmpdir(), "lithe-ci-summary-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const workflow = readFileSync(resolve(repository, ".github/workflows/ci-macos.yml"), "utf8");
  const summary = workflow.split("      - name: Summarize selected lanes\n")[1]
    .split("\n  swift-tests:")[0].split("        run: |\n")[1]
    .split("\n").map((line) => line.replace(/^          /, "")).join("\n");
  const env = {
    ...process.env, GITHUB_STEP_SUMMARY: resolve(root, "summary.md"),
    SWIFT: "true", RUST_CORE: "false", MACOS_RELEASE: "false", RUST_COMMENTS: "false",
    METADATA: "false", GIT_VALIDATION: "false", MACOS_ROLLBACK: "false",
    PLUGINS: "false", SWIFT_DATABASE: "false", RUST_DATABASE: "false", EDITOR_TESTS: "false",
  };
  const run = (overrides) => spawnSync("bash", ["-e", "-c", summary], {
    cwd: repository, encoding: "utf8", timeout: 5_000, env: { ...env, ...overrides },
  });
  succeeded(run({}));
  failed(run({ MACOS_ROLLBACK: "" }), /Invalid or missing macOS CI selection/);
  failed(run({ MACOS_ROLLBACK: "unknown" }), /Invalid or missing macOS CI selection/);
  failed(run({ SWIFT: "unknown" }), /Invalid or missing macOS CI selection/);
});

test("lightweight feature records retain path diagnostics and reject invalid matrix content", { timeout: 20_000 }, (t) => {
  const f = fixture(t);
  f.git("init", "-q");
  f.git("config", "user.name", "Matrix Fixture");
  f.git("config", "user.email", "matrix@example.invalid");
  const commit = () => {
    f.git("add", ".");
    f.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture");
    return f.git("rev-parse", "HEAD").trim();
  };
  const base = commit();
  for (const [feature, error] of [
    [{ ...f.feature, id: "different" }, /ID must match/],
    [{ ...f.feature, windows: { ...f.feature.windows, verificationStatus: "unknown" } }, /invalid windows entry/],
    [{ ...f.feature, macos: { ...f.feature.macos, evidence: ["missing.txt"] } }, /missing evidence/],
  ]) {
    f.save(feature);
    const head = commit();
    const classified = spawnSync("bash", [resolve(f.root, "scripts/classify-ci-changes.sh"), base, head], {
      cwd: f.root, encoding: "utf8", timeout: 5_000,
    });
    succeeded(classified);
    assert.ok(classified.stdout.trim().split("\n").every((line) => /^[a-z_]+=false$/.test(line)), classified.stdout);
    assert.match(classified.stderr, /path=shared\/platform-feature-matrix\/features\/sample\.json .*rule=feature-record selected=none/);
    failed(f.run("generate-platform-feature-matrix.mjs", ["--check"]), error);
  }

  // An earlier path's Swift selection must not be attributed to the later
  // descriptive record; the final outputs must still keep the Swift lane.
  mkdirSync(resolve(f.root, "macos/Sources"), { recursive: true });
  writeFileSync(resolve(f.root, "macos/Sources/fixture.swift"), "// fixture\n");
  f.save({ ...f.feature, capability: "Updated" });
  const classified = spawnSync("bash", [resolve(f.root, "scripts/classify-ci-changes.sh"), base, commit()], {
    cwd: f.root, encoding: "utf8", timeout: 5_000,
  });
  succeeded(classified);
  assert.match(classified.stdout, /^swift=true$/m);
  assert.match(classified.stderr, /path=macos\/Sources\/fixture\.swift .*selected=swift/);
  assert.match(classified.stderr, /path=shared\/platform-feature-matrix\/features\/sample\.json .*rule=feature-record selected=none/);
  succeeded(f.run("generate-platform-feature-matrix.mjs", ["--check"]));
});

test("generation combines independent capabilities deterministically and escapes HTML", { timeout: 15_000 }, (t) => {
  const f = fixture(t);
  f.save({ ...f.feature, id: "another", capability: '<script>alert("x")</script>' }, "another");
  succeeded(f.run("generate-platform-feature-matrix.mjs"));
  const out = resolve(f.root, ".artifacts/platform-feature-matrix");
  const source = JSON.parse(readFileSync(resolve(out, "platform-feature-matrix.json")));
  assert.deepEqual(source.features.map(({ id }) => id), ["another", "sample"]);
  assert.deepEqual(source.features[1], f.feature);
  const html = readFileSync(resolve(out, "index.html"), "utf8");
  assert.ok(html.includes("&lt;script&gt;"));
  assert.ok(!html.includes("<script>"));
  const names = ["index.html", "platform-parity-matrix.md", "platform-parity-matrix.csv", "platform-feature-matrix.json"];
  const before = names.map((name) => readFileSync(resolve(out, name), "utf8"));
  succeeded(f.run("generate-platform-feature-matrix.mjs"));
  assert.deepEqual(names.map((name) => readFileSync(resolve(out, name), "utf8")), before);
  const custom = resolve(f.root, "site/matrix");
  succeeded(f.run("generate-platform-feature-matrix.mjs", ["--output-dir", custom]));
  assert.equal(readFileSync(resolve(custom, "index.html"), "utf8"), html);
});

test("validation needs no committed views and rejects invalid ID, status and evidence", { timeout: 15_000 }, (t) => {
  const f = fixture(t);
  succeeded(f.run("generate-platform-feature-matrix.mjs", ["--check"]));
  f.save({ ...f.feature, id: "different" });
  failed(f.run("generate-platform-feature-matrix.mjs", ["--check"]), /ID must match/);
  f.save({ ...f.feature, windows: { ...f.feature.windows, verificationStatus: "unknown" } });
  failed(f.run("generate-platform-feature-matrix.mjs", ["--check"]), /invalid windows entry/);
  f.save({ ...f.feature, macos: { ...f.feature.macos, evidence: ["missing.txt"] } });
  failed(f.run("generate-platform-feature-matrix.mjs", ["--check"]), /missing evidence/);
});

test("gate rejects metadata, formatting and date-only edits, accepts capability changes and reviewed exemption", { timeout: 20_000 }, (t) => {
  const f = fixture(t);
  f.git("init", "-q");
  f.git("config", "user.name", "Matrix Fixture");
  f.git("config", "user.email", "matrix@example.invalid");
  const commit = () => { f.git("add", "."); f.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture"); return f.git("rev-parse", "HEAD").trim(); };
  const base = commit();
  mkdirSync(resolve(f.root, "macos/Sources"), { recursive: true });
  writeFileSync(resolve(f.root, "macos/Sources/fixture.swift"), "// fixture\n");
  const metadata = resolve(f.directory, "metadata.json");
  writeFileSync(metadata, readFileSync(metadata, "utf8").replace("2026-09-29", "2026-09-30"));
  f.save({ ...f.feature, lastReviewed: "2026-10-02" });
  const dates = commit();
  failed(f.run("verify-platform-feature-matrix-change.mjs", [base, dates]), /without a substantive capability update/);
  succeeded(f.run("verify-platform-feature-matrix-change.mjs", [base, dates], { MATRIX_UPDATE_EXEMPT: "true" }));
  // Reordering and pretty-printing keys must not masquerade as a capability change.
  writeFileSync(resolve(f.directory, "features/sample.json"), JSON.stringify(Object.fromEntries(Object.entries(f.feature).reverse())));
  const formatting = commit();
  failed(f.run("verify-platform-feature-matrix-change.mjs", [base, formatting]), /without a substantive capability update/);
  f.save({ ...f.feature, capability: "Updated behavior" });
  const updated = commit();
  succeeded(f.run("verify-platform-feature-matrix-change.mjs", [base, updated]));
  succeeded(f.run("verify-platform-feature-matrix-change.mjs", [updated, updated]));
  failed(f.run("verify-platform-feature-matrix-change.mjs", ["missing-revision", updated]), /fatal/);
});

test("two branches changing different capabilities merge without generated-view conflicts", { timeout: 15_000 }, (t) => {
  const f = fixture(t);
  f.git("init", "-q");
  f.git("config", "user.name", "Matrix Fixture");
  f.git("config", "user.email", "matrix@example.invalid");
  const commit = () => { f.git("add", "shared", "scripts", "evidence.txt"); f.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture"); };
  commit();
  f.git("branch", "other");
  f.save({ ...f.feature, capability: "Updated original" });
  commit();
  const first = f.git("rev-parse", "HEAD").trim();
  f.git("checkout", "-q", "other");
  f.save({ ...f.feature, id: "second", capability: "Independent feature" }, "second");
  commit();
  f.git("-c", "commit.gpgsign=false", "merge", "--no-edit", first);
  succeeded(f.run("generate-platform-feature-matrix.mjs"));
  const merged = JSON.parse(readFileSync(resolve(f.root, ".artifacts/platform-feature-matrix/platform-feature-matrix.json"), "utf8"));
  assert.deepEqual(merged.features.map(({ capability }) => capability), ["Updated original", "Independent feature"]);
});
