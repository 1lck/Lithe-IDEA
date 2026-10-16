#!/usr/bin/env node
// Chooses a runner pool for each selected macOS lane from the jobs that are
// already running or queued in this repository. GitHub fixes runs-on when a job
// is created, so the choice happens once in the Linux classify job; a lane that
// later waits cannot move to the other pool.
//
// Decision record:
// .agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const MAC_MINI_RUNNER = ['self-hosted', 'macOS', 'ARM64', 'lithe-mac-mini'];
export const HOSTED_MACOS_RUNNER = 'macos-26';
const MAC_MINI_LABEL = 'lithe-mac-mini';

// Each Mac mini runner keeps its own build outputs between jobs, so lanes that
// share a build configuration prefer the same runners. Debug lanes share one
// SwiftPM test build and debug Rust Core; packaging owns the release build. The
// labels are assigned to the runners in GitHub; capacities are their counts.
export const MAC_MINI_GROUPS = Object.freeze({
  debug: { label: 'lithe-mac-mini-debug', capacity: 2 },
  release: { label: 'lithe-mac-mini-release', capacity: 1 },
});
const LANE_GROUP = Object.freeze({ swift: 'debug', plugins: 'debug', rust: 'debug', release: 'release' });

// Pools are 'hosted' or 'mac-mini-<group>'.
const miniPool = (group) => `mac-mini-${group}`;
const groupOfPool = (pool) => (pool.startsWith('mac-mini-') ? pool.slice('mac-mini-'.length) : null);

// The routing used before dynamic selection, and whenever the API cannot be
// read: heavy compilation lanes on the Mac minis, the rest on hosted runners.
export const STATIC_POOLS = Object.freeze({
  swift: 'hosted',
  release: miniPool('release'),
  rust: miniPool('debug'),
  plugins: 'hosted',
});

// Lanes that stay on hosted runners until the Mac minis can run them. Swift
// tests need a WindowServer session that publishes native windows
// (DesktopIsolationTests); a Mac mini without an active display does not.
// Remove the lane here once the runner host keeps a display session awake.
export const HOSTED_ONLY_LANES = new Set(['swift']);

// Lanes claim free runners in this order. Swift tests own the longest critical
// path once they also verify the Rust bridge, so they get the faster pool first.
const LANE_PRIORITY = ['swift', 'release', 'plugins', 'rust'];

const ACTIVE_JOB_STATUSES = new Set(['queued', 'in_progress', 'waiting', 'pending', 'requested']);
const REQUEST_TIMEOUT_MS = 15000;
const MAX_RUNS_INSPECTED = 40;

export function poolOfJob(job) {
  const labels = (job.labels ?? []).map((label) => String(label).toLowerCase());
  if (labels.includes(MAC_MINI_LABEL)) return 'mac-mini';
  if (labels.some((label) => label.startsWith('macos-'))) return 'hosted';
  return null;
}

// Mac mini jobs count against the whole pool and, when they requested a group
// label, against that group. Jobs from older workflow revisions request only
// the shared label and may occupy any runner, so the pool total stays binding.
export function countBusyRunners(jobs) {
  const busy = { 'mac-mini': 0, hosted: 0, groups: Object.fromEntries(Object.keys(MAC_MINI_GROUPS).map((g) => [g, 0])) };
  for (const job of jobs) {
    if (!ACTIVE_JOB_STATUSES.has(job.status)) continue;
    const pool = poolOfJob(job);
    if (!pool) continue;
    busy[pool] += 1;
    if (pool !== 'mac-mini') continue;
    const labels = (job.labels ?? []).map((label) => String(label).toLowerCase());
    for (const [group, { label }] of Object.entries(MAC_MINI_GROUPS)) {
      if (labels.includes(label)) busy.groups[group] += 1;
    }
  }
  return busy;
}

// Pull requests take a free runner in their preferred Mac mini group, then the
// other group, then a free hosted runner. Pushes and manual runs stay on the
// Mac minis even when they are busy, so a merge never takes a hosted runner
// that a pull request is waiting for.
export function assignPools({ lanes, busy, capacity, macMiniOnly }) {
  const used = { 'mac-mini': busy['mac-mini'], hosted: busy.hosted, groups: { ...(busy.groups ?? {}) } };
  for (const group of Object.keys(MAC_MINI_GROUPS)) used.groups[group] ??= 0;
  const groupHasRoom = (group) => used['mac-mini'] < capacity['mac-mini']
    && used.groups[group] < MAC_MINI_GROUPS[group].capacity;
  const pools = {};
  const ordered = LANE_PRIORITY.filter((lane) => lanes.includes(lane));
  for (const lane of ordered) {
    const preferred = LANE_GROUP[lane];
    const other = Object.keys(MAC_MINI_GROUPS).find((group) => group !== preferred);
    let pool;
    if (HOSTED_ONLY_LANES.has(lane)) {
      pool = 'hosted';
    } else if (groupHasRoom(preferred)) {
      pool = miniPool(preferred);
    } else if (groupHasRoom(other)) {
      pool = miniPool(other);
    } else if (macMiniOnly) {
      pool = miniPool(preferred);
    } else if (used.hosted < capacity.hosted) {
      pool = 'hosted';
    } else {
      // Both pools are full: join the shorter queue relative to its size.
      const miniPressure = (used['mac-mini'] + 1) / capacity['mac-mini'];
      const hostedPressure = (used.hosted + 1) / capacity.hosted;
      pool = hostedPressure < miniPressure ? 'hosted' : miniPool(preferred);
    }
    const group = groupOfPool(pool);
    if (group) {
      used['mac-mini'] += 1;
      used.groups[group] += 1;
    } else {
      used.hosted += 1;
    }
    pools[lane] = pool;
  }
  return pools;
}

