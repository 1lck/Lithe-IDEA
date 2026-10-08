#!/usr/bin/env bun

import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, extname, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Glob, Transpiler } from "bun";

const repository = resolve(import.meta.dirname, "..");
const sourceRoot = "windows/tauri/src/";
const planPath = ".artifacts/test-stability/windows-ci-selection.txt";
const registry = JSON.parse(readFileSync(new URL("./windows-ci-test-suites.json", import.meta.url), "utf8"));
const isTest = (path) => /\.(?:test|spec)\.[cm]?[jt]sx?$/.test(path);
const feature = (path) => path.match(/^windows\/tauri\/src\/features\/([^/]+)\//)?.[1];

function sourceFiles(root, directory = sourceRoot) {
  return readdirSync(resolve(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const path = directory + entry.name;
    if (entry.isDirectory()) return sourceFiles(root, path + "/");
    return entry.isFile() && /\.[cm]?[jt]sx?$/.test(path) && !path.endsWith(".d.ts") ? [path] : [];
  }).sort();
}

function matches(path, filter) {
  const relative = path.slice("windows/tauri/".length);
  // Existing commands pass bare Bun filename filters, not ./ explicit paths.
  // Bun includes sibling names as well: src/features/run also runs run-actions.
  return relative.includes(filter);
}

function localDependency(root, importer, specifier) {
  const clean = specifier.split("?")[0];
  const stem = clean.startsWith("@/") ? sourceRoot + clean.slice(2)
    : clean.startsWith(".") ? posix.normalize(posix.join(posix.dirname(importer), clean)) : null;
  if (!stem) return null;
  const candidates = [stem, ...[".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js", "/index.jsx"].map((suffix) => stem + suffix)];
  if (/\.jsx?$/.test(stem)) candidates.push(stem.replace(/\.js$/, ".ts").replace(/\.jsx$/, ".tsx"));
  return candidates.find((path) => existsSync(resolve(root, path))) ?? stem;
}

function dependencyGraph(root, files) {
  const importers = new Map();
  const scanners = new Map();
  const opaque = new Set();
  for (const file of files) {
    const loader = extname(file).slice(1).replace(/^[cm]/, "");
    if (!scanners.has(loader)) scanners.set(loader, new Transpiler({ loader }));
    const text = readFileSync(resolve(root, file), "utf8");
    // Bun owns syntax parsing. Do not approximate imports with a source-text regex.
    const imports = scanners.get(loader).scan(text).imports.map(({ path }) => path);
    // Source-inspection tests also depend on literal URL inputs, without importing them.
    for (const match of text.matchAll(/new URL\(\s*["']([^"']+)["']\s*,\s*import\.meta\.url\s*\)/g)) imports.push(match[1]);
    // A computed target cannot be proved unrelated; keep its consumers running.
    if (/\b(?:import|require)\s*\(\s*[A-Za-z_$]/.test(text)) opaque.add(file);
    const globCalls = [...text.matchAll(/import\.meta\.glob\(\s*["']([^"']+)["']/g)];
    if ((text.match(/import\.meta\.glob\s*\(/g) ?? []).length !== globCalls.length) opaque.add(file);
    for (const match of globCalls) {
      for (const input of new Glob(match[1]).scanSync({ cwd: resolve(root, posix.dirname(file)), onlyFiles: true })) imports.push("./" + input.replaceAll("\\", "/"));
    }
    for (const specifier of imports) {
      const dependency = localDependency(root, file, specifier);
      if (!dependency) continue;
      if (!importers.has(dependency)) importers.set(dependency, new Set());
      importers.get(dependency).add(file);
    }
  }
  return { importers, opaque };
}

function irrelevant(path) {
  return /\.(md|mdx)$/.test(path) || /^(macos\/|Plugins\/mac\/|docs\/|Casks\/)/.test(path)
    || /^shared\/platform-feature-matrix\/features\/[a-z0-9]+(-[a-z0-9]+)*\.json$/.test(path);
}

export function selectSuites({ root = repository, changes = [], full = false, groups = registry.groups } = {}) {
  const files = sourceFiles(root);
  const tests = files.filter(isTest);
  const groupTests = Object.fromEntries(Object.entries(groups).map(([id, group]) => [id, tests.filter((file) => group.tests.some((filter) => matches(file, filter)))]));
  for (const [id, members] of Object.entries(groupTests)) {
    if (members.length === 0) throw new Error(`Windows suite ${id} has no matching tests`);
  }
  const owners = Object.fromEntries(Object.entries(groupTests).map(([id, members]) => [id, new Set(members.map(feature).filter(Boolean))]));
  const registeredOwners = new Set(Object.values(owners).flatMap((set) => [...set]));
  const reasons = [];
  const changed = [];
  for (const { status, path } of changes) {
    if (irrelevant(path)) continue;
    changed.push(path);
    // Assets, declarations, native contracts, global helpers and unowned modules
    // need full coverage: runtime dependencies need not appear as JS imports.
    if (status === "D" || !path.startsWith(sourceRoot) || !/\.[jt]sx?$/.test(path)
      || path.endsWith(".d.ts") || !registeredOwners.has(feature(path))) reasons.push(`${status}: ${path}`);
  }
  if (changed.length === 0 && !full) reasons.push("No recognized Windows source change in selected frontend lane");
  const selected = Object.fromEntries(Object.keys(groups).map((id) => [id, []]));
  if (full || reasons.length > 0) {
    for (const id of Object.keys(groups)) selected[id].push(full ? "Full validation event" : "Conservative fallback");
  } else {
    let graph;
    try {
      graph = dependencyGraph(root, files);
    } catch (error) {
      reasons.push(`Dependency scan failed: ${error.message}`);
      for (const id of Object.keys(groups)) selected[id].push("Dependency scan fallback");
    }
    if (graph) {
      const affected = new Set([...changed, ...graph.opaque]);
      const queue = [...affected];
      for (let index = 0; index < queue.length; index++) {
        for (const importer of graph.importers.get(queue[index]) ?? []) {
          if (!affected.has(importer)) { affected.add(importer); queue.push(importer); }
        }
      }
      const changedOwners = new Set(changed.map(feature));
      for (const id of Object.keys(groups)) {
        for (const owner of owners[id]) if (changedOwners.has(owner)) selected[id].push(`Feature: ${owner}`);
        for (const test of groupTests[id]) if (affected.has(test)) selected[id].push(`Dependent test: ${test}`);
        // The invoke boundary remains a baseline check even for presentation changes.
        if (id === "platform") selected[id].push("Platform routing baseline");
      }
    }
  }
  const covered = new Set(Object.values(groupTests).flat());
  const additional = tests.filter((test) => !covered.has(test) && changed.includes(test));
  return { schemaVersion: 1, full: full || reasons.length > 0, reasons, changed, selected, additional };
}

export function readChanges(root, base, head) {
  if (!base || !head) throw new Error("PR comparison base/head is missing");
  // Disable rename detection: either deletion endpoint conservatively selects all.
  const fields = execFileSync("git", ["diff", "--no-renames", "--name-status", "-z", base, head, "--"], {
    cwd: root, encoding: "utf8", timeout: 15_000, maxBuffer: 16 * 1024 * 1024,
  }).split("\0");
  const changes = [];
  for (let index = 0; index < fields.length - 1; index += 2) {
    const status = fields[index], path = fields[index + 1];
    if (!/^[AMDT]$/.test(status) || !path) throw new Error("Unrecognized git diff record");
    changes.push({ status, path });
  }
  return changes;
}

async function main() {
  if (process.argv.includes("--run-additional")) {
    const plan = JSON.parse(readFileSync(resolve(repository, planPath), "utf8"));
    const { run, parseArguments } = await import("../.agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs");
    // One process per extra test prevents a newly added module mock from leaking.
    for (const [index, path] of plan.additional.entries()) {
      if (!path.startsWith(sourceRoot) || !isTest(path) || path.includes("..")) throw new Error("Invalid additional test path");
      await run(parseArguments(["--suite-timeout-ms", "60000", "--report", resolve(repository, `.artifacts/test-stability/windows-additional-${index}.json`), "--", "./" + path.slice("windows/tauri/".length)]));
    }
    return;
  }
  const event = process.env.CI_EVENT_NAME;
  if (!["pull_request", "push", "workflow_dispatch"].includes(event)) throw new Error(`Unsupported CI event: ${event}`);
  const plan = selectSuites({ full: event !== "pull_request", changes: event === "pull_request" ? readChanges(repository, process.env.CI_BASE_SHA, process.env.GITHUB_SHA) : [] });
  mkdirSync(dirname(resolve(repository, planPath)), { recursive: true });
  writeFileSync(resolve(repository, planPath), JSON.stringify(plan, null, 2) + "\n");
  const outputs = [...Object.entries(plan.selected).map(([id, reasons]) => `${id}=${reasons.length > 0}`), `full=${plan.full}`, `additional=${plan.additional.length > 0}`].join("\n") + "\n";
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, outputs);
  console.log(outputs);
  console.log(JSON.stringify(plan, null, 2));
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, "### Windows frontend test selection\n\n" + Object.entries(plan.selected).map(([id, reasons]) => `- ${id}: ${reasons.length ? "run" : "skip"}`).join("\n") + "\n\n" + plan.reasons.map((reason) => `- Full fallback: ${reason.replaceAll("\n", " ")}`).join("\n") + "\n");
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  try { await main(); } catch (error) { console.error(error); process.exitCode = 1; }
}
