import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const optionsFile = fileURLToPath(new URL('./macos-swift-build-options.sh', import.meta.url));

function argumentsFor(value) {
  const env = { ...process.env };
  delete env.LITHE_SWIFT_BUILD_JOBS;
  if (value !== undefined) env.LITHE_SWIFT_BUILD_JOBS = value;
  // Exercise actual zsh array expansion, including its empty-array behavior.
  // Every child has a local deadline; no compiler or network is started.
  return spawnSync('/bin/zsh', ['-f', '-c',
    'set -euo pipefail; source "$1"; args=(build "${LITHE_SWIFT_BUILD_ARGS[@]}" --configuration debug); printf "%s\\n" "${args[@]}"',
    'options-test', optionsFile], { env, encoding: 'utf8', timeout: 5000 });
}

test('hosted and local builds keep SwiftPM defaults', () => {
  for (const value of [undefined, '']) {
    const result = argumentsFor(value);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'build\n--configuration\ndebug\n');
  }
});

test('shared runners pass a positive compilation budget as separate arguments', () => {
  for (const value of ['2', '12']) {
    const result = argumentsFor(value);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `build\n--jobs\n${value}\n--configuration\ndebug\n`);
  }
});

test('invalid budgets fail before a compiler can start', () => {
  for (const value of ['0', '-2', '1.5', 'two', '2 --disable-sandbox', '2\n3']) {
    const result = argumentsFor(value);
    assert.equal(result.status, 2, `${value}: ${result.stderr}`);
    assert.match(result.stderr, /must be a positive integer/);
    assert.equal(result.stdout, '');
  }
});
