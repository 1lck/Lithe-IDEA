import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArguments, run } from '../../../.agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs';
import { verifyRustShards } from './verify-rust-shards.mjs';

const names = Array.from({ length: 101 }, (_, index) => `tests::case_${index}`);
const options = { timeout: 15000 };

async function runFixture(t, args = [], enumeration = names) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-shard-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const config = parseArguments(['--manifest', join(root, 'Cargo.toml'), '--report', join(root, 'report.json'), ...args]);
  let clock = 0;
  await run(config, {
    now: () => clock,
    runProcessImpl: async ({ args, onStdoutLine }) => {
      clock += 1;
      if (onStdoutLine) onStdoutLine(JSON.stringify({ reason: 'compiler-artifact', profile: { test: true },
        executable: join(root, 'test-binary'), manifest_path: config.manifest, target: { name: 'core' } }));
      else if (args[0] !== '--list') assert.ok(enumeration.includes(args[1]));
      return { code: 0, timedOut: false, durationMs: 1, stderr: '',
        stdout: args[0] === '--list' ? enumeration.map(name => `${name}: test`).join('\n') : 'running 1 test\n' };
    },
  });
  return JSON.parse(readFileSync(config.report, 'utf8'));
}

test('two real runner shards cover the original suite exactly once regardless of enumeration order', options, async t => {
  const first = await runFixture(t, ['--shard-index', '1', '--shard-count', '2']);
  const second = await runFixture(t, ['--shard-index', '2', '--shard-count', '2'], [...names].reverse());
  assert.equal(verifyRustShards([first, second]), names.length);
  assert.ok(first.tests.length > 20 && second.tests.length > 20);
  assert.equal(first.buildDurationMs, 1);
  for (const report of [first, second]) assert.ok(report.tests.every(item => item.maxMs === 15000));
  assert.throws(() => verifyRustShards([first]), /Missing/);
  assert.throws(() => verifyRustShards([first, first]), /duplicate/);
  const missing = structuredClone(second);
  missing.tests.pop();
  assert.throws(() => verifyRustShards([first, missing]), /Incomplete Rust coverage/);
  const mismatch = structuredClone(second);
  mismatch.inventory.pop();
  assert.throws(() => verifyRustShards([first, mismatch]), /different tests/);
  const failed = structuredClone(second);
  failed.tests[0].status = 'timeout';
  assert.throws(() => verifyRustShards([first, failed]), /Failed Rust test/);
});

test('native integration prefix avoids rerunning ordinary Core tests and rejects a typo', options, async t => {
  const report = await runFixture(t, ['--test-prefix', 'tests::native::'], ['tests::unit', 'tests::native::java']);
  assert.deepEqual(report.tests.map(item => item.name), ['tests::native::java']);
  assert.equal(report.selection.testPrefix, 'tests::native::');
  await assert.rejects(runFixture(t, ['--test-prefix', 'missing::']), /No Rust tests/);
});

test('invalid shard coordinates fail before compilation', options, () => {
  for (const args of [['--shard-index', '0'], ['--shard-count', '0'], ['--shard-index', '3', '--shard-count', '2'], ['--test-prefix']]) {
    assert.throws(() => parseArguments(['--manifest', 'rust/Cargo.toml', ...args]));
  }
});
