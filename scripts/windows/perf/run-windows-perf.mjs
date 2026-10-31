#!/usr/bin/env node
// Measures the Windows frontend's interactions in Chromium against an in-page
// mock host: production bundle, deterministic project, no Rust host or language
// server. See .agents/notes/implemented/testing/2026-10-30-windows-frontend-performance-budgets.md.
//
//   node scripts/windows/perf/run-windows-perf.mjs
//   ... --only typing,scroll --runs 5
//   ... --cpu 4               4x CPU slowdown; budgets are reported, not enforced
//   ... --save-baseline       store this run as the local baseline
//   ... --no-build            reuse the last perf bundle
//   ... --fail-on-budget      exit 1 when a metric is over budget or regressed
//   ... --profile typingLarge CPU profile of the typing phase, unminified build
import { spawnSync } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { dirname, extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { createFixture } from "./lib/fixture.mjs";
import { topSelfTime } from "./lib/cpu-profile.mjs";
import { Harness, fixtureScript, initialBundleKilobytes } from "./lib/harness.mjs";
import { evaluate, renderReport } from "./lib/report.mjs";
import { medianMetrics } from "./lib/stats.mjs";
import { SCENARIOS } from "./scenarios.mjs";

const SCENARIO_TIMEOUT_MILLISECONDS = 180_000;
const SCRIPT_DIRECTORY = import.meta.dirname;
const REPOSITORY = resolve(SCRIPT_DIRECTORY, "../../..");
const FRONTEND = join(REPOSITORY, "windows/tauri");
const OUTPUT = join(REPOSITORY, ".artifacts/windows-perf");

const { values: options } = parseArgs({
  options: {
    only: { type: "string" },
    runs: { type: "string", default: "3" },
    warmup: { type: "string", default: "1" },
    cpu: { type: "string", default: "1" },
    list: { type: "boolean", default: false },
    "no-build": { type: "boolean", default: false },
    "save-baseline": { type: "boolean", default: false },
    "fail-on-budget": { type: "boolean", default: false },
    json: { type: "string" },
    profile: { type: "string" },
  },
  allowPositionals: false,
});

if (options.list) {
  for (const scenario of SCENARIOS) console.log(`${scenario.id.padEnd(16)} ${scenario.title}`);
  process.exit(0);
}

const DIST = join(OUTPUT, options.profile ? "dist-profile" : "dist");
const only = (options.profile ?? options.only)?.split(",").map((id) => id.trim());
const scenarios = only ? SCENARIOS.filter((scenario) => only.includes(scenario.id)) : SCENARIOS;
if (only && scenarios.length !== only.length) {
  const known = new Set(SCENARIOS.map((scenario) => scenario.id));
  throw new Error(`Unknown scenario: ${only.filter((id) => !known.has(id)).join(", ")}`);
}
const runs = options.profile ? 1 : Math.max(1, Number(options.runs));
const warmup = options.profile ? 0 : Math.max(0, Number(options.warmup));
const cpuThrottle = Math.max(1, Number(options.cpu));
const baselinePath = join(OUTPUT, `baseline-${cpuThrottle}x.json`);

function build() {
  console.log("Building the production frontend...");
  const unminified = options.profile ? ["--minify", "false"] : [];
  const result = spawnSync("bunx", ["vp", "build", "--outDir", DIST, "--emptyOutDir", ...unminified], {
    cwd: FRONTEND,
    stdio: ["ignore", "ignore", "inherit"],
    shell: process.platform === "win32",
  });
  if (result.status !== 0) throw new Error("Frontend build failed");
}

const CONTENT_TYPES = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".png": "image/png",
};

function serve() {
  const server = createServer((request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const file = join(DIST, path === "/" ? "index.html" : path);
    if (!file.startsWith(DIST) || !existsSync(file) || !statSync(file).isFile()) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "content-type": CONTENT_TYPES[extname(file)] ?? "application/octet-stream" });
    createReadStream(file).pipe(response);
  });
  return new Promise((resolveServer) => {
    server.listen(0, "127.0.0.1", () => resolveServer(server));
  });
}

