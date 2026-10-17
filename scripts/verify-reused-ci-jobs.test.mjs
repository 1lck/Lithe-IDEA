import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyReusedJobs } from './verify-reused-ci-jobs.mjs';

// Job states are replayed from a script; the clock and sleep are virtual, so
// no test waits in real time and the deadline is fully deterministic.
function scripted(states) {
  const reads = {};
  const fetchImpl = async (url) => {
    const id = url.match(/jobs\/(\d+)$/)[1];
    const sequence = states[id];
    const index = Math.min(reads[id] = (reads[id] ?? -1) + 1, sequence.length - 1);
    const state = sequence[index];
    return state === 'missing' ? { ok: false, status: 404, json: async () => ({}) } : { ok: true, status: 200, json: async () => ({ html_url: `job/${id}`, ...state }) };
  };
  let clock = 0;
  return { fetchImpl, now: () => clock, sleep: async (ms) => { clock += ms; }, reads };
}

const silent = { log() {} };
const verify = (reuse, harness, timeoutMs = 10_000) => verifyReusedJobs({ reuse, repository: 'o/r', token: 't', apiURL: 'https://api.invalid',
  fetchImpl: harness.fetchImpl, now: harness.now, sleep: harness.sleep, timeoutMs, pollMs: 1_000, log: silent });

test('passed reused jobs are accepted without waiting', async () => {
  const harness = scripted({ 1: [{ status: 'completed', conclusion: 'success' }] });
  assert.deepEqual(await verify({ swift: { job_id: 1 } }, harness), []);
  assert.equal(harness.reads[1], 0);
});

test('a running reused job is awaited until it passes', async () => {
  const harness = scripted({ 1: [{ status: 'in_progress' }, { status: 'in_progress' }, { status: 'completed', conclusion: 'success' }] });
  assert.deepEqual(await verify({ rust: { job_id: 1 } }, harness), []);
  assert.equal(harness.reads[1], 2);
});

test('a reused job that fails, is cancelled, or cannot be read fails the gate', async () => {
  const harness = scripted({ 1: [{ status: 'completed', conclusion: 'failure' }], 2: [{ status: 'completed', conclusion: 'cancelled' }], 3: ['missing'] });
  const failures = await verify({ swift: { job_id: 1 }, rust: { job_id: 2 }, release: { job_id: 3 } }, harness);
  assert.equal(failures.length, 3);
  assert.match(failures[0], /^swift: .*concluded failure/);
  assert.match(failures[1], /^rust: .*concluded cancelled/);
  assert.match(failures[2], /^release: could not read/);
});

test('a reused job still running at the deadline fails the gate', async () => {
  const harness = scripted({ 1: [{ status: 'in_progress' }] });
  const failures = await verify({ swift: { job_id: 1 } }, harness, 3_000);
  assert.match(failures[0], /did not finish before the gate deadline/);
});