export function runnersFor(pools) {
  const runners = {};
  for (const lane of Object.keys(STATIC_POOLS)) {
    const group = groupOfPool(pools[lane] ?? STATIC_POOLS[lane]);
    runners[lane] = group ? [...MAC_MINI_RUNNER, MAC_MINI_GROUPS[group].label] : HOSTED_MACOS_RUNNER;
  }
  return runners;
}

function positiveInteger(name, value, fallback) {
  if (value === undefined || value === '') return fallback;
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${name} must be a positive integer`);
  return Number(value);
}

export function parseLanes(value) {
  const lanes = (value ?? '').split(',').map((lane) => lane.trim()).filter(Boolean);
  for (const lane of lanes) {
    if (!(lane in STATIC_POOLS)) throw new Error(`Unknown macOS lane: ${lane}`);
  }
  return lanes;
}

async function requestJSON(url, token, fetchImpl) {
  const response = await fetchImpl(url, {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28',
    },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`GitHub API ${response.status} for ${new URL(url).pathname}`);
  return response.json();
}

export async function listActiveMacJobs({ apiURL, repository, token, currentRunID, fetchImpl = fetch }) {
  const runs = [];
  for (const status of ['in_progress', 'queued']) {
    const page = await requestJSON(
      `${apiURL}/repos/${repository}/actions/runs?status=${status}&per_page=100`, token, fetchImpl);
    runs.push(...(page.workflow_runs ?? []));
  }
  const runIDs = [...new Set(runs.map((run) => run.id))]
    .filter((id) => String(id) !== String(currentRunID))
    .slice(0, MAX_RUNS_INSPECTED);
  const pages = await Promise.all(runIDs.map((id) => requestJSON(
    `${apiURL}/repos/${repository}/actions/runs/${id}/jobs?filter=latest&per_page=100`, token, fetchImpl)));
  return pages.flatMap((page) => page.jobs ?? []);
}

export async function selectRunners(env, fetchImpl = fetch) {
  const lanes = parseLanes(env.LITHE_MACOS_LANES);
  const capacity = {
    'mac-mini': positiveInteger('LITHE_MAC_MINI_CAPACITY', env.LITHE_MAC_MINI_CAPACITY, 3),
    hosted: positiveInteger('LITHE_HOSTED_MACOS_CAPACITY', env.LITHE_HOSTED_MACOS_CAPACITY, 5),
  };
  const macMiniOnly = env.GITHUB_EVENT_NAME !== 'pull_request';
  if (lanes.length === 0) {
    return { runners: runnersFor({}), pools: {}, busy: null, reason: 'no macOS lane selected' };
  }
  if (macMiniOnly) {
    const pools = assignPools({ lanes, busy: { 'mac-mini': 0, hosted: 0 }, capacity, macMiniOnly });
    return { runners: runnersFor(pools), pools, busy: null, reason: `${env.GITHUB_EVENT_NAME} runs use the Mac minis only` };
  }
  try {
    if (!env.GITHUB_TOKEN) throw new Error('GITHUB_TOKEN is not available');
    const jobs = await listActiveMacJobs({
      apiURL: env.GITHUB_API_URL || 'https://api.github.com',
      repository: env.GITHUB_REPOSITORY,
      token: env.GITHUB_TOKEN,
      currentRunID: env.GITHUB_RUN_ID,
      fetchImpl,
    });
    const busy = countBusyRunners(jobs);
    const pools = assignPools({ lanes, busy, capacity, macMiniOnly });
    return { runners: runnersFor(pools), pools, busy, reason: 'chosen from active jobs' };
  } catch (error) {
    const pools = Object.fromEntries(lanes.map((lane) => [lane, STATIC_POOLS[lane]]));
    return { runners: runnersFor(pools), pools, busy: null, reason: `static fallback: ${error.message}` };
  }
}

function summaryMarkdown({ pools, busy, reason }) {
  const lines = ['### macOS runner selection', '', `Reason: ${reason}`];
  if (busy) {
    const groups = Object.entries(busy.groups).map(([group, count]) => `${group} ${count}`).join(', ');
    lines.push('', `Active jobs before this run: Mac mini ${busy['mac-mini']} (${groups}), hosted ${busy.hosted}`);
  }
  const lanes = Object.keys(pools);
  if (lanes.length > 0) {
    lines.push('', '| Lane | Pool |', '| --- | --- |', ...lanes.map((lane) => `| ${lane} | ${pools[lane]} |`));
  }
  return `${lines.join('\n')}\n`;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = await selectRunners(process.env);
  const output = `runners=${JSON.stringify(result.runners)}\n`;
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, output);
  else process.stdout.write(output);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summaryMarkdown(result));
  if (result.reason.startsWith('static fallback')) console.log(`::warning title=macOS runner selection::${result.reason}`);
  console.error(summaryMarkdown(result));
}
