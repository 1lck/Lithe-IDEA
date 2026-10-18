import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isCiInfrastructure, parseClassification, planLaneReuse, planOutputs } from './plan-ci-lane-reuse.mjs';

const classifier = fileURLToPath(new URL('./classify-ci-changes.sh', import.meta.url));

// A throwaway repository with the real classifier: `preview` plus a pull
// request branch. Every git call has a deadline; nothing touches the network.
function fixtureRepository(t) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-lane-reuse-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', timeout: 10000 }).trim();
  const write = (path, text) => { mkdirSync(join(root, dirname(path)), { recursive: true }); writeFileSync(join(root, path), `${text}\n`); };
  const commit = (message) => { git('add', '-A'); git('-c', 'user.email=ci@example.invalid', '-c', 'user.name=CI', 'commit', '-q', '-m', message); return git('rev-parse', 'HEAD'); };
  mkdirSync(join(root, 'scripts'));
  copyFileSync(classifier, join(root, 'scripts/classify-ci-changes.sh'));
  git('init', '-q', '-b', 'preview');
  git('config', 'gc.auto', '0');
  write('macos/Sources/Lithe/App.swift', 'struct App {}');
  write('macos/Sources/Lithe/Other.swift', 'struct Other {}');
  write('rust/lithe-core/src/lib.rs', 'pub fn value() -> u8 { 1 }');
  write('README.md', '# Test');
  write('.github/workflows/ci-macos.yml', 'name: macOS CI');
  const base = commit('base');
  git('checkout', '-q', '-b', 'feature');
  return { root, git, write, commit, base };
}

// Fake GitHub API: one workflow listing, per-run jobs, base tips by time, and
// recorded cancellations. Unknown paths fail like a real API error would.
function fakeGitHub({ runs = [], jobs = {}, baseTips = [], failListing = false }) {
  const cancelled = [];
  const fetchImpl = async (url, { method = 'GET' } = {}) => {
    const { pathname, searchParams } = new URL(url);
    const reply = (body, status = 200) => ({ ok: status < 300, status, json: async () => body });
    if (pathname.endsWith('/runs') && pathname.includes('/workflows/')) return failListing ? reply({}, 500) : reply({ workflow_runs: runs });
    const jobMatch = pathname.match(/\/actions\/runs\/(\d+)\/jobs$/);
    if (jobMatch) return reply({ jobs: jobs[jobMatch[1]] ?? [] });
    const cancelMatch = pathname.match(/\/actions\/runs\/(\d+)\/cancel$/);
    if (cancelMatch && method === 'POST') { cancelled.push(Number(cancelMatch[1])); return reply(null, 202); }
    if (pathname.endsWith('/commits')) {
      const until = new Date(searchParams.get('until'));
      const tip = [...baseTips].reverse().find((item) => new Date(item.at) <= until);
      return reply(tip ? [{ sha: tip.sha }] : []);
    }
    return reply({}, 404);
  };
  return { fetchImpl, cancelled };
}

const job = (id, name, status, conclusion) => ({ id, name, status, conclusion, html_url: `https://example.invalid/job/${id}` });
// Fixture run ids double as run numbers; the planned run is number 50.
const run = (id, headSha, status, createdAt) => ({ id, run_number: id, head_sha: headSha, status, created_at: createdAt, head_repository: { full_name: 'owner/repo' } });
const fullMacJobs = (offset, conclusion = 'success', status = 'completed') => [
  job(offset + 1, 'Swift tests', status, status === 'completed' ? conclusion : null),
  job(offset + 2, 'Rust Core tests', status, status === 'completed' ? conclusion : null),
  job(offset + 3, 'Release package verification (arm64)', status, status === 'completed' ? conclusion : null),
];

function classify(fixture, base, head) {
  const env = { ...process.env, LITHE_CI_SCOPE: 'pull_request' };
  delete env.LITHE_CI_ONLY_PATHS;
  return parseClassification(execFileSync('bash', [join(fixture.root, 'scripts/classify-ci-changes.sh'), base, head], { cwd: fixture.root, encoding: 'utf8', env, timeout: 10000 }));
}

async function plan(fixture, { head, base = fixture.base, github, event = 'pull_request' }) {
  return planLaneReuse({
    env: {
      LITHE_CI_WORKFLOW: 'macos', LITHE_CI_WORKFLOW_FILE: 'ci-macos.yml', GITHUB_EVENT_NAME: event, GITHUB_TOKEN: 't',
      GITHUB_REPOSITORY: 'owner/repo', GITHUB_API_URL: 'https://api.invalid', GITHUB_RUN_ID: '999', GITHUB_RUN_NUMBER: '50',
      PR_BASE_SHA: base, PR_BASE_REF: 'preview', PR_HEAD_SHA: head, PR_HEAD_REF: 'feature', PR_HEAD_REPOSITORY: 'owner/repo',
    },
    outputs: classify(fixture, base, head),
    repoRoot: fixture.root,
    fetchImpl: github.fetchImpl,
    log: { warn() {} },
  });
}

