import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  defaultManifestPath,
  defaultRepoRoot,
  enumerateFixtureFiles,
  evidenceFilePath,
  runCoverageCheck,
} from './check-plugin-fixture-coverage.mjs';

// A throwaway repository shaped like the real one: a fixtures directory, a
// classification manifest, and evidence files the manifest can point at.
// Every wait is synchronous filesystem work, so the tests are deterministic
// and clean their temp roots through t.after on success and failure alike.
function tempRepo(t) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-fixture-coverage-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const fixturesDirectory = 'shared/contracts/plugins/v1/fixtures';
  const fixturesDir = join(root, ...fixturesDirectory.split('/'));
  return {
    root,
    fixturesDir,
    fixturesDirectory,
    writeFixture(relativePath) {
      mkdirSync(dirname(join(fixturesDir, ...relativePath.split('/'))), { recursive: true });
      writeFileSync(join(fixturesDir, ...relativePath.split('/')), '{}\n');
    },
    writeManifest(entries, extra = {}) {
      const manifestPath = join(root, 'scripts', 'plugin-fixture-coverage.json');
      mkdirSync(dirname(manifestPath), { recursive: true });
      writeFileSync(
        manifestPath,
        JSON.stringify({ schemaVersion: 1, fixturesDirectory, fixtures: entries, ...extra }, null, 2),
      );
    },
    check() {
      const manifest = JSON.parse(readFileSync(join(root, 'scripts', 'plugin-fixture-coverage.json'), 'utf8'));
      return runCoverageCheck({ repoRoot: root, fixturesDir, manifest });
    },
  };
}

// Evidence strings are repo-relative, like the real manifest's.
const fixtureEvidence = (relativePath) => `shared/contracts/plugins/v1/fixtures/${relativePath}:1 exists`;

function entry(path, overrides = {}) {
  const evidence = [fixtureEvidence(path)];
  return {
    path,
    category: 'valid-manifest',
    outcome: 'success',
    coreEvidence: evidence,
    windowsEvidence: evidence,
    windowsStatus: 'wired',
    gapStage: null,
    gapDetail: null,
    ...overrides,
  };
}

const kinds = (result) => result.problems.map((problem) => problem.kind);

test('a matching manifest and directory pass with an honest summary', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.plugin.json');
  repo.writeFixture('nested/b.json');
  repo.writeManifest([
    entry('a.plugin.json'),
    entry('nested/b.json', {
      category: 'marketplace',
      windowsStatus: 'unwired',
      gapStage: 'M2',
      gapDetail: 'no Windows consumer yet',
      windowsEvidence: [],
    }),
  ]);
  const result = repo.check();
  assert.equal(result.ok, true);
  assert.deepEqual(result.problems, []);
  assert.equal(result.summary.fixtures, 2);
  assert.equal(result.summary.wired, 1);
  assert.equal(result.summary.knownGaps, 1);
  assert.deepEqual(result.summary.gapStages, { M2: 1 });
  assert.deepEqual(result.summary.byCategory, { 'valid-manifest': 1, marketplace: 1 });
});

test('a new file in the fixtures directory fails as unknown', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('classified.json');
  repo.writeFixture('surprise.plugin.json');
  repo.writeManifest([entry('classified.json')]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['unknown-fixture']);
  assert.match(result.problems[0].detail, /surprise\.plugin\.json/);
});

test('a classified file that no longer exists fails as missing', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('present.json');
  repo.writeManifest([
    entry('present.json'),
    // Its evidence points at a surviving file so only the missing fixture is reported.
    entry('removed.json', {
      coreEvidence: [fixtureEvidence('present.json')],
      windowsEvidence: [fixtureEvidence('present.json')],
    }),
  ]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['missing-fixture']);
  assert.match(result.problems[0].detail, /removed\.json/);
});

test('classifying the same fixture twice fails', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeManifest([entry('a.json'), entry('a.json')]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['duplicate-entry']);
});

test('an unsorted list fails so diffs stay reviewable', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeFixture('b.json');
  repo.writeManifest([entry('b.json'), entry('a.json')]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['unsorted-entry']);
});

test('incoherent entries fail: unknown enums, wired without evidence, gap without stage', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeFixture('b.json');
  repo.writeFixture('c.json');
  repo.writeFixture('d.json');
  repo.writeManifest([
    entry('a.json', { category: 'mystery', windowsStatus: 'indirect-core', gapStage: 'M4', gapDetail: 'x', windowsEvidence: [] }),
    entry('b.json', { windowsEvidence: [] }),
    entry('c.json', { windowsStatus: 'indirect-core', gapDetail: 'stage forgotten', windowsEvidence: [] }),
    entry('d.json', { coreEvidence: [] }),
  ]);
  const result = repo.check();
  assert.equal(result.ok, false);
  const details = result.problems.map((problem) => problem.detail);
  assert.ok(details.some((detail) => detail.includes('unknown category "mystery"')), details.join('\n'));
  assert.ok(details.some((detail) => detail.includes('b.json: windowsStatus "wired" requires')), details.join('\n'));
  assert.ok(details.some((detail) => detail.includes('c.json: a known gap must name a roadmap stage')), details.join('\n'));
  assert.ok(details.some((detail) => detail.includes('d.json: coreEvidence must name')), details.join('\n'));
});

