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
  for (const name of ["generate-platform-feature-matrix.mjs", "verify-platform-feature-matrix-change.mjs"]) {
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
