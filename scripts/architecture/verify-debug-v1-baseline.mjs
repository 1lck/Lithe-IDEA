#!/usr/bin/env node
// Checks that the #1210 P0 baseline manifest still points at real tests and fixtures.
// A renamed or deleted test would otherwise silently shrink the safety net that the
// unified debug engine must pass before any old session path is removed.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../..", import.meta.url).pathname;
const manifestPath = "shared/fixtures/debug/v1-baseline.json";
const manifest = JSON.parse(readFileSync(join(root, manifestPath), "utf8"));
const failures = [];
const fail = (message) => failures.push(message);

// Rust declares `fn name`, Swift Testing declares `func name`, Windows frontend uses test titles.
const declares = (source, name) => new RegExp(`\\b(fn|func)\\s+${name}\\b`).test(source);
const platforms = new Set(["rust", "macos", "windows"]);
const statuses = new Set(["covered", "partial", "gap"]);
const ids = new Set();
const referencedFixtures = new Set();

if (manifest.version !== 1) fail("baseline version must be 1");

for (const item of manifest.items) {
  if (ids.has(item.id)) fail(`duplicate item id ${item.id}`);
  ids.add(item.id);
  if (!statuses.has(item.status)) fail(`${item.id}: unknown status ${item.status}`);
  const gaps = item.gaps ?? [];
  if (item.status === "covered" && gaps.length > 0) fail(`${item.id}: covered items must not list gaps`);
  if (item.status !== "covered" && gaps.length === 0) fail(`${item.id}: ${item.status} items must explain their gaps`);
  if (item.status !== "gap" && item.evidence.length === 0) fail(`${item.id}: needs evidence`);

  for (const evidence of item.evidence) {
    if (!platforms.has(evidence.platform)) fail(`${item.id}: unknown platform ${evidence.platform}`);
    const file = join(root, evidence.path);
    if (!existsSync(file)) {
      fail(`${item.id}: missing file ${evidence.path}`);
      continue;
    }
    if (!declares(readFileSync(file, "utf8"), evidence.test)) {
      fail(`${item.id}: ${evidence.path} does not declare ${evidence.test}`);
    }
    if (evidence.fixture) {
      referencedFixtures.add(evidence.fixture);
      if (!existsSync(join(root, evidence.fixture))) fail(`${item.id}: missing fixture ${evidence.fixture}`);
    }
  }
}

// Every recorded v1 fixture must belong to some baseline item; v2 projection fixtures
// describe the new contract and are exempt.
const fixtureDirectory = "shared/fixtures/debug";
for (const name of readdirSync(join(root, fixtureDirectory))) {
  const path = `${fixtureDirectory}/${name}`;
  if (path !== manifestPath && name.endsWith(".json") && !name.startsWith("projection-v2") && !referencedFixtures.has(path)) {
    fail(`${path} is not referenced by any baseline item`);
  }
}

if (failures.length > 0) {
  console.error(failures.map((message) => `- ${message}`).join("\n"));
  process.exit(1);
}
const counts = manifest.items.reduce((total, item) => ({ ...total, [item.status]: (total[item.status] ?? 0) + 1 }), {});
console.log(`debug v1 baseline: ${manifest.items.length} items ${JSON.stringify(counts)}`);
