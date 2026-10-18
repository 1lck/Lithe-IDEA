import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runProcess } from '../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const source = readFileSync(new URL('../.github/workflows/cancel-closed-pr-runs.yml', import.meta.url), 'utf8');
const shell = source.split('        run: |\n')[1].split('\n').map((line) => line.slice(10)).join('\n');
const repository = fileURLToPath(new URL('../', import.meta.url));
const options = { timeout: 15_000 };
const closedAt = '2026-10-18T14:00:00Z';
const active = (id, extra = {}) => ({
  id, status: 'queued', event: 'pull_request', head_sha: `old-head-${id}`,
  head_branch: 'feature', head_repository: { full_name: 'owner/repo' },
  created_at: '2026-10-18T13:00:00Z', pull_requests: [], ...extra,
});

async function cleanup(t, runs, failures = {}) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-closed-ci-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const executable = join(root, 'gh');
  const calls = join(root, 'calls.jsonl');
  // Only this fake executable can reach the cleanup shell. It serves multiple
  // API pages and records mutations; an unexpected request fails immediately.
  writeFileSync(executable, `#!${process.execPath}
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_CALLS, JSON.stringify(args) + '\\n');
const runs = JSON.parse(process.env.FAKE_RUNS);
const failures = JSON.parse(process.env.FAKE_FAILURES);
const path = args.find(arg => arg.startsWith('repos/'));
if (path === 'repos/owner/repo/actions/runs') {
  const status = args.find(arg => arg.startsWith('status=')).slice(7);
  if (failures.listing === status) process.exit(42);
  const selected = runs.filter(run => run.status === status);
  console.log(JSON.stringify({ workflow_runs: selected }));
  console.log(JSON.stringify({ workflow_runs: selected.slice(0, 1) }));
} else {
  const match = path?.match(/actions\\/runs\\/(\\d+)(\\/force-cancel)?$/);
  if (!match) process.exit(43);
  if (match[2]) process.exit(failures.cancel ? 44 : 0);
  console.log(failures.status ?? 'completed');
}
`);
  chmodSync(executable, 0o755);
  let terminate;
  let result;
  try {
    result = await runProcess({
      command: 'bash', args: ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', shell],
      cwd: repository, timeoutMs: 5_000,
      env: {
        PATH: `${root}${delimiter}${process.env.PATH}`, GITHUB_REPOSITORY: 'owner/repo',
        HEAD_REF: 'feature', HEAD_REPOSITORY: 'owner/repo', PR_NUMBER: '123', CLOSED_AT: closedAt,
        FAKE_RUNS: JSON.stringify(runs), FAKE_CALLS: calls, FAKE_FAILURES: JSON.stringify(failures),
      },
      onSpawn: (process) => { terminate = process.terminate; },
    });
  } finally {
    if (terminate) assert.equal(await terminate(), true, 'cleanup shell and descendants must terminate');
  }
  assert.equal(result.timedOut, false, result.stderr);
  return { ...result, calls: readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse) };
}

test('closing a PR cancels paginated historical heads while preserving other work', options, async (t) => {
  const runs = ['queued', 'in_progress', 'waiting', 'pending', 'requested'].map((status, index) => active(101 + index, { status }));
  runs.push(
    active(201, { head_repository: { full_name: 'another/fork' } }),
    active(202, { head_branch: 'other-feature' }),
    active(203, { event: 'push' }),
    active(204, { event: 'workflow_dispatch' }),
    active(205, { created_at: '2026-10-18T14:00:01Z' }),
    active(206, { pull_requests: [{ number: 999 }] }),
    active(207, { pull_requests: [{ number: 123 }, { number: 999 }] }),
    active(106, { created_at: closedAt, pull_requests: [{ number: 123 }] }),
    active(107, { pull_requests: null }),
  );
  const result = await cleanup(t, runs);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.calls.filter(args => args.includes('POST')).map(args => args.find(arg => arg.startsWith('repos/'))),
    [101, 102, 103, 104, 105, 106, 107].map(id => `repos/owner/repo/actions/runs/${id}/force-cancel`));
  for (const args of result.calls.filter(args => args.includes('GET'))) {
    assert.ok(args.includes('--paginate'));
    assert.ok(args.includes('branch=feature'));
  }
  assert.doesNotMatch(source, /head_sha=|actions\/checkout/);
});

test('a cancellation race is accepted only after the run completed', options, async (t) => {
  const result = await cleanup(t, [active(101)], { cancel: true, status: 'completed' });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /finished before it could be cancelled/);
});

test('cancellation failures for an active run fail the cleanup check', options, async (t) => {
  const result = await cleanup(t, [active(101)], { cancel: true, status: 'in_progress' });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Could not cancel active run 101/);
});

test('listing failures fail cleanup instead of reporting success', options, async (t) => {
  const result = await cleanup(t, [], { listing: 'queued' });
  assert.notEqual(result.code, 0);
});
