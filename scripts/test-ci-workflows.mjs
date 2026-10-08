#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { parseArguments, run } from "../.agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs";
import { toolReport, budgetFailures, reportTools } from "./report-ci-tool-tests.mjs";

const repository = resolve(import.meta.dirname, "..");
const macos = readFileSync(resolve(repository, ".github/workflows/ci-macos.yml"), "utf8");
const windows = readFileSync(resolve(repository, ".github/workflows/ci-windows.yml"), "utf8");

test("Windows suite registry is wired to conditional steps without changing isolation seeds", { timeout: 5_000 }, () => {
  const { groups } = JSON.parse(readFileSync(resolve(repository, "scripts/windows-ci-test-suites.json"), "utf8"));
  const frontend = job(windows, "frontend");
  for (const [id, group] of Object.entries(groups)) {
    const step = frontend.split(`      - name: ${group.step}\n`)[1]?.split("\n      - name: ")[0];
    assert.ok(step, `Missing ${id} step`);
    assert.ok(step.includes(`if: steps.tests.outputs.${id} == 'true'`), `Unconditional suite ${id}`);
    for (const path of group.tests) assert.ok(step.includes(path), `Registry/workflow mismatch: ${id} ${path}`);
  }
  assert.equal((frontend.match(/foreach \(\$seed in @\(1, 3, 7\)\)/g) ?? []).length, 2);
  assert.equal((frontend.match(/foreach \(\$seed in @\(1, 3\)\)/g) ?? []).length, 1);
  assert.match(frontend, /name: Check out source\n\s+uses: actions\/checkout@v7\n\s+with:\n\s+fetch-depth: 0/);
  assert.match(frontend, /name: Check Windows frontend types\n\s+working-directory:/);
  assert.match(frontend, /name: Verify Windows boundaries\n\s+shell:/);
  assert.match(frontend, /name: Upload optional PHP plugin package\n\s+if: steps.tests.outputs.optional_plugins == 'true'/);
});

test("CI tool reports enforce the same hard budgets they display", { timeout: 5_000 }, () => {
  const ordinary = toolReport([{ name: "tool regression", status: "passed", durationMs: 16000 }]);
  assert.equal(budgetFailures(ordinary).length, 1);
  const integrationName = "real Rust binaries honor the filter, report selected timings and fail empty matches";
  const integration = toolReport([{ name: integrationName, status: "passed", durationMs: 16000 }]);
  assert.equal(budgetFailures(integration).length, 0);
  integration.tests[0].durationMs = 60000;
  assert.equal(budgetFailures(integration).length, 1);
  for (const status of ["failed", "error", "timeout", "incomplete", "unknown"]) {
    assert.equal(budgetFailures(toolReport([{ name: "broken", status, durationMs: 1 }])).length, 1);
  }
  assert.throws(() => toolReport([]), /Missing/);
});

test("an over-budget CI tool writes diagnostics and then fails the workflow", { timeout: 5_000 }, (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "lithe-ci-budget-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(resolve(directory, "ci-workflows.junit.xml"), '<testsuite><testcase name="slow tool" time="16"/></testsuite>');
  assert.throws(() => reportTools(directory), /exceeded their budget/);
  assert.ok(existsSync(resolve(directory, "ci-workflows.html")));
  assert.match(readFileSync(resolve(directory, "ci-workflows.junit.xml"), "utf8"), /performance-budget/);
  assert.ok(macos.includes("run: node scripts/report-ci-tool-tests.mjs"));
});

test("CI tooling dashboard aggregates every current lane", { timeout: 5_000 }, (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "lithe-ci-dashboard-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  for (const [lane, name] of [["ci-workflows", "workflow scenario"], ["sparkle-baseline", "download scenario"]]) {
    writeFileSync(resolve(directory, `${lane}.junit.xml`), `<testsuite><testcase name="${name}" time="0.01"/></testsuite>`);
  }
  reportTools(directory);
  const html = readFileSync(resolve(directory, "index.html"), "utf8");
  assert.ok(html.includes("workflow scenario"));
  assert.ok(html.includes("download scenario"));
});

