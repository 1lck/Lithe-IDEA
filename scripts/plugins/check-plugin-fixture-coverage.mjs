#!/usr/bin/env node
// Fixture coverage detector for shared/contracts/plugins/v1/fixtures.
//
// Every fixture file must appear exactly once in the explicit classification
// list scripts/plugins/plugin-fixture-coverage.json, and every list entry must point
// at a real file. This closes the "fixtures added without classification"
// hole: a new file in the directory fails with unknown-fixture, a stale list
// entry fails with missing-fixture, a file classified twice fails with
// duplicate-entry. The list must stay sorted so diffs stay reviewable, and a
// non-wired Windows status is a known gap that must name a roadmap stage
// (M0-M10) and a concrete detail until a real test closes it.
//
// Usage:
//   node scripts/plugins/check-plugin-fixture-coverage.mjs
//     [--manifest scripts/plugins/plugin-fixture-coverage.json]
//     [--repo-root <dir>] [--fixtures-dir <dir>]
//
// Exits 0 when the enumeration and the list match and every entry is
// coherent; exits 1 after printing one line per problem. Read-only: it never
// writes anything and needs no network. Unit tests live in
// scripts/plugins/check-plugin-fixture-coverage.test.mjs.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

export const CATEGORY_VALUES = [
  'valid-manifest',
  'invalid-edits',
  'command-plans',
  'build-plans',
  'runtime-versions',
  'function-protocol',
  'project-plans',
  'project-generation',
  'marketplace',
  // Shared acceptance data for publisher-signature verification (M1); the
  // fixture and its classification ship together in the unified plugin PR.
  // Both hosts consume it in their own signature tests, so there is no Core
  // validation surface and coreEvidence is optional for this category.
  'signature-vectors',
  'native-ui',
  'vcs-provider',
  'template-assets',
  // Read-only syntax data consumed by an independent editor contribution.
  // It still requires Core evidence and an honest Windows wiring status.
  'grammar-assets',
];

export const OUTCOME_VALUES = ['success', 'rejection', 'partial-support'];

export const WINDOWS_STATUS_VALUES = ['wired', 'validated-only', 'indirect-core', 'unwired'];

// Roadmap stages M0-M10, plus `followup` for capabilities that landed after
// the roadmap froze: the plan routes those into separately numbered later
// stages (section 6) that do not exist yet, so no M-number may be invented.
export const GAP_STAGE_PATTERN = /^(M(10|[0-9])|followup)$/;

export function defaultRepoRoot() {
  return join(dirname(fileURLToPath(import.meta.url)), '../..');
}

export function defaultManifestPath() {
  return join(defaultRepoRoot(), 'scripts/plugins/plugin-fixture-coverage.json');
}

// Recursively lists regular files under fixturesDir as '/'-separated paths
// relative to it, in the same byte order the manifest must be sorted with.
// Any non-directory, non-regular entry (symlink, junction) is reported as a
// fixture candidate so an anomalous entry cannot hide behind the enumeration.
export function enumerateFixtureFiles(fixturesDir) {
  if (!statSync(fixturesDir, { throwIfNoEntry: false })?.isDirectory()) {
    throw new Error(`fixtures directory is not readable: ${fixturesDir}`);
  }
  const found = [];
  const walk = (absolute, prefix) => {
    for (const entry of readdirSync(absolute, { withFileTypes: true })) {
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        walk(join(absolute, entry.name), relativePath);
      } else {
        found.push(relativePath);
      }
    }
  };
  walk(fixturesDir, '');
  found.sort(comparePaths);
  return found;
}

