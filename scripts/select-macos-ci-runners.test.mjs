import test from 'node:test';
import assert from 'node:assert/strict';
import {
  HOSTED_MACOS_RUNNER,
  MAC_MINI_GROUPS,
  MAC_MINI_RUNNER,
  assignPools,
  countBusyRunners,
  parseLanes,
  runnersFor,
  selectRunners,
} from './select-macos-ci-runners.mjs';

const capacity = { 'mac-mini': 3, hosted: 5 };
const DEBUG = [...MAC_MINI_RUNNER, MAC_MINI_GROUPS.debug.label];
const RELEASE = [...MAC_MINI_RUNNER, MAC_MINI_GROUPS.release.label];
const miniJob = (status, labels = DEBUG) => ({ status, labels: [...labels] });
const hostedJob = (status) => ({ status, labels: [HOSTED_MACOS_RUNNER] });
const busyOf = (debug, release, hosted, shared = 0) => (
  { 'mac-mini': debug + release + shared, hosted, groups: { debug, release } });

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

test('only active macOS jobs occupy a pool, and group labels occupy their group', () => {
  const busy = countBusyRunners([
    miniJob('in_progress'), miniJob('queued', RELEASE), miniJob('completed'),
    miniJob('in_progress', MAC_MINI_RUNNER),
    hostedJob('in_progress'), { status: 'in_progress', labels: ['ubuntu-latest'] },
  ]);
  assert.deepEqual(busy, busyOf(1, 1, 1, 1));
});

test('lanes take a free runner in the group that holds their build outputs', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust', 'plugins', 'release'], busy: busyOf(0, 0, 0), capacity, macMiniOnly: false }),
    { release: 'mac-mini-release', plugins: 'mac-mini-debug', rust: 'mac-mini-debug' });
});

test('a full preferred group borrows a free runner from the other group', () => {
  assert.deepEqual(
    assignPools({ lanes: ['plugins', 'release'], busy: busyOf(2, 0, 0), capacity, macMiniOnly: false }),
    { release: 'mac-mini-release', plugins: 'hosted' });
  assert.deepEqual(
    assignPools({ lanes: ['plugins'], busy: busyOf(2, 0, 0), capacity, macMiniOnly: false }),
    { plugins: 'mac-mini-release' });
  assert.deepEqual(
    assignPools({ lanes: ['release'], busy: busyOf(1, 1, 0), capacity, macMiniOnly: false }),
    { release: 'mac-mini-debug' });
});

test('jobs on the shared label keep the whole Mac mini pool bounded', () => {
  assert.deepEqual(
    assignPools({ lanes: ['plugins'], busy: busyOf(0, 0, 0, 3), capacity, macMiniOnly: false }),
    { plugins: 'hosted' });
});

test('a full Mac mini pool sends work to free hosted runners', () => {
  assert.deepEqual(
    assignPools({ lanes: ['release', 'plugins'], busy: busyOf(2, 1, 3), capacity, macMiniOnly: false }),
    { release: 'hosted', plugins: 'hosted' });
});

test('when both pools are full a lane joins the relatively shorter queue', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust'], busy: busyOf(4, 1, 5), capacity, macMiniOnly: false }),
    { rust: 'hosted' });
  assert.deepEqual(
    assignPools({ lanes: ['rust'], busy: busyOf(2, 1, 7), capacity, macMiniOnly: false }),
    { rust: 'mac-mini-debug' });
});

test('pushes and manual runs never take a hosted runner for Mac mini lanes', () => {
  assert.deepEqual(
    assignPools({ lanes: ['rust', 'release', 'plugins'], busy: busyOf(2, 1, 0), capacity, macMiniOnly: true }),
    { release: 'mac-mini-release', plugins: 'mac-mini-debug', rust: 'mac-mini-debug' });
});

test('hosted-only lanes stay hosted and do not consume a Mac mini slot', () => {
  assert.deepEqual(
    assignPools({ lanes: ['swift', 'release', 'plugins', 'rust'], busy: busyOf(1, 0, 0), capacity, macMiniOnly: false }),
    { swift: 'hosted', release: 'mac-mini-release', plugins: 'mac-mini-debug', rust: 'hosted' });
  assert.deepEqual(
    assignPools({ lanes: ['swift'], busy: busyOf(0, 0, 9), capacity, macMiniOnly: true }),
    { swift: 'hosted' });
});

test('every lane receives a valid runs-on value', () => {
  assert.deepEqual(runnersFor({ plugins: 'mac-mini-debug' }), {
    swift: HOSTED_MACOS_RUNNER, release: RELEASE, rust: DEBUG, plugins: DEBUG,
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
      101: [miniJob('in_progress'), miniJob('in_progress', RELEASE)], 102: [hostedJob('queued')] });
  const result = await selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'release,rust' }, fetchImpl);
  assert.deepEqual(result.busy, busyOf(1, 1, 1));
  assert.deepEqual(result.pools, { release: 'mac-mini-debug', rust: 'hosted' });
  assert.ok(!requested.some((path) => path.includes('/runs/100/')));
});

test('API failures fall back to the static routing', async () => {
  const fetchImpl = async () => ({ ok: false, status: 403, json: async () => ({}) });
  const result = await selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'swift,rust' }, fetchImpl);
  assert.match(result.reason, /^static fallback: GitHub API 403/);
  assert.deepEqual(result.pools, { swift: 'hosted', rust: 'mac-mini-debug' });
  assert.deepEqual(result.runners.swift, HOSTED_MACOS_RUNNER);
  assert.deepEqual(result.runners.rust, DEBUG);
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
  assert.deepEqual(result.pools, { swift: 'hosted', rust: 'mac-mini-debug' });
  assert.deepEqual(requested, []);
});

test('invalid capacities fail instead of silently routing', async () => {
  await assert.rejects(
    selectRunners({ ...pullRequestEnv, LITHE_MACOS_LANES: 'swift', LITHE_MAC_MINI_CAPACITY: '0' }),
    /LITHE_MAC_MINI_CAPACITY must be a positive integer/);
});