test("host PHP isolation does not require an unselected package and still rejects source and dist leaks", { timeout: 10_000 }, (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "lithe-ci-php-isolation-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  for (const path of ["scripts", "windows/tauri/src", "windows/tauri/dist"]) mkdirSync(resolve(directory, path), { recursive: true });
  const verifier = resolve(directory, "scripts/verify-windows-plugin-isolation.mjs");
  writeFileSync(verifier, readFileSync(resolve(repository, "scripts/verify-windows-plugin-isolation.mjs")));
  const source = resolve(directory, "windows/tauri/src/app.ts");
  writeFileSync(source, "export const app = 1;");
  const invoke = (...args) => spawnSync(process.execPath, [verifier, ...args], { cwd: directory, encoding: "utf8", timeout: 2_000 });
  assert.equal(invoke("--host-only", "--dist").status, 0);
  assert.notEqual(invoke().status, 0, "Default validation still requires the optional package");
  writeFileSync(source, 'import "@lithe/php";');
  assert.notEqual(invoke("--host-only", "--dist").status, 0);
  writeFileSync(source, "export const app = 1;");
  writeFileSync(resolve(directory, "windows/tauri/dist/app.js"), 'const languageServer = "intelephense";');
  assert.notEqual(invoke("--host-only", "--dist").status, 0);
  assert.ok(windows.includes("node scripts/verify-windows-plugin-isolation.mjs --host-only --dist"));
});

function job(workflow, name) {
  const contents = workflow.split(`\n  ${name}:\n`)[1];
  assert.ok(contents, `Missing job ${name}`);
  return contents.split(/\n  [a-z][a-z-]*:\n/)[0];
}

function gateScript(workflow, name) {
  return job(workflow, name).split("        run: |\n")[1]
    .split("\n").map((line) => line.replace(/^          /, "")).join("\n");
}

function gate(name, env) {
  const environment = { ...process.env, ...env };
  // Gate fixtures must not source a developer's shell integration or rc file.
  delete environment.BASH_ENV;
  delete environment.ENV;
  return spawnSync("bash", ["-e", "-u", "-c", gateScript(macos, name)], {
    cwd: repository, env: environment, encoding: "utf8", timeout: 2_000,
  });
}

test("selected Swift suites share one compilation and preserve their check names", { timeout: 5_000 }, () => {
  const swift = job(macos, "swift-tests");
  assert.equal((macos.match(/test-macos\.sh list/g) ?? []).length, 1);
  assert.match(swift, /if: needs.changes.outputs.swift == 'true' \|\| needs.changes.outputs.plugins == 'true' \|\| needs.changes.outputs.swift_database == 'true'/);
  for (const [name, flag] of [
    ["Run Swift unit tests", "swift"], ["Run plugin-focused Swift tests", "plugins"],
    ["Build and verify official plugin packages", "plugins"], ["Run database-focused Swift tests", "swift_database"],
  ]) {
    assert.ok(swift.includes(`name: ${name}\n        if: needs.changes.outputs.${flag} == 'true'`));
  }
  for (const name of ["macOS CI gate", "Plugin CI gate", "Database CI gate"]) {
    assert.ok(macos.includes(`name: ${name}`));
  }
  assert.equal(existsSync(resolve(repository, ".github/workflows/ci-plugins.yml")), false);
  assert.equal(existsSync(resolve(repository, ".github/workflows/ci-database.yml")), false);
  // PHP's isolated suite must not also run inside the main Swift invocation.
  assert.ok(job(macos, "plugin-gate").includes("if: always() && (needs.changes.result != 'success' || needs.changes.outputs.plugins == 'true')"));
  assert.ok(job(macos, "database-gate").includes("if: always() && (needs.changes.result != 'success' || needs.changes.outputs.swift_database == 'true' || needs.changes.outputs.rust_database == 'true')"));
  assert.ok(swift.includes("--skip '([Pp]lugin|LitheGoSupportModuleTests|LithePhpSupportModuleTests|LinuxDo)'"));
});