function comparePaths(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

// An evidence string is '<repo-relative path>[:<line>] <free-text label>'.
// Only the file part is enforced (test files move); the line number is
// documentation of where the evidence was read at the audit's base commit.
export function evidenceFilePath(evidence) {
  const token = evidence.trim().split(/\s+/)[0] ?? '';
  const match = token.match(/^(.+):(\d+)$/);
  return match ? match[1] : token;
}

// Checks the classification list against the real directory enumeration.
// Returns { ok, problems, summary }; problems are { kind, detail } and the
// summary counts fixtures, categories, wired entries, and known gaps.
export function runCoverageCheck({ repoRoot, fixturesDir, manifest }) {
  const problems = [];
  const push = (kind, detail) => problems.push({ kind, detail });

  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return {
      ok: false,
      problems: [{ kind: 'io', detail: 'manifest is not a JSON object' }],
      summary: null,
    };
  }
  if (manifest.schemaVersion !== 1) {
    push('io', `manifest schemaVersion must be 1, got ${JSON.stringify(manifest.schemaVersion)}`);
  }
  const fixtures = manifest.fixtures;
  if (!Array.isArray(fixtures)) {
    push('io', 'manifest fixtures must be an array');
    return { ok: false, problems, summary: null };
  }

  let onDisk;
  try {
    onDisk = enumerateFixtureFiles(fixturesDir);
  } catch (error) {
    push('io', String(error.message ?? error));
    return { ok: false, problems, summary: null };
  }

  const byPath = new Map();
  let previousPath = null;
  for (const [index, entry] of fixtures.entries()) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      push('invalid-entry', `fixtures[${index}] is not an object`);
      continue;
    }
    const path = entry.path;
    if (typeof path !== 'string' || path.length === 0) {
      push('invalid-entry', `fixtures[${index}].path must be a non-empty string`);
      continue;
    }
    if (byPath.has(path)) {
      push('duplicate-entry', `${path} is classified at indexes ${byPath.get(path)} and ${index}`);
      continue;
    }
    byPath.set(path, index);
    if (previousPath !== null && comparePaths(previousPath, path) >= 0) {
      push('unsorted-entry', `${path} must come after ${previousPath}; keep the list sorted`);
    }
    previousPath = path;
    validateEntry(entry, repoRoot, push);
  }

  const listed = new Set(byPath.keys());
  for (const path of onDisk) {
    if (!listed.has(path)) push('unknown-fixture', `${path} exists in the fixtures directory but is not classified`);
  }
  for (const path of listed) {
    if (!onDisk.includes(path)) push('missing-fixture', `${path} is classified but does not exist in the fixtures directory`);
  }

  const classified = [...byPath.keys()];
  const summary = {
    fixtures: classified.length,
    onDisk: onDisk.length,
    byCategory: {},
    wired: 0,
    knownGaps: 0,
    gapStages: {},
  };
  for (const path of classified) {
    const entry = fixtures[byPath.get(path)];
    if (!entry || typeof entry !== 'object') continue;
    summary.byCategory[entry.category] = (summary.byCategory[entry.category] ?? 0) + 1;
    if (entry.windowsStatus === 'wired') summary.wired += 1;
    else {
      summary.knownGaps += 1;
      if (typeof entry.gapStage === 'string') {
        summary.gapStages[entry.gapStage] = (summary.gapStages[entry.gapStage] ?? 0) + 1;
      }
    }
  }

  return { ok: problems.length === 0, problems, summary };
}

function validateEntry(entry, repoRoot, push) {
  const path = entry.path;
  if (typeof path === 'string' && path.length > 0) {
    if (path.includes('\\') || path.startsWith('/') || path.split('/').includes('..')) {
      push('invalid-entry', `${path}: fixture paths must be '/'-separated and stay inside the fixtures directory`);
    }
  }
  if (!CATEGORY_VALUES.includes(entry.category)) {
    push('invalid-entry', `${path ?? '<missing path>'}: unknown category ${JSON.stringify(entry.category)}`);
  }
  if (!OUTCOME_VALUES.includes(entry.outcome)) {
    push('invalid-entry', `${path ?? '<missing path>'}: unknown outcome ${JSON.stringify(entry.outcome)}`);
  }
  if (!WINDOWS_STATUS_VALUES.includes(entry.windowsStatus)) {
    push('invalid-entry', `${path ?? '<missing path>'}: unknown windowsStatus ${JSON.stringify(entry.windowsStatus)}`);
  }
  checkEvidence(entry.path, entry.coreEvidence, 'coreEvidence', repoRoot, push, entry.category !== 'signature-vectors');
  checkEvidence(entry.path, entry.windowsEvidence, 'windowsEvidence', repoRoot, push, true);

  const wired = entry.windowsStatus === 'wired';
  if (wired) {
    if (!Array.isArray(entry.windowsEvidence) || entry.windowsEvidence.length === 0) {
      push('invalid-entry', `${path}: windowsStatus "wired" requires at least one windowsEvidence entry`);
    }
    if (entry.gapStage !== null && entry.gapStage !== undefined) {
      push('invalid-entry', `${path}: a wired fixture must not carry gapStage`);
    }
    if (entry.gapDetail !== null && entry.gapDetail !== undefined) {
      push('invalid-entry', `${path}: a wired fixture must not carry gapDetail`);
    }
  } else if (WINDOWS_STATUS_VALUES.includes(entry.windowsStatus)) {
    if (typeof entry.gapStage !== 'string' || !GAP_STAGE_PATTERN.test(entry.gapStage)) {
      push('invalid-entry', `${path}: a known gap must name a roadmap stage (M0-M10), got ${JSON.stringify(entry.gapStage)}`);
    }
    if (typeof entry.gapDetail !== 'string' || entry.gapDetail.trim().length === 0) {
      push('invalid-entry', `${path}: a known gap must describe what is missing in gapDetail`);
    }
  }
}

