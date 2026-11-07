#!/usr/bin/env node
// Controlled executable, not a build parser/server. Core interprets all model,
// task, diagnostic, test and dependency semantics. Every hold has a local bound.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const root = process.cwd();
const state = path.join(root, ".lithe-acceptance");
const controlFile = path.join(state, "control.json");
const markerIndex = args.lastIndexOf("--fixture-marker");
const marker = markerIndex < 0 ? "a" : args[markerIndex + 1];
const child = args.includes("--fixture-child");
mkdirSync(state, { recursive: true });
function event(type, extra = {}) {
  appendFileSync(path.join(state, "events.jsonl"), JSON.stringify({
    event: type, marker, pid: process.pid, parentPid: process.ppid, child,
    argv: args, workspace: root, ...extra,
  }) + "\n");
}
let control = {};
if (existsSync(controlFile)) control = JSON.parse(readFileSync(controlFile, "utf8"));
const probe = args.includes("--version");
const model = args.includes("litheModel") || (args.includes("list") && !args.includes("-m"));
const dependencies = args.some((arg) => arg.endsWith("litheDependencies")) || args.includes("-m");
const testing = args.some((arg) => arg === "test" || arg.endsWith(":test"));
const action = probe ? "probe" : model ? "model" : dependencies ? "dependencies" : testing ? "test" : "task";
event("started", { action, savedText: existsSync(path.join(root, "acceptance.build.txt"))
  ? readFileSync(path.join(root, "acceptance.build.txt"), "utf8") : null });

function emitOutput(value, prefix) {
  const target = args.find((arg) => arg.startsWith(prefix));
  const text = JSON.stringify(value);
  if (!target) { process.stdout.write(text + "\n"); return; }
  const output = path.resolve(target.slice(prefix.length));
  // Native allocates the path. Fixtures must never create package/bundle state.
  if (!path.isAbsolute(target.slice(prefix.length)) || !output.toLowerCase().includes(`${path.sep}plugin-state${path.sep}`)) {
    throw new Error("expected the native operation's exclusive plugin-state output file");
  }
  writeFileSync(output, text + "\n");
  event("output-file", { output });
}

function finish() {
  if (probe) process.stdout.write("Lithe Build Acceptance 1.0.0\n");
  else if (model) {
    if (args.some((arg) => arg.startsWith("-PlitheModelOutput="))) {
      emitOutput({ format: "litheBuildModel", version: 1,
        projects: [{ path: ".", name: "fixture-app", properties: { taskPrefix: "" } },
          { path: "nested", name: "fixture-nested", properties: { taskPrefix: ":nested:" } }],
        targets: [], tasks: [], optionValues: {}, run: [], contentRoots: [],
      }, "-PlitheModelOutput=");
    } else process.stdout.write(JSON.stringify({ Module: { Path: "fixture-app", Dir: root, GoVersion: "1.21" },
      Name: "main", ImportPath: "fixture-app", Dir: root, TestGoFiles: ["fixture_test.go"] }) + "\n");
  } else if (dependencies) {
    if (args.some((arg) => arg.startsWith("-PlitheDependenciesOutput="))) {
      emitOutput({ format: "litheDependencies", version: 1, dependencies: [{ name: "fixture-dependency", version: "1.0.0", children: [] }] }, "-PlitheDependenciesOutput=");
    } else process.stdout.write(JSON.stringify({ Path: "fixture-dependency", Version: "v1.0.0", Indirect: false }) + "\n");
  } else if (testing) {
    const reports = path.join(root, "build/test-results/test");
    mkdirSync(reports, { recursive: true });
    writeFileSync(path.join(reports, "TEST-fixture.xml"),
      '<testsuite name="fixture.Suite" tests="1" failures="1"><testcase classname="fixture.Suite" name="fails" file="src/main.rs" line="1"><failure message="controlled failure">fixture assertion</failure></testcase></testsuite>\n');
    process.stdout.write("src/main.rs:1:1: error: controlled diagnostic\n");
    process.stdout.write("src/main.go:1:1: controlled diagnostic\n");
    process.stdout.write("src/Main.java:1: error: controlled diagnostic\n");
    process.stderr.write("controlled test stderr\n");
    process.exitCode = 1;
  } else {
    process.stdout.write(`controlled task stdout [marker=${marker}]\n`);
    process.stderr.write("controlled task stderr\n");
  }
  event("finished", { action, exitCode: process.exitCode ?? 0 });
}

let watcher = null;
let deadline = null;
let descendant = null;
function release() {
  if (watcher) clearInterval(watcher);
  if (deadline) clearTimeout(deadline);
  watcher = null; deadline = null;
  if (descendant && descendant.exitCode === null) descendant.kill();
}
process.once("exit", release);
if (child || (!probe && control.holdAction === action)) {
  if (!child) {
    descendant = spawn(process.execPath, [fileURLToPath(import.meta.url), "--fixture-child", "--fixture-marker", marker],
      { cwd: root, stdio: "ignore", windowsHide: true });
    event("child-spawned", { childPid: descendant.pid, action });
  }
  event("gated", { action, token: control.token ?? null });
  const expires = performance.now() + 45_000;
  // This is a real executable boundary; the acceptance driver controls a file
  // gate, and both this watchdog and the host operation deadline remain active.
  watcher = setInterval(() => {
    if (!child && existsSync(path.join(state, `release-${control.token}`))) {
      release(); finish();
    } else if (performance.now() >= expires) {
      release(); process.exitCode = 73; event("gate-timeout", { action });
    }
  }, 25);
  deadline = setTimeout(() => { release(); process.exitCode = 73; }, 46_000);
} else finish();
