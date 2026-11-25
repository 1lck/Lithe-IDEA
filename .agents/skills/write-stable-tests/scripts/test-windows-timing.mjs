import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { runProcess, terminateProcessTree } from "./test-timing-lib.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const powershell = process.env.LITHE_TEST_POWERSHELL || (process.platform === "win32" ? "powershell.exe" : "pwsh");
const quote = (value) => `'${value.replaceAll("'", "''")}'`;
// Windows PowerShell 5 needs a BOM to recognize UTF-8 fixture paths.
const writePowerShell = (file, content) => writeFileSync(file, `\uFEFF${content}`);

function fixture(t, { mode = "pass", missing, gateExit = 0, conversion = "pass" } = {}) {
  const root = mkdtempSync(path.join(os.tmpdir(), "lithe Windows timing 中文 "));
  const pids = path.join(root, "pids.json");
  t.after(async () => {
    try {
      if (existsSync(pids)) for (const pid of JSON.parse(readFileSync(pids, "utf8"))) {
        try { process.kill(pid, 0); } catch (error) {
          if (error.code === "ESRCH") continue;
          throw error;
        }
        const stopped = await terminateProcessTree({ pid, kill: () => process.kill(pid, "SIGKILL") });
        assert.equal(stopped, true, `could not reclaim fixture process ${pid}`);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
  const scripts = path.join(root, ".agents/skills/write-stable-tests/scripts");
  mkdirSync(scripts, { recursive: true });
  for (const name of ["test-stability-windows.ps1", "run-go-tests-with-timing.mjs", "test-timing-lib.mjs", "generate-test-report.mjs"]) {
    copyFileSync(path.join(scriptDirectory, name), path.join(scripts, name));
  }
  const gate = path.join(root, "gate-ran");
  writePowerShell(path.join(scripts, "verify-test-stability.ps1"),
    `[System.IO.File]::WriteAllText(${quote(gate)}, 'ran')\n$global:LASTEXITCODE = ${gateExit}\n`);
  // Only Windows tool discovery is substituted. The actual PowerShell entry
  // and Node timing/report/cleanup runners execute against a synthetic Go stream.
  writePowerShell(path.join(scripts, "git-bash-path.ps1"), `
function Resolve-GitForWindowsTools {
    param([string]$GitPath)
    return [pscustomobject]@{ Bash = ${quote(process.execPath)}; Cygpath = 'Convert-FixtureWrapperPath' }
}
function Convert-FixtureWrapperPath {
    param([string]$u)
    $global:LASTEXITCODE = ${conversion === "fail" ? 7 : 0}
    ${conversion === "empty" ? "return ''" : "return $u"}
}
`);
  mkdirSync(path.join(root, "desktop"), { recursive: true });
  mkdirSync(path.join(root, "scripts/desktop"), { recursive: true });
  writeFileSync(path.join(root, "desktop/go.mod"), "module fixture\n");
  const argumentsFile = path.join(root, "arguments.json");
  writeFileSync(path.join(root, "scripts/desktop/desktop-go.sh"), `
const fs = require('node:fs');
const { fork } = require('node:child_process');
fs.writeFileSync(${JSON.stringify(argumentsFile)}, JSON.stringify(process.argv.slice(2)));
const emit = (event) => process.stdout.write(JSON.stringify({ Package: 'fixture', Test: 'TestFixture', ...event }) + '\\n');
if (${JSON.stringify(mode)} === 'hang') {
  const child = fork(${JSON.stringify(path.join(root, "descendant.cjs"))}, [], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  child.once('message', () => {
    fs.writeFileSync(${JSON.stringify(pids)}, JSON.stringify([process.pid, child.pid]));
    emit({ Action: 'run' });
  });
} else if (${JSON.stringify(mode)} !== 'empty') {
  emit({ Action: 'run' });
  emit({ Action: ${JSON.stringify(mode === "fail" ? "fail" : "pass")}, Elapsed: 0.001 });
  process.exitCode = ${mode === "fail" ? 1 : 0};
}
`);
  // This interval intentionally keeps the owned descendant alive. Completion
  // comes from the runner's deadline, not a sleep used to order the test.
  writeFileSync(path.join(root, "descendant.cjs"), "process.send('ready'); setInterval(() => {}, 60000);\n");
  if (missing) rmSync(path.join(root, missing));
  return { root, scripts, gate, argumentsFile, pids,
    report: path.join(root, ".artifacts/test-stability/windows-desktop-go.json") };
}

async function invoke(f, parameters = {}) {
  const entries = Object.entries(parameters).map(([key, value]) => {
    const literal = Array.isArray(value) ? `@(${value.map(quote).join(", ")})`
      : typeof value === "number" ? String(value) : quote(value);
    return `${key} = ${literal}`;
  });
  const launcher = path.join(f.root, "invoke.ps1");
  // The real resolver has separate native-path tests; here git.exe is a named
  // fixture command so routing tests also run on non-Windows PowerShell hosts.
  writePowerShell(launcher, `
$ErrorActionPreference = 'Stop'
function git.exe {}
$parameters = @{ ${entries.join("; ")} }
& ${quote(path.join(f.scripts, "test-stability-windows.ps1"))} @parameters
exit $LASTEXITCODE
`);
  const result = await runProcess({ command: powershell,
    args: ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", launcher], cwd: f.root,
    timeoutMs: 12000, maxCapturedBytes: 128 * 1024 });
  assert.equal(result.timedOut, false, result.stderr);
  assert.equal(result.terminationConfirmed, true, result.stderr);
  return result;
}

test("retired scopes fail before tools, the static gate, or reports run", { timeout: 30000 }, async (t) => {
  for (const Scope of ["All", "Frontend", "WindowsRust", "SharedRust", "SharedRustCore", "SharedRustHosts"]) {
    await t.test(Scope, { timeout: 15000 }, async (t) => {
      const f = fixture(t);
      const result = await invoke(f, { Scope });
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /DesktopGo/);
      assert.equal(existsSync(f.gate), false, "retired scopes must fail before running checks");
      assert.equal(existsSync(f.argumentsFile), false);
      assert.equal(existsSync(path.dirname(f.report)), false);
    });
  }
});

test("removed client and Core options cannot silently succeed in DesktopGo", { timeout: 20000 }, async (t) => {
  for (const parameter of [{ FrontendTestPath: ["obsolete.test.ts"] }, { CoreShardIndex: 1 }, { CoreShardCount: 1 }]) {
    const f = fixture(t);
    const result = await invoke(f, parameter);
    assert.notEqual(result.code, 0);
    assert.equal(existsSync(f.gate), false);
    assert.equal(existsSync(f.argumentsFile), false);
  }
});

test("default and explicit DesktopGo preserve arguments and timing reports", { timeout: 20000 }, async (t) => {
  for (const scope of [{}, { Scope: "DesktopGo" }]) {
    const f = fixture(t);
    const result = await invoke(f, { ...scope, WarnSeconds: 2, MaxSeconds: 7, SuiteTimeoutSeconds: 9,
      GoTestPattern: "^TestSaved Text$", GoPackages: ["./internal/one", "./internal/two"] });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(existsSync(f.gate), true);
    assert.deepEqual(JSON.parse(readFileSync(f.argumentsFile, "utf8")),
      ["test", "-json", "-count=1", "-p=1", "-parallel=1", "-timeout=9s", "-run", "^TestSaved Text$", "./internal/one", "./internal/two"]);
    const report = JSON.parse(readFileSync(f.report, "utf8"));
    assert.equal(report.warnMs, 2000);
    assert.equal(report.maxMs, 7000);
    assert.equal(report.suiteTimeoutMs, 9000);
    assert.deepEqual(report.tests.map(({ name, status, durationMs }) => ({ name, status, durationMs })),
      [{ name: "TestFixture", status: "passed", durationMs: 1 }]);
    assert.match(readFileSync(f.report.replace(/\.json$/, ".html"), "utf8"), /TestFixture/);
    assert.match(readFileSync(f.report.replace(/\.json$/, ".junit.xml"), "utf8"), /TestFixture/);
  }
});

test("missing current desktop sources fail before the static gate", { timeout: 20000 }, async (t) => {
  for (const missing of ["desktop/go.mod", "scripts/desktop/desktop-go.sh"]) {
    const f = fixture(t, { missing });
    const result = await invoke(f);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /DesktopGo test source is missing/);
    assert.equal(existsSync(f.gate), false);
    assert.equal(existsSync(f.argumentsFile), false);
  }
});

test("static gate and path conversion failures stop before Go", { timeout: 20000 }, async (t) => {
  const gateFixture = fixture(t, { gateExit: 13 });
  const failedGate = await invoke(gateFixture);
  assert.equal(failedGate.code, 13, failedGate.stderr);
  assert.equal(existsSync(gateFixture.argumentsFile), false);
  for (const conversion of ["fail", "empty"]) {
    const f = fixture(t, { conversion });
    const result = await invoke(f);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /Could not convert/);
    assert.equal(existsSync(f.argumentsFile), false);
  }
});

test("DesktopGo propagates zero matches and assertion failures", { timeout: 20000 }, async (t) => {
  for (const mode of ["empty", "fail"]) {
    const f = fixture(t, { mode });
    const result = await invoke(f);
    assert.notEqual(result.code, 0);
    const report = JSON.parse(readFileSync(f.report, "utf8"));
    assert.ok(report.tests.some(({ status }) => status === (mode === "empty" ? "error" : "failed")));
    assert.match(readFileSync(f.report.replace(/\.json$/, ".junit.xml"), "utf8"), mode === "empty" ? /<error/ : /<failure/);
  }
});

test("DesktopGo deadline stops the test and its descendant and reports failure", { timeout: 15000 }, async (t) => {
  const f = fixture(t, { mode: "hang" });
  const result = await invoke(f, { SuiteTimeoutSeconds: 3 });
  assert.notEqual(result.code, 0);
  const report = JSON.parse(readFileSync(f.report, "utf8"));
  assert.equal(report.suiteTimeoutMs, 3000);
  assert.equal(report.process.timedOut, true);
  assert.equal(report.process.terminationConfirmed, true);
  assert.ok(report.tests.some(({ name, status }) => name === "TestFixture" && status === "timeout"));
  for (const pid of JSON.parse(readFileSync(f.pids, "utf8"))) {
    assert.throws(() => process.kill(pid, 0), (error) => error.code === "ESRCH", `fixture process ${pid} must have exited`);
  }
});