function checkEvidence(path, evidence, field, repoRoot, push, required) {
  if (evidence === undefined) {
    if (required) push('invalid-entry', `${path ?? '<missing path>'}: ${field} is required`);
    return;
  }
  if (!Array.isArray(evidence)) {
    push('invalid-entry', `${path ?? '<missing path>'}: ${field} must be an array of strings`);
    return;
  }
  if (required && field === 'coreEvidence' && evidence.length === 0) {
    push('invalid-entry', `${path}: coreEvidence must name at least one Core-side reference`);
    return;
  }
  for (const item of evidence) {
    if (typeof item !== 'string' || item.trim().length === 0) {
      push('invalid-entry', `${path ?? '<missing path>'}: ${field} entries must be non-empty strings`);
      continue;
    }
    const file = evidenceFilePath(item);
    if (file.length === 0) {
      push('invalid-entry', `${path}: ${field} entry does not start with a file path: ${item}`);
      continue;
    }
    if (!existsSync(join(repoRoot, ...file.split('/')))) {
      push('evidence-path', `${path}: ${field} references a missing file: ${file}`);
    }
  }
}

// Fixture-set drift is the failure CI cannot fix by rerunning; point the
// person reading a red check at the one file that resolves it.
const FIXTURE_SET_PROBLEMS = new Set(['unknown-fixture', 'missing-fixture', 'duplicate-entry', 'unsorted-entry']);

function printReport(result) {
  const { problems, summary } = result;
  for (const problem of problems) console.error(`${problem.kind}: ${problem.detail}`);
  if (problems.some((problem) => FIXTURE_SET_PROBLEMS.has(problem.kind))) {
    console.error('hint: register or clean up fixtures in scripts/plugins/plugin-fixture-coverage.json; the maintenance rules are section 6 of docs/development/windows-plugin-fixture-coverage.md');
  }
  if (summary) {
    const stages = Object.entries(summary.gapStages)
      .sort(comparePaths)
      .map(([stage, count]) => `${stage}:${count}`)
      .join(' ');
    console.log(
      `fixtures=${summary.fixtures} onDisk=${summary.onDisk} wired=${summary.wired} knownGaps=${summary.knownGaps}` +
        (stages ? ` gapStages(${stages})` : ''),
    );
  }
}

function main() {
  const { values } = parseArgs({
    options: {
      manifest: { type: 'string' },
      'repo-root': { type: 'string' },
      'fixtures-dir': { type: 'string' },
    },
  });
  const repoRoot = values['repo-root'] ?? defaultRepoRoot();
  const manifestPath = values.manifest ?? join(repoRoot, 'scripts/plugins/plugin-fixture-coverage.json');

  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    console.error(`io: cannot read manifest ${manifestPath}: ${error.message}`);
    process.exitCode = 1;
    return;
  }

  const fixturesDir =
    values['fixtures-dir'] ??
    (typeof manifest.fixturesDirectory === 'string' ? join(repoRoot, ...manifest.fixturesDirectory.split('/')) : null);
  if (!fixturesDir) {
    console.error('io: manifest fixturesDirectory is missing and --fixtures-dir was not given');
    process.exitCode = 1;
    return;
  }

  const result = runCoverageCheck({ repoRoot, fixturesDir, manifest });
  printReport(result);
  process.exitCode = result.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