test("macOS gate rejects cancelled, failed or skipped selected work and dependent gates", { timeout: 10_000 }, () => {
  const valid = {
    CHANGES_RESULT: "success", SWIFT_SELECTED: "true", SWIFT_RESULT: "success",
    RUST_CORE_SELECTED: "false", RUST_CORE_RESULT: "skipped",
    RELEASE_SELECTED: "false", RELEASE_RESULT: "skipped",
    PLUGIN_SELECTED: "true", DATABASE_SELECTED: "true",
    PLUGIN_GATE_RESULT: "success", DATABASE_GATE_RESULT: "success",
  };
  assert.equal(gate("gate", valid).status, 0);
  for (const value of ["failure", "cancelled", "skipped"]) {
    for (const key of ["CHANGES_RESULT", "SWIFT_RESULT", "PLUGIN_GATE_RESULT", "DATABASE_GATE_RESULT"]) {
      assert.notEqual(gate("gate", { ...valid, [key]: value }).status, 0, `${key}=${value}`);
    }
  }
  assert.equal(gate("gate", { ...valid, SWIFT_SELECTED: "false", SWIFT_RESULT: "skipped" }).status, 0);
  assert.notEqual(gate("gate", { ...valid, SWIFT_SELECTED: "false" }).status, 0);
  for (const lane of ["PLUGIN", "DATABASE"]) {
    assert.equal(gate("gate", { ...valid, [`${lane}_SELECTED`]: "false", [`${lane}_GATE_RESULT`]: "skipped" }).status, 0);
    assert.notEqual(gate("gate", { ...valid, [`${lane}_SELECTED`]: "false" }).status, 0);
  }
  for (const lane of ["RUST_CORE", "RELEASE"]) {
    assert.equal(gate("gate", { ...valid, [`${lane}_SELECTED`]: "true", [`${lane}_RESULT`]: "success" }).status, 0);
    for (const result of ["failure", "cancelled", "skipped"]) {
      assert.notEqual(gate("gate", { ...valid, [`${lane}_SELECTED`]: "true", [`${lane}_RESULT`]: result }).status, 0);
    }
  }
});

test("plugin gate uses the shared Swift job only when plugin validation is selected", { timeout: 5_000 }, () => {
  for (const result of ["success", "failure", "cancelled", "skipped"]) {
    const env = { CHANGES_RESULT: "success", PLUGIN_SELECTED: "true", PLUGIN_RESULT: result };
    assert.equal(gate("plugin-gate", env).status === 0, result === "success");
    assert.equal(gate("plugin-gate", { ...env, PLUGIN_SELECTED: "false" }).status, 0);
    assert.notEqual(gate("plugin-gate", { ...env, CHANGES_RESULT: "failure" }).status, 0);
    assert.notEqual(gate("plugin-gate", { ...env, PLUGIN_SELECTED: "" }).status, 0);
    assert.notEqual(gate("plugin-gate", { ...env, PLUGIN_SELECTED: "unknown" }).status, 0);
  }
});

test("database gate enforces selected Swift and Rust scopes independently", { timeout: 10_000 }, () => {
  for (const swift of ["true", "false"]) {
    for (const rust of ["true", "false"]) {
      const valid = {
        CHANGES_RESULT: "success", SWIFT_DATABASE_SELECTED: swift, RUST_DATABASE_SELECTED: rust,
        SWIFT_DATABASE_RESULT: swift === "true" ? "success" : "skipped",
        RUST_DATABASE_RESULT: rust === "true" ? "success" : "skipped",
      };
      assert.equal(gate("database-gate", valid).status, 0);
      assert.notEqual(gate("database-gate", { ...valid, SWIFT_DATABASE_SELECTED: "" }).status, 0);
      assert.notEqual(gate("database-gate", { ...valid, RUST_DATABASE_SELECTED: "unknown" }).status, 0);
      for (const lane of ["SWIFT_DATABASE", "RUST_DATABASE"]) {
        if (valid[`${lane}_SELECTED`] !== "true") continue;
        for (const result of ["failure", "cancelled", "skipped"]) {
          assert.notEqual(gate("database-gate", { ...valid, [`${lane}_RESULT`]: result }).status, 0);
        }
      }
      if (swift === "false") {
        // A different selected Swift suite can legitimately have used this job.
        assert.equal(gate("database-gate", { ...valid, SWIFT_DATABASE_RESULT: "success" }).status, 0);
      }
    }
  }
});