async function withDeadline(work, label) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${SCENARIO_TIMEOUT_MILLISECONDS} ms`)), SCENARIO_TIMEOUT_MILLISECONDS);
  });
  try {
    return await Promise.race([work, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

function printProfile({ cpuProfile: profile, payloadByCommand }) {
  if (!profile) throw new Error(`${options.profile} has no profiled phase`);
  const path = join(OUTPUT, `${options.profile}.cpuprofile`);
  writeFileSync(path, JSON.stringify(profile));
  console.log(`\nSelf time by function (${path}):`);
  for (const { milliseconds, name, url } of topSelfTime(profile, 30)) {
    console.log(`${milliseconds.toFixed(1).padStart(9)} ms  ${name}  ${url}`);
  }
  console.log("\nIPC payload by command:");
  for (const [command, bytes] of Object.entries(payloadByCommand).sort((left, right) => right[1] - left[1]).slice(0, 12)) {
    console.log(`${(bytes / 1_024).toFixed(1).padStart(9)} KB  ${command}`);
  }
}

async function runScenario(browser, url, script, scenario) {
  const measured = [];
  let unanswered = {};
  for (let run = 0; run < warmup + runs; run += 1) {
    const harness = await Harness.launch(browser, {
      url,
      fixtureScript: script,
      cpuThrottle,
      profile: Boolean(options.profile),
    });
    try {
      const metrics = await withDeadline(scenario.run(harness), `${scenario.id} run ${run}`);
      if (harness.pageErrors.length > 0) {
        throw new Error(`${scenario.id} raised a page error:\n${harness.pageErrors[0]}`);
      }
      if (run >= warmup) measured.push(metrics);
      unanswered = await harness.host("unanswered()");
      if (options.profile) printProfile(harness);
    } finally {
      await harness.close();
    }
  }
  return { metrics: medianMetrics(measured), unanswered };
}

if (!options["no-build"] || !existsSync(join(DIST, "index.html"))) build();
mkdirSync(OUTPUT, { recursive: true });

const require = createRequire(join(FRONTEND, "package.json"));
const { chromium } = require("playwright-core");
const server = await serve();
const url = `http://127.0.0.1:${server.address().port}/`;
const script = fixtureScript(createFixture());
const browser = await chromium.launch();

const results = {};
const unanswered = {};
let failed = false;
try {
  for (const scenario of scenarios) {
    process.stdout.write(`${scenario.id}: ${scenario.title}... `);
    try {
      const outcome = await runScenario(browser, url, script, scenario);
      results[scenario.id] = outcome.metrics;
      Object.assign(unanswered, outcome.unanswered);
      console.log("done");
    } catch (error) {
      failed = true;
      console.log("FAILED");
      console.error(String(error.message ?? error));
    }
  }
} finally {
  await browser.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}

if (results.startup) Object.assign(results.startup, initialBundleKilobytes(DIST));

const budgets = JSON.parse(readFileSync(join(SCRIPT_DIRECTORY, "budgets.json"), "utf8"));
const baseline = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, "utf8")) : null;
const rows = evaluate(results, budgets, baseline);
console.log(`\n${renderReport(rows)}`);
console.log(`\nCommands without a mock answer: ${Object.keys(unanswered).sort().join(", ") || "none"}`);

if (options.json) {
  mkdirSync(dirname(resolve(options.json)), { recursive: true });
  writeFileSync(resolve(options.json), `${JSON.stringify(results, null, 2)}\n`);
}
if (options["save-baseline"]) {
  writeFileSync(baselinePath, `${JSON.stringify(results, null, 2)}\n`);
  console.log(`Baseline saved to ${baselinePath}`);
}

const breached = cpuThrottle === 1 ? rows.filter((row) => row.over || row.regressed) : rows.filter((row) => row.regressed);
if (failed || (options["fail-on-budget"] && breached.length > 0)) process.exitCode = 1;