test('a wired fixture must not carry gap fields and a gap must describe the miss', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeFixture('b.json');
  repo.writeManifest([
    entry('a.json', { gapStage: 'M4', gapDetail: 'stray' }),
    entry('b.json', { windowsStatus: 'unwired', gapStage: 'M4', gapDetail: '  ' }),
  ]);
  const result = repo.check();
  assert.equal(result.ok, false);
  const details = result.problems.map((problem) => problem.detail);
  assert.ok(details.some((detail) => detail.includes('a.json: a wired fixture must not carry gapStage')), details.join('\n'));
  assert.ok(details.some((detail) => detail.includes('b.json: a known gap must describe')), details.join('\n'));
});

test('evidence must point at files that exist in the repository', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeManifest([
    entry('a.json', {
      coreEvidence: ['rust/lithe-core/src/tests/gone.rs:12 vanished'],
      windowsEvidence: [fixtureEvidence('a.json')],
    }),
  ]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['evidence-path']);
  assert.match(result.problems[0].detail, /rust\/lithe-core\/src\/tests\/gone\.rs/);
});

test('fixture paths must stay inside the fixtures directory', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  repo.writeManifest([entry('../outside.json')]);
  const result = repo.check();
  assert.equal(result.ok, false);
  assert.ok(kinds(result).includes('invalid-entry'), kinds(result).join(', '));
  assert.ok(result.problems.some((problem) => /stay inside the fixtures directory/.test(problem.detail)));
  // The escaping path must not silently pass the set comparison either.
  assert.ok(kinds(result).includes('unknown-fixture'), 'a.json on disk goes unclassified');
  assert.ok(kinds(result).includes('missing-fixture'), 'the escaped entry matches no file');
});

test('a missing fixtures directory is an io problem, not a crash', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'lithe-fixture-coverage-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const result = runCoverageCheck({
    repoRoot: root,
    fixturesDir: join(root, 'does-not-exist'),
    manifest: { schemaVersion: 1, fixtures: [] },
  });
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['io']);
  assert.equal(result.summary, null);
});

test('a non-object manifest is an io problem', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('a.json');
  const result = runCoverageCheck({ repoRoot: repo.root, fixturesDir: repo.fixturesDir, manifest: [] });
  assert.equal(result.ok, false);
  assert.deepEqual(kinds(result), ['io']);
});

test('enumeration is recursive, uses / separators, and is sorted', (t) => {
  const repo = tempRepo(t);
  repo.writeFixture('zeta.json');
  repo.writeFixture('nested/deep/gamma.json');
  repo.writeFixture('alpha.json');
  assert.deepEqual(enumerateFixtureFiles(repo.fixturesDir), [
    'alpha.json',
    'nested/deep/gamma.json',
    'zeta.json',
  ]);
});

test('evidence parsing keeps the file part and drops the line number', () => {
  assert.equal(evidenceFilePath('rust/lithe-core/src/tests/vcs.rs:65 a name'), 'rust/lithe-core/src/tests/vcs.rs');
  assert.equal(evidenceFilePath('windows/tauri/src-tauri/src/plugin_host/tests.rs name'), 'windows/tauri/src-tauri/src/plugin_host/tests.rs');
  assert.equal(evidenceFilePath('shared/contracts/plugins/v1/fixtures/x.json'), 'shared/contracts/plugins/v1/fixtures/x.json');
});

// The enforcement test: the real manifest must match the real fixtures
// directory right now, and its known gaps must stay explicit. When this test
// fails, classify the new fixture or clean the stale entry - never weaken
// this assertion to make a change pass.
test('the real fixture directory and classification list agree', () => {
  const repoRoot = defaultRepoRoot();
  const manifest = JSON.parse(readFileSync(defaultManifestPath(), 'utf8'));
  const fixturesDir = join(repoRoot, ...manifest.fixturesDirectory.split('/'));
  const result = runCoverageCheck({ repoRoot, fixturesDir, manifest });
  assert.equal(result.ok, true, result.problems.map((problem) => `${problem.kind}: ${problem.detail}`).join('\n'));
  assert.ok(result.summary.fixtures >= 30, `expected the full fixture set, got ${result.summary.fixtures}`);
  assert.ok(result.summary.knownGaps > 0, 'the audit documents real gaps; a zero-gap manifest means the statuses were flattened');
  for (const fixture of manifest.fixtures) {
    if (fixture.windowsStatus !== 'wired') {
      assert.match(fixture.gapStage, /^M(10|[1-9])$/, `${fixture.path} gap stage`);
      assert.ok(fixture.gapDetail.trim().length > 0, `${fixture.path} gap detail`);
    }
  }
});