test("shared editor tests run once on Linux while native hosts retain their validation", { timeout: 5_000 }, () => {
  assert.equal((macos.match(/--working-directory frontend\/editor/g) ?? []).length, 1);
  assert.equal((windows.match(/--working-directory frontend\/editor/g) ?? []).length, 1);
  assert.match(windows, /name: Test shared editor for a standalone manual run\n\s+if: github.event_name == 'workflow_dispatch'/);
  assert.match(windows, /name: Test dependency cache tooling for a standalone manual run\n\s+if: github.event_name == 'workflow_dispatch'/);
  const changes = job(macos, "changes");
  assert.match(changes, /name: Test shared editor source model once\n\s+if: steps.classify.outputs.editor_tests == 'true'/);
  assert.ok(job(macos, "release-build").includes("probe-macos-monaco.sh --workbench-tests"));
  assert.ok(job(windows, "frontend").includes("bun run typecheck"));
});

test("real JDT runs only its named integration module with existing bounded deadlines", { timeout: 5_000 }, () => {
  const jdt = job(windows, "real-jdt");
  assert.ok(jdt.includes("--test-filter lsp::interface::engine::real_jdt_tests::"));
  assert.ok(jdt.includes("--build-timeout-ms 600000"));
  assert.ok(jdt.includes("--suite-timeout-ms 1200000"));
  assert.ok(jdt.includes("--test-budget lsp::interface::engine::real_jdt_tests::real_jdtls_discovers_builds_and_launches_java_25_entrypoints=600000"));
});

test("Rust filter rejects missing values and keeps the default full suite", { timeout: 5_000 }, () => {
  assert.equal(parseArguments(["--manifest", "rust/Cargo.toml"]).testFilter, null);
  for (const args of [[], [""], ["--report", "report.json"]]) {
    assert.throws(() => parseArguments(["--manifest", "rust/Cargo.toml", "--test-filter", ...args]), /nonempty test-name substring/);
  }
});

test("real Rust binaries honor the filter, report selected timings and fail empty matches", { timeout: 60_000 }, async (t) => {
  const root = mkdtempSync(resolve(tmpdir(), "lithe-ci-rust-filter-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(resolve(root, "src"));
  writeFileSync(resolve(root, "Cargo.toml"), '[package]\nname = "ci-filter-fixture"\nversion = "0.1.0"\nedition = "2021"\n');
  writeFileSync(resolve(root, "src/lib.rs"), `
#[cfg(test)]
mod tests {
    #[test]
    fn selected() { assert_eq!(2 + 2, 4); }
    #[test]
    fn unselected() { panic!("The scoped job must not run this test"); }
}
`);
  const options = parseArguments([
    "--manifest", resolve(root, "Cargo.toml"), "--test-filter", "tests::selected",
    "--warn-ms", "500", "--max-ms", "2000", "--build-timeout-ms", "20000",
    "--suite-timeout-ms", "25000", "--report", resolve(root, "filtered.json"),
  ]);
  await run(options);
  const report = JSON.parse(readFileSync(options.report, "utf8"));
  assert.deepEqual(report.tests.map(({ name, status }) => ({ name, status })), [{ name: "tests::selected", status: "passed" }]);
  assert.match(readFileSync(resolve(root, "filtered.junit.xml"), "utf8"), /tests::selected/);
  assert.doesNotMatch(readFileSync(resolve(root, "filtered.junit.xml"), "utf8"), /tests::unselected/);
  await assert.rejects(run({ ...options, testFilter: "missing::test" }), /No Rust tests were enumerated/);
  await assert.rejects(run({ ...options, testFilter: null }), /Rust test\(s\) failed/);
});
