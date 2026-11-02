// Offline executable protocol checks. These never launch Lithe or a server.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const tool = fileURLToPath(new URL("./fake-build-tool.mjs", import.meta.url));

function withWorkspace(action) {
  const parent = mkdtempSync(path.join(os.tmpdir(), "lithe-build-protocol-"));
  const workspace = path.join(parent, "workspace with spaces");
  mkdirSync(workspace);
  writeFileSync(path.join(workspace, "acceptance.build.txt"), "saved-buffer-from-editor\n");
  try { action(workspace, parent); }
  finally { rmSync(parent, { recursive: true }); }
}

function run(workspace, args) {
  // Every non-gated fixture invocation owns one bounded child. No test starts
  // the hold mode or its descendant; those belong to future native job tests.
  const result = spawnSync(process.execPath, [tool, ...args], {
    cwd: workspace, timeout: 5_000, maxBuffer: 1024 * 1024,
    encoding: "utf8", windowsHide: true,
  });
  assert.ifError(result.error);
  return result;
}

function events(workspace) {
  return readFileSync(path.join(workspace, ".lithe-acceptance/events.jsonl"), "utf8")
    .trim().split("\n").map(line => JSON.parse(line));
}

test("probe reports a stable version without launching a descendant", () => withWorkspace(workspace => {
  const result = run(workspace, ["--version"]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, "Lithe Build Acceptance 1.0.0\n");
  assert.deepEqual(events(workspace).map(event => event.event), ["started", "finished"]);
  assert.equal(events(workspace)[0].action, "probe");
}));

test("stdout model is input for the unchanged Core jsonStream map", () => withWorkspace(workspace => {
  const result = run(workspace, ["list", "-json", "./..."]);
  assert.equal(result.status, 0);
  const document = JSON.parse(result.stdout);
  assert.equal(document.Module.Path, "fixture-app");
  assert.equal(document.Module.Dir, workspace);
  assert.equal(events(workspace)[0].savedText, "saved-buffer-from-editor\n");
}));

test("output-file model writes only the native-shaped operation destination", () => withWorkspace((workspace, parent) => {
  const state = path.join(parent, "plugin-state", "fixture.plugin");
  mkdirSync(state, { recursive: true });
  const output = path.join(state, "build-unique.model.json");
  const result = run(workspace, ["litheModel", `-PlitheModelOutput=${output}`]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, "");
  const document = JSON.parse(readFileSync(output, "utf8"));
  assert.equal(document.format, "litheBuildModel");
  assert.equal(document.version, 1);
  assert.equal(document.projects[1].path, "nested");
  assert.ok(events(workspace).some(event => event.output === output));
}));

test("relative and non-state output destinations are rejected without creating them", () => withWorkspace((workspace, parent) => {
  for (const output of ["relative.json", path.join(parent, "installed-resource.json")]) {
    const result = run(workspace, ["litheModel", `-PlitheModelOutput=${output}`]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /exclusive plugin-state output file/);
  }
  assert.deepEqual(readdirSync(parent), ["workspace with spaces"]);
}));

test("dependency stdout and output-file retain canonical decoder inputs", () => withWorkspace((workspace, parent) => {
  const stdout = run(workspace, ["list", "-m", "-json", "all"]);
  assert.equal(JSON.parse(stdout.stdout).Path, "fixture-dependency");
  const state = path.join(parent, "plugin-state", "fixture.plugin");
  mkdirSync(state, { recursive: true });
  const output = path.join(state, "build-unique.dependencies.json");
  const file = run(workspace, ["litheDependencies", `-PlitheDependenciesOutput=${output}`]);
  assert.equal(file.status, 0);
  assert.equal(JSON.parse(readFileSync(output, "utf8")).format, "litheDependencies");
}));

test("task preserves literal arguments and the last reviewed replacement marker", () => withWorkspace(workspace => {
  const literal = "argument with spaces and $() characters";
  const result = run(workspace, ["--fixture-marker", "a", "--fixture-marker", "b", "build", literal]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, "controlled task stdout [marker=b]\n");
  assert.equal(result.stderr, "controlled task stderr\n");
  const started = events(workspace)[0];
  assert.equal(started.marker, "b");
  assert.equal(started.argv.at(-1), literal);
}));

test("controlled test emits JUnit input, diagnostics, stderr and a failing exit", () => withWorkspace(workspace => {
  const result = run(workspace, ["test"]);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /src\/main\.rs:1:1: error:/);
  assert.match(result.stdout, /src\/main\.go:1:1:/);
  assert.match(result.stdout, /src\/Main\.java:1: error:/);
  assert.match(result.stderr, /controlled test stderr/);
  const report = readFileSync(path.join(workspace, "build/test-results/test/TEST-fixture.xml"), "utf8");
  assert.match(report, /failures="1"/);
  assert.match(report, /file="src\/main.rs" line="1"/);
  assert.equal(events(workspace).at(-1).exitCode, 1);
}));
