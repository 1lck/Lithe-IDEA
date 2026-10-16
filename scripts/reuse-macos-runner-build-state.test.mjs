import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./reuse-macos-runner-build-state.sh', import.meta.url));

// Every child has a local deadline; only git and file operations run, inside a
// temporary repository that each test removes.
function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 10000 });
  assert.equal(result.error, undefined, result.error?.message);
  return result;
}

function fixtureRepository(t) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-runner-state-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'scripts'));
  copyFileSync(script, join(root, 'scripts/reuse-macos-runner-build-state.sh'));
  writeFileSync(join(root, 'tracked.txt'), 'tracked\n');
  for (const args of [['init', '-q'], ['add', '.'],
    ['-c', 'user.email=ci@example.invalid', '-c', 'user.name=CI', 'commit', '-q', '-m', 'base']]) {
    assert.equal(run('git', args, root).status, 0);
  }
  return root;
}

function write(root, path, contents = 'x\n') {
  mkdirSync(join(root, path, '..'), { recursive: true });
  writeFileSync(join(root, path), contents);
}

// A low free-space floor keeps the fixtures independent of the host's disk.
function reuse(root, ...args) {
  const floor = args.length > 0 && !args.includes('--min-free-gb') ? ['--min-free-gb', '1'] : [];
  return run('/bin/zsh', ['-f', 'scripts/reuse-macos-runner-build-state.sh', ...args, ...floor], root);
}

test('keeps build outputs and dependency stores while removing other untracked files', (t) => {
  const root = fixtureRepository(t);
  assert.equal(reuse(root, '--identity', 'xcode-a').status, 0);
  for (const kept of ['.build/debug/module.o', 'rust/target/macos/lib.a', '.artifacts/cargo-home/registry/cache/a.crate',
    '.artifacts/swiftpm-cache/repositories/a', '.artifacts/jdtls-downloads/a', '.artifacts/jdk-downloads/a']) {
    write(root, kept);
  }
  write(root, 'macos/Sources/Lithe/Stale.swift');
  write(root, '.artifacts/test-stability/old.json');
  write(root, 'dist/Lithe.dmg');

  const result = reuse(root, '--identity', 'xcode-a');
  assert.equal(result.status, 0, result.stderr);
  for (const kept of ['.build/debug/module.o', 'rust/target/macos/lib.a', '.artifacts/cargo-home/registry/cache/a.crate',
    '.artifacts/swiftpm-cache/repositories/a', '.artifacts/jdtls-downloads/a', '.artifacts/jdk-downloads/a', 'tracked.txt']) {
    assert.ok(existsSync(join(root, kept)), `${kept} should be kept`);
  }
  for (const removed of ['macos/Sources/Lithe/Stale.swift', '.artifacts/test-stability/old.json', 'dist/Lithe.dmg']) {
    assert.ok(!existsSync(join(root, removed)), `${removed} should be removed`);
  }
});

test('a toolchain change discards compilation outputs but keeps verified downloads', (t) => {
  const root = fixtureRepository(t);
  assert.equal(reuse(root, '--identity', 'xcode-a').status, 0);
  write(root, '.build/debug/module.o');
  write(root, 'rust/target/macos/lib.a');
  write(root, '.artifacts/cargo-home/registry/cache/a.crate');

  const result = reuse(root, '--identity', 'xcode-b');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /toolchain identity changed/);
  assert.ok(!existsSync(join(root, '.build/debug/module.o')));
  assert.ok(!existsSync(join(root, 'rust/target')));
  assert.ok(existsSync(join(root, '.artifacts/cargo-home/registry/cache/a.crate')));
  assert.equal(reuse(root, '--identity', 'xcode-b').stdout.includes('Discarding'), false);
});

test('build state without a recorded identity is not trusted', (t) => {
  const root = fixtureRepository(t);
  write(root, '.build/debug/module.o');
  const result = reuse(root, '--identity', 'xcode-a');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /no toolchain identity recorded/);
  assert.ok(!existsSync(join(root, '.build/debug/module.o')));
});

test('invalid arguments fail before anything is removed', (t) => {
  const root = fixtureRepository(t);
  write(root, 'untracked.txt');
  for (const args of [[], ['--identity', 'a', '--limit-gb', '0'], ['--identity', 'a', '--min-free-gb', 'ten']]) {
    const result = reuse(root, ...args);
    assert.equal(result.status, 2, `${args.join(' ')}: ${result.stderr}`);
  }
  assert.ok(existsSync(join(root, 'untracked.txt')));
});
