import test from 'node:test';
import assert from 'node:assert/strict';
import {
  HOSTED_MACOS_RUNNER,
  MAC_MINI_RUNNER,
  assignPools,
  countBusyRunners,
  parseLanes,
  runnersFor,
  selectRunners,
} from './select-macos-ci-runners.mjs';

const capacity = { 'mac-mini': 3, hosted: 5 };
const miniJob = (status) => ({ status, labels: [...MAC_MINI_RUNNER] });
const hostedJob = (status) => ({ status, labels: [HOSTED_MACOS_RUNNER] });

// Answers the two run listings and each run's job listing from fixtures; no
// request leaves the process.
function fakeGitHub(runsByStatus, jobsByRun) {
  const requested = [];
  const fetchImpl = async (url) => {
    const { pathname, searchParams } = new URL(url);
    requested.push(pathname + (searchParams.has('status') ? `?status=${searchParams.get('status')}` : ''));
    const jobsMatch = pathname.match(/\/actions\/runs\/(\d+)\/jobs$/);
    const body = jobsMatch
      ? { jobs: jobsByRun[jobsMatch[1]] ?? [] }
      : { workflow_runs: (runsByStatus[searchParams.get('status')] ?? []).map((id) => ({ id })) };
    return { ok: true, status: 200, json: async () => body };
  };
  return { fetchImpl, requested };
}

const pullRequestEnv = {
  GITHUB_EVENT_NAME: 'pull_request',
  GITHUB_TOKEN: 'fixture-token',
  GITHUB_REPOSITORY: 'example/lithe',
  GITHUB_API_URL: 'https://api.example.invalid',
  GITHUB_RUN_ID: '100',
};

test('only active macOS jobs occupy a pool', () => {
  const busy = countBusyRunners([
    miniJob('in_progress'), miniJob('queued'), miniJob('completed'),
    hostedJob('in_progress'), { status: 'in_progress', labels: ['ubuntu-latest'] },
  ]);
  assert.deepEqual(busy, { 'mac-mini': 2, hosted: 1 });
});

test('pull requests fill free Mac minis first, then hosted runners', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust', 'plugins', 'release'], busy: { 'mac-mini': 1, hosted: 0 }, capacity, macMiniOnly: false }),
    { release: 'mac-mini', plugins: 'mac-mini', rust: 'hosted' });
});

test('a full Mac mini pool sends work to free hosted runners', () => {
  assert.deepEqual(
    assignPools({ lanes: ['release', 'plugins'], busy: { 'mac-mini': 3, hosted: 3 }, capacity, macMiniOnly: false }),
    { release: 'hosted', plugins: 'hosted' });
});

test('when both pools are full a lane joins the relatively shorter queue', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust'], busy: { 'mac-mini': 5, hosted: 5 }, capacity, macMiniOnly: false }),
    { rust: 'hosted' });
  assert.deepEqual(
    assignPools({ lanes: ['rust'], busy: { 'mac-mini': 3, hosted: 7 }, capacity, macMiniOnly: false }),
    { rust: 'mac-mini' });
});

test('pushes and manual runs never take a hosted runner for Mac mini lanes', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust', 'release', 'plugins'], busy: { 'mac-mini': 3, hosted: 0 }, capacity, macMiniOnly: true }),
    { release: 'mac-mini', plugins: 'mac-mini', rust: 'mac-mini' });
});

test('hosted-only lanes stay hosted and do not consume a Mac mini slot', () => {
  assert.deepEqual(
    assignPools({ lanes: ['swift', 'release', 'plugins', 'rust'], busy: { 'mac-mini': 1, hosted: 0 }, capacity, macMiniOnly: false }),
    { swift: 'hosted', release: 'mac-mini', plugins: 'mac-mini', rust: 'hosted' });
  assert.deepEqual(
    assignPools({ lanes: ['swift'], busy: { 'mac-mini': 0, hosted: 9 }, capacity, macMiniOnly: true }),
    { swift: 'hosted' });
});

test('every lane receives a valid runs-on value', () => {
  assert.deepEqual(runnersFor({ swift: 'mac-mini' }), {
    swift: MAC_MINI_RUNNER, release: MAC_MINI_RUNNER, rust: MAC_MINI_RUNNER, plugins: HOSTED_MACOS_RUNNER,
  });
});

test('lane lists reject unknown names', () => {
  assert.deepEqual(parseLanes(' swift, rust ,'), ['swift', 'rust']);
  assert.throws(() => parseLanes('swift,windows'), /Unknown macOS lane: windows/);
});

test('selection counts jobs of other active runs and skips the current run', async () => {
  const { fetchImpl, requested } = fakeGitHub(
    { in_progress: [100, 101], queued: [101, 102] },
    { 100: [miniJob('in_progress'), miniJob('in_progress'), miniJob('in_progress')],
      101: [miniJob('in_progress'), miniJob('in_progress')], 102: [hostedJob('queued')] });
  const result = await selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'release,rust' }, fetchImpl);
  assert.deepEqual(result.busy, { 'mac-mini': 2, hosted: 1 });
  assert.deepEqual(result.pools, { release: 'mac-mini', rust: 'hosted' });
  assert.ok(!requested.some((path) => path.includes('/runs/100/')));
});

test('API failures fall back to the static routing', async () => {
  const fetchImpl = async () => ({ ok: false, status: 403, json: async () => ({}) });
  const result = await selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'swift,rust' }, fetchImpl);
  assert.match(result.reason, /^static fallback: GitHub API 403/);
  assert.deepEqual(result.pools, { swift: 'hosted', rust: 'mac-mini' });
  assert.deepEqual(result.runners.swift, HOSTED_MACOS_RUNNER);
});

test('a missing token falls back without contacting GitHub', async () => {
  const { fetchImpl, requested } = fakeGitHub({}, {});
  const result = await selectRunners({ ...pullRequestEnv, GITHUB_TOKEN: '', LITHE_MACOS_LANES: 'plugins' }, fetchImpl);
  assert.match(result.reason, /GITHUB_TOKEN is not available/);
  assert.deepEqual(requested, []);
});

test('pushes choose the Mac minis without reading the API', async () => {
  const { fetchImpl, requested } = fakeGitHub({}, {});
  const result = await selectRunners({ ...pullRequestEnv, GITHUB_EVENT_NAME: 'push', LITHE_MACOS_LANES: 'swift,rust' }, fetchImpl);
  assert.deepEqual(result.pools, { swift: 'hosted', rust: 'mac-mini' });
  assert.deepEqual(requested, []);
});

test('invalid capacities fail instead of silently routing', async () => {
  await assert.rejects(
    selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'swift', LITHE_MAC_MINI_CAPACITY: '0' }),
    /LITHE_MAC_MINI_CAPACITY must be a positive integer/);
});
