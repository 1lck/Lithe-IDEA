// Tests for board-cache.sh against a local bare repository standing in for GitHub. Each test
// gets its own fixture: the bare remote, a checkout that holds main and the script, and a second
// single-branch clone playing the next workflow run. Nothing touches the network.
//
//   node --test scripts/ci/deploy-agent-notes-board/board-cache.test.mjs
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { runProcess } from '../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const SCRIPT = 'scripts/ci/deploy-agent-notes-board/board-cache.sh';
const CACHE = '.artifacts/agent-notes-board/cache/github.json';
const BRANCH = 'refs/heads/engineering-board-cache';
const GIT_TIMEOUT_MS = 10_000;
const SCRIPT_TIMEOUT_MS = 15_000;

// The user's global and system Git settings (signing, hooks, default branch) stay out of it.
const ENV = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 'Dev', GIT_AUTHOR_EMAIL: 'dev@example.invalid',
  GIT_COMMITTER_NAME: 'Dev', GIT_COMMITTER_EMAIL: 'dev@example.invalid' };
for (const name of ['GITHUB_STEP_SUMMARY', 'GITHUB_SHA', 'GITHUB_SERVER_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID',
  'BOARD_CACHE_REMOTE']) delete ENV[name];

const git = (cwd, ...args) => execFileSync('git', args, { cwd, env: ENV, encoding: 'utf8', timeout: GIT_TIMEOUT_MS }).trim();

function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'lithe-board-cache-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const remote = path.join(root, 'remote.git');
  const first = path.join(root, 'first');
  git(root, 'init', '--quiet', '--bare', '--initial-branch=main', remote);
  git(root, 'init', '--quiet', '--initial-branch=main', first);
  mkdirSync(path.join(first, path.dirname(SCRIPT)), { recursive: true });
  copyFileSync(new URL('./board-cache.sh', import.meta.url), path.join(first, SCRIPT));
  git(first, 'add', SCRIPT);
  git(first, 'commit', '--quiet', '-m', 'main');
  git(first, 'remote', 'add', 'origin', remote);
  git(first, 'push', '--quiet', 'origin', 'main');
  const clone = (name) => {
    const dir = path.join(root, name);
    git(root, 'clone', '--quiet', '--single-branch', '--branch', 'main', remote, dir);
    return dir;
  };
  return { remote, first, clone };
}

async function run(checkout, action, env = {}) {
  const result = await runProcess({ command: 'bash', args: [SCRIPT, action], cwd: checkout, env: { ...ENV, ...env },
    timeoutMs: SCRIPT_TIMEOUT_MS, maxCapturedBytes: 65536 });
  assert.equal(result.timedOut, false, `board-cache.sh ${action} timed out`);
  assert.equal(result.terminationConfirmed, true);
  return result;
}

function writeCache(checkout, text) {
  mkdirSync(path.join(checkout, path.dirname(CACHE)), { recursive: true });
  writeFileSync(path.join(checkout, CACHE), text);
}

const remoteTip = (remote) => {
  const line = git(remote, 'ls-remote', '--heads', remote, BRANCH);
  return line ? line.split(/\s+/)[0] : '';
};

const CACHE_V1 = '{"schema":1,"fetchedAt":"2026-03-01T00:00:00.000Z","repos":[],"watermarks":{},"items":{\n"a#1":{"title":"one"}\n}}\n';
const CACHE_V2 = CACHE_V1.replace('2026-03-01', '2026-03-02').replace('"one"', '"ONE"');

test('restore without the branch leaves the cache alone, and save creates the branch', async (t) => {
  const { remote, first } = fixture(t);
  const restored = await run(first, 'restore');
  assert.equal(restored.code, 0, restored.stderr);
  assert.match(restored.stdout, /does not exist yet/);
  assert.equal(existsSync(path.join(first, CACHE)), false);

  const missing = await run(first, 'save');
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /build the board before saving/);
  assert.equal(remoteTip(remote), '');

  writeCache(first, CACHE_V1);
  const saved = await run(first, 'save', { GITHUB_SHA: 'abc1234' });
  assert.equal(saved.code, 0, saved.stderr);
  const tip = remoteTip(remote);
  assert.match(saved.stdout, new RegExp(`Saved the board cache to engineering-board-cache ${tip.slice(0, 12)}`));
  assert.equal(git(remote, 'ls-tree', '--name-only', tip), 'README.md\ngithub.json');
  assert.equal(git(remote, 'show', `${tip}:github.json`) + '\n', CACHE_V1);
  assert.equal(git(remote, 'log', '--format=%P|%an|%s%n%b', tip),
    '|github-actions[bot]|Update engineering board cache\nFetched from GitHub at 2026-03-01T00:00:00.000Z; board built from abc1234.');
  // The data branch never moves main.
  assert.equal(git(remote, 'rev-parse', 'refs/heads/main'), git(first, 'rev-parse', 'HEAD'));
});

test('the next run restores the branch, saves on top of it and skips an unchanged cache', async (t) => {
  const { remote, first, clone } = fixture(t);
  writeCache(first, CACHE_V1);
  assert.equal((await run(first, 'save')).code, 0);
  const firstTip = remoteTip(remote);

  // A fresh checkout of main only, as the workflow makes, has no copy of the branch yet.
  const next = clone('next');
  const restored = await run(next, 'restore');
  assert.equal(restored.code, 0, restored.stderr);
  assert.match(restored.stdout, new RegExp(`Restored the board cache from engineering-board-cache ${firstTip.slice(0, 12)}`));
  assert.equal(readFileSync(path.join(next, CACHE), 'utf8'), CACHE_V1);

  const unchanged = await run(next, 'save');
  assert.equal(unchanged.code, 0, unchanged.stderr);
  assert.match(unchanged.stdout, /unchanged/);
  assert.equal(remoteTip(remote), firstTip);

  writeCache(next, CACHE_V2);
  const saved = await run(next, 'save');
  assert.equal(saved.code, 0, saved.stderr);
  const secondTip = remoteTip(remote);
  assert.equal(git(remote, 'rev-parse', `${secondTip}^`), firstTip);
  assert.equal(git(remote, 'show', `${secondTip}:github.json`) + '\n', CACHE_V2);

  // The first checkout still has the old tip locally; its save asks the remote again and builds
  // on the newer commit instead of forking the branch.
  writeCache(first, CACHE_V1.replace('"one"', '"later"'));
  const later = await run(first, 'save');
  assert.equal(later.code, 0, later.stderr);
  assert.equal(git(remote, 'rev-parse', `${remoteTip(remote)}^`), secondTip);
});

test('restore falls back to a full read when the remote cannot be asked', async (t) => {
  const { first } = fixture(t);
  writeCache(first, CACHE_V1);
  const restored = await run(first, 'restore', { BOARD_CACHE_REMOTE: path.join(first, 'missing.git') });
  assert.equal(restored.code, 0, restored.stderr);
  assert.match(restored.stdout, /Could not read engineering-board-cache/);
  assert.equal(readFileSync(path.join(first, CACHE), 'utf8'), CACHE_V1);
});