test('a small follow-up commit reuses every lane that already passed', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  f.write('rust/lithe-core/src/lib.rs', 'pub fn value() -> u8 { 2 }');
  const first = f.commit('swift and rust');
  f.write('README.md', '# Updated docs');
  const second = f.commit('docs');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: fullMacJobs(100) }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.deepEqual(result.run, { swift: false, rust: false, release: false });
  assert.deepEqual(Object.keys(result.reuse).sort(), ['release', 'rust', 'swift']);
  assert.equal(result.reuse.swift.job_id, 101);
  assert.match(planOutputs('macos', result), /^run_swift=false\nrun_rust=false\nrun_release=false\nreuse=\{/);
});

test('a follow-up commit reruns only the lanes its own changes affect', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  f.write('rust/lithe-core/src/lib.rs', 'pub fn value() -> u8 { 2 }');
  const first = f.commit('swift and rust');
  f.write('macos/Sources/Lithe/Other.swift', 'struct Other { let b = 2 }');
  const second = f.commit('more swift');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: fullMacJobs(100) }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
  assert.equal(result.run.rust, false);
  assert.equal(result.run.release, false);
});

test('a lane still running in the earlier run is reused and that run is kept', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  f.write('rust/lithe-core/src/lib.rs', 'pub fn value() -> u8 { 2 }');
  const first = f.commit('swift and rust');
  f.write('macos/Sources/Lithe/Other.swift', 'struct Other { let b = 2 }');
  const second = f.commit('more swift');
  const github = fakeGitHub({ runs: [run(10, first, 'in_progress', '2026-10-17T01:00:00Z')], jobs: { 10: fullMacJobs(100, null, 'in_progress') }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
  assert.equal(result.reuse.rust.status, 'in_progress');
  assert.deepEqual(github.cancelled, []);
});

test('an earlier run no lane reuses is cancelled', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 2 }');
  const second = f.commit('swift again');
  const github = fakeGitHub({ runs: [run(10, first, 'in_progress', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'in_progress', null)] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
  assert.deepEqual(github.cancelled, [10]);
});

test('unstarted jobs and unfinished self-hosted jobs rerun instead of blocking a gate', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.write('README.md', '# Docs');
  const second = f.commit('docs');
  for (const status of ['queued', 'waiting', 'pending', 'requested', 'in_progress']) {
    for (const labels of [['macos-26'], ['self-hosted', 'macOS', 'lithe-mac-mini']]) {
      if (status === 'in_progress' && labels[0] === 'macos-26') continue;
      const github = fakeGitHub({
        runs: [run(10, first, 'in_progress', '2026-10-17T01:00:00Z')],
        jobs: { 10: [{ ...job(101, 'Swift tests', status, null), labels }] },
        baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }],
      });
      const result = await plan(f, { head: second, github });
      assert.equal(result.run.swift, true, `${status}: ${labels}`);
      assert.deepEqual(result.reuse, {});
      assert.deepEqual(github.cancelled, [10]);
    }
  }
});

test('a run created after this one is neither cancelled nor reused', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 2 }');
  const second = f.commit('swift again');
  f.write('README.md', '# Docs');
  const third = f.commit('docs');
  // Run 60 belongs to a newer push and has no test job yet; this planner for
  // the older revision starts late and sees it in the listing.
  const github = fakeGitHub({
    runs: [run(60, third, 'in_progress', '2026-10-17T03:00:00Z'), run(10, first, 'in_progress', '2026-10-17T01:00:00Z')],
    jobs: { 60: [], 10: [job(101, 'Swift tests', 'in_progress', null)] },
    baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }],
  });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
  assert.deepEqual(github.cancelled, [10]);
});

test('a change to a file with a Chinese name is not mistaken for no change', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/示例 "quoted".swift', 'struct Example {}');
  const first = f.commit('add chinese file');
  f.write('macos/Sources/Lithe/示例 "quoted".swift', 'struct Example { let changed = true }');
  const second = f.commit('change chinese file');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', 'success')] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
  assert.deepEqual(result.reuse, {});
});

test('an executable bit change alone reruns the lanes the file affects', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.git('update-index', '--chmod=+x', 'macos/Sources/Lithe/App.swift');
  f.git('-c', 'user.email=ci@example.invalid', '-c', 'user.name=CI', 'commit', '-q', '-m', 'mode only');
  const second = f.git('rev-parse', 'HEAD');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', 'success')] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
  const result = await plan(f, { head: second, github });
  assert.equal(result.run.swift, true);
});

