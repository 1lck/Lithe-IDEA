import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "bun:test";
import { readChanges, selectSuites } from "./select-windows-ci-tests.mjs";

const prefix = "windows/tauri/src/";
const groups = {
  platform: { tests: ["src/platform"] },
  editor: { tests: ["src/features/editor/editor.test.ts"] },
  git: { tests: ["src/features/git/git.test.ts"] },
  terminal: { tests: ["src/features/terminal/terminal.test.ts"] },
  settings: { tests: ["src/features/settings/settings.test.ts"] },
  tabs: { tests: ["src/features/tabs/tabs.test.ts"] },
};

function fixture(check: (root: string, put: (path: string, text: string) => void) => void) {
  const root = mkdtempSync(resolve(tmpdir(), "lithe-ci-selection-"));
  const put = (path: string, text: string) => {
    const target = resolve(root, prefix + path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, text);
  };
  try {
    put("platform/routing.test.ts", "export {};");
    put("features/editor/model.ts", "export const model = 1;");
    put("features/editor/index.ts", 'export { model } from "./model";');
    put("features/editor/editor.test.ts", 'import { model } from "./model";');
    put("features/git/git.test.ts", 'const model = import("@/features/editor/index");');
    put("features/terminal/terminal.test.ts", "export {};");
    put("features/settings/settings.test.ts", "export {};");
    put("features/tabs/tabs.test.ts", 'const source = new URL("../editor/model.ts", import.meta.url);');
    check(root, put);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function selection(root: string, path: string, status = "M") {
  return selectSuites({ root, groups, changes: [{ status, path }] });
}

test("local changes include feature suites, re-exports, dynamic literal imports and source readers", () => fixture((root) => {
  const plan = selection(root, prefix + "features/editor/model.ts");
  assert.equal(plan.full, false);
  for (const id of ["platform", "editor", "git", "tabs"]) assert.ok(plan.selected[id].length, id);
  for (const id of ["terminal", "settings"]) assert.equal(plan.selected[id].length, 0, id);
}));

test("a registered test edit keeps unrelated feature suites skipped", () => fixture((root) => {
  const plan = selection(root, prefix + "features/terminal/terminal.test.ts");
  assert.ok(plan.selected.terminal.length);
  assert.equal(plan.selected.git.length, 0);
  assert.equal(plan.selected.editor.length, 0);
  assert.deepEqual(plan.additional, []);
}));

test("new unregistered tests are scheduled in independent processes", () => fixture((root, put) => {
  put("features/terminal/new.test.ts", 'import "../editor/model";');
  const path = prefix + "features/terminal/new.test.ts";
  const plan = selection(root, path, "A");
  assert.equal(plan.full, false);
  assert.deepEqual(plan.additional, [path]);
  assert.ok(plan.selected.terminal.length);
}));

test("deletions conservatively preserve all existing suites", () => fixture((root) => {
  const plan = selection(root, prefix + "features/editor/model.ts", "D");
  assert.equal(plan.full, true);
  for (const reasons of Object.values(plan.selected)) assert.ok(reasons.length);
}));

test("rename endpoints cannot lose the old feature's validation", () => fixture((root) => {
  const plan = selectSuites({ root, groups, changes: [
    { status: "D", path: prefix + "features/editor/model.ts" },
    { status: "A", path: prefix + "features/terminal/model.ts" },
  ] });
  assert.equal(plan.full, true);
  assert.ok(plan.selected.editor.length);
  assert.ok(plan.selected.terminal.length);
}));

for (const path of [
  "package.json", "bun.lock", "windows/tauri/tsconfig.json", "windows/tauri/src-tauri/src/main.rs",
  "shared/fixtures/lsp/result.json", "frontend/editor/src/model.ts", "scripts/windows-ci-test-suites.json",
  prefix + "utils/shared.ts", prefix + "features/editor/model.d.ts", prefix + "features/editor/theme.css",
  prefix + "features/not-yet-owned/model.ts",
]) test(`global, native, asset or unowned input selects full coverage: ${path}`, () => fixture((root) => {
  const plan = selection(root, path);
  assert.equal(plan.full, true);
  assert.equal(Object.values(plan.selected).filter((reasons) => reasons.length).length, Object.keys(groups).length);
}));

test("documentation and canonical capability records do not enlarge a known frontend change", () => fixture((root) => {
  const plan = selectSuites({ root, groups, changes: [
    { status: "M", path: prefix + "features/terminal/terminal.test.ts" },
    { status: "M", path: "docs/ci-builds.md" },
    { status: "M", path: "shared/platform-feature-matrix/features/terminal.json" },
    { status: "M", path: "macos/Sources/Lithe/Views/Terminal.swift" },
  ] });
  assert.equal(plan.full, false);
  assert.equal(plan.selected.editor.length, 0);
}));

test("manual and main validation selects every registered suite", () => fixture((root) => {
  const plan = selectSuites({ root, groups, full: true });
  assert.equal(plan.full, true);
  for (const reasons of Object.values(plan.selected)) assert.ok(reasons.length);
}));

test("dependency scan failure falls back instead of silently skipping consumers", () => fixture((root, put) => {
  put("features/editor/model.ts", "export const = ;");
  const plan = selection(root, prefix + "features/terminal/terminal.test.ts");
  assert.equal(plan.full, true);
  assert.match(plan.reasons.join("\n"), /Dependency scan failed/);
}));

test("computed module targets retain their consumers as baseline checks", () => fixture((root, put) => {
  put("features/terminal/terminal.test.ts", "const target = getTarget(); const module = import(target);");
  const plan = selection(root, prefix + "features/settings/settings.test.ts");
  assert.equal(plan.full, false);
  assert.ok(plan.selected.terminal.length);
  assert.equal(plan.selected.editor.length, 0);
}));

test("literal Vite glob inputs participate in dependency selection", () => fixture((root, put) => {
  put("features/git/git.test.ts", 'const inputs = import.meta.glob("../editor/*.ts");');
  const plan = selection(root, prefix + "features/editor/model.ts");
  assert.equal(plan.full, false);
  assert.ok(plan.selected.git.some((reason: string) => reason.includes("Dependent test")));
}));

test("an empty registered suite fails before writing a passing plan", () => fixture((root) => {
  assert.throws(() => selectSuites({ root, groups: { missing: { tests: ["src/features/missing"] } }, full: true }), /no matching tests/);
}));

test("missing comparison commits fail explicitly", () => {
  assert.throws(() => readChanges(resolve(import.meta.dirname, ".."), "", "HEAD"), /missing/);
  assert.throws(() => readChanges(resolve(import.meta.dirname, ".."), "HEAD", ""), /missing/);
});

test("Git diff preserves whitespace paths and emits both rename endpoints", () => fixture((root, put) => {
  const git = (...args: string[]) => {
    const result = spawnSync("git", ["-c", "core.hooksPath=disabled-hooks", "-c", "commit.gpgsign=false", ...args], {
      cwd: root, encoding: "utf8", timeout: 2000,
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git("init", "-q");
  git("config", "user.name", "CI Test");
  git("config", "user.email", "ci@example.invalid");
  put("features/editor/old model.ts", "export const value = 1;");
  git("add", ".");
  git("commit", "-qm", "fixture base");
  const base = git("rev-parse", "HEAD");
  git("mv", prefix + "features/editor/old model.ts", prefix + "features/terminal/new model.ts");
  git("commit", "-qm", "fixture rename");
  const changes = readChanges(root, base, "HEAD");
  assert.deepEqual(changes, [
    { status: "D", path: prefix + "features/editor/old model.ts" },
    { status: "A", path: prefix + "features/terminal/new model.ts" },
  ]);
  assert.equal(selectSuites({ root, groups, changes }).full, true);
}), 10000);

test("real repository terminal changes keep Java, document and debugger suites skipped", () => {
  const plan = selectSuites({ changes: [{ status: "M", path: prefix + "features/terminal/utils/terminal-keyboard.ts" }] });
  assert.equal(plan.full, false);
  assert.ok(plan.selected.terminal.length);
  for (const id of ["java_navigation", "documents", "debug_events", "debug_service", "spring"]) assert.equal(plan.selected[id].length, 0, id);
}, 5000);