test('a base change to a member crate manifest reruns every lane', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.git('checkout', '-q', 'preview');
  f.write('rust/lithe-core/Cargo.toml', '[package]\nname = "lithe-core"\n[features]\nextra = []');
  const newBase = f.commit('crate features');
  f.git('checkout', '-q', 'feature');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', 'success')] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }, { at: '2026-10-17T02:00:00Z', sha: newBase }] });
  const result = await plan(f, { head: first, base: newBase, github });
  assert.equal(result.run.swift, true);
  assert.deepEqual(result.reuse, {});
});

test('merging an ordinary base change keeps every result', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.git('checkout', '-q', 'preview');
  f.write('rust/lithe-core/src/lib.rs', 'pub fn value() -> u8 { 9 }');
  const newBase = f.commit('someone else');
  f.git('checkout', '-q', 'feature');
  f.git('-c', 'user.email=ci@example.invalid', '-c', 'user.name=CI', 'merge', '-q', '--no-edit', 'preview');
  const merged = f.git('rev-parse', 'HEAD');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', 'success')] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }, { at: '2026-10-17T02:00:00Z', sha: newBase }] });
  const result = await plan(f, { head: merged, base: newBase, github });
  assert.equal(result.run.swift, false);
  assert.equal(result.reuse.swift.job_id, 101);
});

test('a base change to CI infrastructure reruns every lane, even without a merge', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.git('checkout', '-q', 'preview');
  f.write('.github/workflows/ci-macos.yml', 'name: macOS CI changed');
  const newBase = f.commit('ci change');
  f.git('checkout', '-q', 'feature');
  const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', 'success')] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }, { at: '2026-10-17T02:00:00Z', sha: newBase }] });
  const result = await plan(f, { head: first, base: newBase, github });
  assert.equal(result.run.swift, true);
  assert.deepEqual(result.reuse, {});
});

test('a failed or cancelled earlier result is never reused', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.write('README.md', '# Docs');
  const second = f.commit('docs');
  for (const conclusion of ['failure', 'cancelled']) {
    const github = fakeGitHub({ runs: [run(10, first, 'completed', '2026-10-17T01:00:00Z')], jobs: { 10: [job(101, 'Swift tests', 'completed', conclusion)] }, baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }] });
    const result = await plan(f, { head: second, github });
    assert.equal(result.run.swift, true, conclusion);
  }
});

test('a lane skipped in the latest run is traced to the run that executed it', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  f.write('README.md', '# Docs');
  const second = f.commit('docs');
  f.write('README.md', '# Docs again');
  const third = f.commit('docs again');
  const github = fakeGitHub({
    runs: [run(11, second, 'completed', '2026-10-17T02:00:00Z'), run(10, first, 'completed', '2026-10-17T01:00:00Z')],
    jobs: { 11: [job(201, 'Swift tests', 'completed', 'skipped')], 10: [job(101, 'Swift tests', 'completed', 'success')] },
    baseTips: [{ at: '2026-10-17T00:00:00Z', sha: f.base }],
  });
  const result = await plan(f, { head: third, github });
  assert.equal(result.reuse.swift.job_id, 101);
});

test('planning failures and non pull request events run every selected lane', async (t) => {
  const f = fixtureRepository(t);
  f.write('macos/Sources/Lithe/App.swift', 'struct App { let a = 1 }');
  const first = f.commit('swift');
  const broken = await plan(f, { head: first, github: fakeGitHub({ failListing: true }) });
  assert.equal(broken.run.swift, true);
  assert.match(broken.reason, /planning failed/);
  const firstRun = await plan(f, { head: first, github: fakeGitHub({}) });
  assert.match(firstRun.reason, /no earlier run of this pull request executed them/);
  const push = await plan(f, { head: first, github: fakeGitHub({}), event: 'push' });
  assert.equal(push.run.swift, true);
  assert.deepEqual(push.reuse, {});
});

test('CI infrastructure paths are recognised', () => {
  for (const path of ['.github/workflows/ci-macos.yml', 'scripts/classify-ci-changes.sh', 'scripts/test-macos.sh', 'Package.resolved', 'rust/Cargo.lock', 'rust/lithe-core/Cargo.toml', 'windows/tauri/crates/project/Cargo.toml', 'windows/tauri/rust-toolchain.toml', '.agents/skills/write-stable-tests/scripts/x.sh']) {
    assert.equal(isCiInfrastructure(path), true, path);
  }
  for (const path of ['macos/Sources/Lithe/App.swift', 'README.md', 'rust/lithe-core/src/lib.rs']) {
    assert.equal(isCiInfrastructure(path), false, path);
  }
});
