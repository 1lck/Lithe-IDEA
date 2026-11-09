import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  evaluate,
  limitFor,
  main,
  parseBenchOutput,
  parseBudgets,
  parseSizeBytes,
  renderMarkdown,
  validateBudgets,
} from './editor-perf-report.mjs';

const SCRIPT = fileURLToPath(new URL('./editor-perf-report.mjs', import.meta.url));
const SHIPPED_BUDGETS = new URL('../../../desktop/benchmarks/editor-budgets.json', import.meta.url);
const REFERENCE_CPU = 'Apple M4';
const OTHER_CPU = 'Intel(R) Xeon(R) Platinum';
const NOT_JUDGED_CPU = 'not judged: CPU differs from the reference machine';
const SMALL = 'BenchmarkEditorViewPaint/go/100KiB';
const LARGE = 'BenchmarkEditorViewPaint/go/10MiB';

function result(nsPerOp, { bytes = 0, allocs = 0, metrics = {} } = {}) {
  return { samples: 1, nsPerOp, bytesPerOp: bytes, allocsPerOp: allocs, metrics };
}

function candidateOf(cpu, entries) {
  return {
    machine: { goos: 'darwin', goarch: 'arm64', cpu },
    results: new Map(Object.entries(entries)),
  };
}

function budgetsOf(...budgets) {
  return {
    schema: 1,
    referenceMachine: { label: 'm4-mbp', kind: 'physical', cpu: REFERENCE_CPU },
    budgets: budgets.map((budget) => ({ why: 'test budget', ...budget })),
  };
}

function benchHeader(cpu) {
  return `goos: darwin\ngoarch: arm64\npkg: example.com/editor\ncpu: ${cpu}\n`;
}

function benchLine(name, ns, bytes, allocs) {
  return `${name}-10 \t 100\t ${ns} ns/op\t ${bytes} B/op\t ${allocs} allocs/op\n`;
}

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'editor-perf-report-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function runCli(args) {
  return spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', timeout: 15_000 });
}

test('parseBenchOutput takes the median of repeated lines and strips the GOMAXPROCS suffix', () => {
  const text = [
    'goos: darwin',
    'goarch: arm64',
    'pkg: github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope',
    'cpu: Apple M4',
    'BenchmarkEditorRopeBuild/go/100KiB-10   \t    1000\t      3000 ns/op\t     512 B/op\t       4 allocs/op',
    'BenchmarkEditorRopeBuild/go/100KiB-10   \t    1000\t      1000 ns/op\t     512 B/op\t       4 allocs/op',
    'BenchmarkEditorRopeBuild/go/100KiB-10   \t    1000\t      2000 ns/op\t     768 B/op\t       6 allocs/op',
    'BenchmarkEditorViewPaint/go/10MiB-10 \t 50\t 10 ns/op\t 0 B/op\t 0 allocs/op',
    'BenchmarkEditorViewPaint/go/10MiB-10 \t 50\t 20 ns/op\t 0 B/op\t 0 allocs/op',
    'BenchmarkEditorViewMemory/go/10MiB-10 \t 1\t 3.5 retained-B\t 900 ns/op\t 5.00 MB/s\t 7 allocs/op',
    'BenchmarkEditorNoSuffix/100KiB \t 10\t 5 ns/op',
    'BenchmarkEditorBroken-10 \t --- FAIL',
    'pkg: example.com/other',
    'cpu: Intel(R) Core(TM)',
    'PASS',
    'ok  \tgithub.com/1lck/Lithe-IDEA/desktop/internal/editor/rope\t1.234s',
  ].join('\n');

  const { machine, results } = parseBenchOutput(text);

  assert.deepEqual(machine, { goos: 'darwin', goarch: 'arm64', cpu: 'Apple M4' });
  assert.deepEqual([...results.keys()], [
    'BenchmarkEditorRopeBuild/go/100KiB',
    'BenchmarkEditorViewPaint/go/10MiB',
    'BenchmarkEditorViewMemory/go/10MiB',
    'BenchmarkEditorNoSuffix/100KiB',
  ]);
  const build = results.get('BenchmarkEditorRopeBuild/go/100KiB');
  assert.equal(build.samples, 3);
  assert.equal(build.nsPerOp, 2000);
  assert.equal(build.bytesPerOp, 512);
  assert.equal(build.allocsPerOp, 4);
  assert.deepEqual(build.metrics, {});
  const paint = results.get('BenchmarkEditorViewPaint/go/10MiB');
  assert.equal(paint.samples, 2);
  assert.equal(paint.nsPerOp, 15);
});

test('parseBenchOutput collects custom metrics regardless of their position', () => {
  const text = 'BenchmarkEditorViewMemory/go/10MiB-10 \t 1\t 3.5 retained-B\t 900 ns/op\t 5.00 MB/s\t 7 allocs/op\n';

  const memory = parseBenchOutput(text).results.get('BenchmarkEditorViewMemory/go/10MiB');

  assert.equal(memory.nsPerOp, 900);
  assert.equal(memory.bytesPerOp, null);
  assert.equal(memory.allocsPerOp, 7);
  assert.deepEqual(memory.metrics, { 'retained-B': 3.5, 'MB/s': 5 });
});

test('parseBenchOutput reports no machine and no results for unrelated text', () => {
  const parsed = parseBenchOutput('FAIL\texample.com/editor [build failed]\n');

  assert.deepEqual(parsed.machine, { goos: null, goarch: null, cpu: null });
  assert.equal(parsed.results.size, 0);
});

test('parseSizeBytes reads the size segment of a benchmark name', () => {
  const table = [
    ['BenchmarkEditorViewPaint/go/100KiB', 100 * 1024],
    ['BenchmarkEditorViewPaint/java/10MiB', 10 * 1024 * 1024],
    ['BenchmarkEditorViewPaint/json/1GiB', 1024 ** 3],
    ['BenchmarkEditorViewPaint/mixed/512B', 512],
    ['BenchmarkEditorRopeBytes/go', null],
    ['BenchmarkEditorRopeBytes', null],
    ['BenchmarkEditorViewPaint/go/100kib', null],
    ['BenchmarkEditorViewPaint/go/10MB', null],
    ['BenchmarkEditorViewPaint/go/1.5MiB', null],
    ['BenchmarkEditorViewPaint/go/100KiB-10', null],
  ];
  for (const [name, expected] of table) {
    assert.equal(parseSizeBytes(name), expected, name);
  }
});

test('limitFor resolves numbers and size-dependent limits', () => {
  assert.equal(limitFor(5, 100), 5);
  assert.equal(limitFor(0, null), 0);
  assert.equal(limitFor({ constant: 10, perTextByte: 2 }, 100), 210);
  assert.equal(limitFor({ perTextByte: 0.5 }, 10), 5);
  assert.equal(limitFor({ constant: 10 }, null), 10);
  assert.equal(limitFor({ constant: 10, perTextByte: 2 }, null), null);
});

test('allocations above the budget are flagged', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', allocsMax: 0, bytesMax: 0 });
  const candidate = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(1000, { allocs: 0 }),
    [LARGE]: result(1000, { allocs: 140, bytes: 4096 }),
  });

  const [small, large] = evaluate(candidate, budgets);

  assert.equal(small.status, 'within');
  assert.equal(large.status, 'over');
  assert.deepEqual(large.findings, ['B/op 4 KiB > 0 B', 'allocs 140 > 0']);
});

test('time budgets are not judged on another CPU but are judged on the reference CPU', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorRopeLineOf/', nsMax: 1000, allocsMax: 0 });
  const name = 'BenchmarkEditorRopeLineOf/go/100KiB';

  const [foreign] = evaluate(candidateOf(OTHER_CPU, { [name]: result(5000) }), budgets);
  const [slow] = evaluate(candidateOf(REFERENCE_CPU, { [name]: result(5000) }), budgets);
  const [fast] = evaluate(candidateOf(REFERENCE_CPU, { [name]: result(500) }), budgets);

  assert.equal(foreign.timeNote, NOT_JUDGED_CPU);
  assert.equal(foreign.status, 'within');
  assert.deepEqual(foreign.findings, []);
  assert.equal(slow.timeNote, null);
  assert.equal(slow.status, 'over');
  assert.match(slow.findings[0], /^time 5 µs > 1 µs/);
  assert.equal(fast.status, 'within');
});

test('machine-independent limits are judged on another CPU while time is not', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorRopeLineOf/', nsMax: 1000, allocsMax: 0 });
  const name = 'BenchmarkEditorRopeLineOf/go/100KiB';

  const [row] = evaluate(candidateOf(OTHER_CPU, { [name]: result(5000, { allocs: 3 }) }), budgets);

  assert.equal(row.status, 'over');
  assert.deepEqual(row.findings, ['allocs 3 > 0']);
  assert.equal(row.timeNote, NOT_JUDGED_CPU);
});

test('a result whose only limit is time is not judged on another CPU', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorRopeBytes/', nsMax: 1000 });
  const name = 'BenchmarkEditorRopeBytes/go/100KiB';

  const [row] = evaluate(candidateOf(OTHER_CPU, { [name]: result(5000) }), budgets);

  assert.equal(row.status, 'unjudged');
  const markdown = renderMarkdown([row], { machine: { cpu: OTHER_CPU }, referenceMachine: budgets.referenceMachine });
  assert.match(markdown, /1 not judged/);
  assert.match(markdown, new RegExp(`5 µs \\(${NOT_JUDGED_CPU}\\)`));
});

test('scaleMax compares each size with the smallest size of the same benchmark', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', scaleMax: 1.5 });
  const middle = 'BenchmarkEditorViewPaint/go/1MiB';
  const candidate = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(1000),
    [middle]: result(1200),
    [LARGE]: result(1400),
    'BenchmarkEditorViewPaint/java/100KiB': result(100),
    'BenchmarkEditorViewPaint/java/10MiB': result(1000),
  });

  const rows = new Map(evaluate(candidate, budgets).map((row) => [row.name, row]));

  assert.equal(rows.get(SMALL).status, 'unjudged');
  assert.deepEqual(rows.get(middle).notes, ['scale 1.20x vs 100KiB <= 1.5x']);
  assert.deepEqual(rows.get(LARGE).notes, ['scale 1.40x vs 100KiB <= 1.5x']);
  assert.equal(rows.get(LARGE).status, 'within');
  assert.deepEqual(rows.get('BenchmarkEditorViewPaint/java/10MiB').findings, ['scale 10.00x vs 100KiB > 1.5x']);
});

test('scaleMax flags a result that grows with the document', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', scaleMax: 1.5 });
  const candidate = candidateOf(REFERENCE_CPU, { [SMALL]: result(1000), [LARGE]: result(2000) });

  const [, large] = evaluate(candidate, budgets);

  assert.equal(large.status, 'over');
  assert.deepEqual(large.findings, ['scale 2.00x vs 100KiB > 1.5x']);
});

test('metricsMax scales with the document size', () => {
  const budgets = budgetsOf({
    pattern: '^BenchmarkEditorViewMemory/',
    metricsMax: { 'retained-B': { constant: 2097152, perTextByte: 1.5 } },
  });
  const large = 'BenchmarkEditorViewMemory/go/10MiB';
  // The limit for 10 MiB is 2 MiB + 1.5 * 10 MiB = 17 MiB (17825792 bytes).

  const [within] = evaluate(candidateOf(REFERENCE_CPU, { [large]: result(1, { metrics: { 'retained-B': 10_000_000 } }) }), budgets);
  const [over] = evaluate(candidateOf(REFERENCE_CPU, { [large]: result(1, { metrics: { 'retained-B': 20_000_000 } }) }), budgets);
  const [missing] = evaluate(candidateOf(REFERENCE_CPU, { [large]: result(1) }), budgets);
  const [unsized] = evaluate(candidateOf(REFERENCE_CPU, { 'BenchmarkEditorViewMemory/go': result(1, { metrics: { 'retained-B': 1 } }) }), budgets);

  assert.equal(within.status, 'within');
  assert.equal(over.status, 'over');
  assert.match(over.findings[0], /^retained-B 19\.1 MiB > 17 MiB/);
  assert.equal(missing.status, 'over');
  assert.deepEqual(missing.findings, ['retained-B missing']);
  assert.equal(unsized.status, 'unjudged');
  assert.deepEqual(unsized.notes, ['retained-B not judged: document size unknown']);
});

test('the first budget whose pattern matches wins', () => {
  const budgets = budgetsOf(
    { pattern: '^BenchmarkEditorViewPaint/', allocsMax: 100 },
    { pattern: '^BenchmarkEditorView', allocsMax: 0 },
  );
  const candidate = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(1, { allocs: 50 }),
    'BenchmarkEditorViewScroll/go/100KiB': result(1, { allocs: 50 }),
    'BenchmarkEditorRopeBuild/go/100KiB': result(1, { allocs: 50 }),
  });

  const [paint, scroll, rope] = evaluate(candidate, budgets);

  assert.equal(paint.status, 'within');
  assert.equal(paint.budget.pattern, '^BenchmarkEditorViewPaint/');
  assert.equal(scroll.status, 'over');
  assert.equal(scroll.budget.pattern, '^BenchmarkEditorView');
  assert.equal(rope.status, 'none');
  assert.equal(rope.budget, null);
});

test('with a base, rows show the ns/op and allocation change', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', allocsMax: 10 });
  const candidate = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(150, { allocs: 5 }),
    [LARGE]: result(150, { allocs: 2 }),
    'BenchmarkEditorViewPaint/go/1MiB': result(150, { allocs: 2 }),
    'BenchmarkEditorViewPaint/go/2MiB': result(150, { allocs: 2 }),
  });
  const base = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(100, { allocs: 2 }),
    [LARGE]: result(200, { allocs: 2 }),
    'BenchmarkEditorViewPaint/go/1MiB': result(0, { allocs: 2 }),
  });

  const rows = evaluate(candidate, budgets, base);
  const markdown = renderMarkdown(rows, { machine: candidate.machine, referenceMachine: budgets.referenceMachine });

  assert.equal(rows[0].vsBase.nsPercent, 50);
  assert.equal(rows[0].vsBase.allocsDelta, 3);
  assert.equal(rows[1].vsBase.nsPercent, -25);
  assert.equal(rows[1].vsBase.allocsDelta, 0);
  assert.equal(rows[2].vsBase.nsPercent, null);
  assert.deepEqual(rows[3].vsBase, { isNew: true });
  assert.match(markdown, /\+50\.0% ns\/op, allocs \+3/);
  assert.match(markdown, /-25\.0% ns\/op, allocs =/);
  assert.match(markdown, /\| new \|/);
  assert.equal(evaluate(candidate, budgets)[0].vsBase, null);
});

test('renderMarkdown summarizes the run and explains the verdict of each row', () => {
  const budgets = budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', allocsMax: 0 });
  const candidate = candidateOf(REFERENCE_CPU, {
    [SMALL]: result(1000),
    [LARGE]: result(1000, { allocs: 140, metrics: { 'retained-B': 2_097_152 } }),
    'BenchmarkEditorOther/go/100KiB': result(2500),
  });

  const markdown = renderMarkdown(evaluate(candidate, budgets), {
    machine: candidate.machine,
    referenceMachine: budgets.referenceMachine,
  });

  assert.match(markdown, /^# Editor performance report/);
  assert.match(markdown, /Machine: darwin\/arm64, Apple M4/);
  assert.match(markdown, /Reference machine: m4-mbp \(physical\), Apple M4/);
  assert.match(markdown, /Large size: 10MiB/);
  assert.match(markdown, /Summary: 3 results, 1 within budget, 1 over budget, 1 without budget/);
  assert.match(markdown, /\| Benchmark \| ns\/op \| B\/op \| allocs\/op \| extra metrics \| vs base \| Budget \|/);
  const rows = new Map(
    markdown
      .split('\n')
      .filter((line) => line.startsWith('| Benchmark') && !line.includes('ns/op |'))
      .map((line) => [line.split(' | ')[0].slice(2), line]),
  );
  assert.ok(rows.get(SMALL).endsWith('| ✅ within |'));
  assert.ok(rows.get(LARGE).includes('retained-B: 2 MiB'));
  assert.ok(rows.get(LARGE).endsWith('| ⚠️ over: allocs 140 > 0 |'));
  assert.ok(rows.get('BenchmarkEditorOther/go/100KiB').endsWith('| — no budget |'));
  assert.ok(markdown.includes('This report never fails the build; overruns are findings to fix or to justify in the PR.'));
});

test('validateBudgets rejects malformed budget files', () => {
  const valid = () => JSON.parse(JSON.stringify(budgetsOf({ pattern: '^A/', nsMax: 1 })));
  const cases = [
    ['not an object', () => [], /JSON object/],
    ['wrong schema', (b) => { b.schema = 2; }, /schema/],
    ['no reference cpu', (b) => { delete b.referenceMachine.cpu; }, /referenceMachine\.cpu/],
    ['budgets not an array', (b) => { b.budgets = {}; }, /budgets: expected an array/],
    ['bad pattern', (b) => { b.budgets[0].pattern = '('; }, /budgets\[0\]\.pattern/],
    ['missing why', (b) => { delete b.budgets[0].why; }, /why/],
    ['unknown key', (b) => { b.budgets[0].nsmax = 1; }, /unknown key "nsmax"/],
    ['negative limit', (b) => { b.budgets[0].nsMax = -1; }, /nsMax/],
    ['unknown limit key', (b) => { b.budgets[0].nsMax = { constant: 1, perByte: 2 }; }, /unknown key "perByte"/],
    ['empty limit object', (b) => { b.budgets[0].bytesMax = {}; }, /bytesMax/],
    ['zero scale', (b) => { b.budgets[0].scaleMax = 0; }, /scaleMax/],
    ['metrics not an object', (b) => { b.budgets[0].metricsMax = []; }, /metricsMax/],
    ['bad metric limit', (b) => { b.budgets[0].metricsMax = { 'retained-B': 'x' }; }, /retained-B/],
  ];
  for (const [label, mutate, expected] of cases) {
    const budgets = valid();
    const replaced = mutate(budgets);
    assert.throws(() => validateBudgets(replaced ?? budgets), expected, label);
  }
  assert.doesNotThrow(() => validateBudgets(valid()));
  assert.throws(() => parseBudgets('{not json'), /invalid JSON/);
});

test('the shipped budget file is valid and no budget shadows a later one', () => {
  const budgets = parseBudgets(readFileSync(SHIPPED_BUDGETS, 'utf8'));
  const patterns = budgets.budgets.map((budget) => budget.pattern);

  assert.equal(new Set(patterns).size, patterns.length, 'patterns must be unique');
  budgets.budgets.forEach((budget, index) => {
    assert.match(budget.pattern, /^\^BenchmarkEditor[A-Za-z]+\/$/);
    const sample = `${budget.pattern.slice(1)}kind/100KiB`;
    const first = budgets.budgets.findIndex((other) => new RegExp(other.pattern).test(sample));
    assert.equal(first, index, `${budget.pattern} is shadowed by ${patterns[first]}`);
  });
  const [paint] = evaluate(candidateOf(REFERENCE_CPU, { [SMALL]: result(1000) }), budgets);
  assert.equal(paint.budget.scaleMax, 1.5);
});

test('main returns 2 for a usage error and 0 for help', () => {
  const output = [];
  const errors = [];
  const streams = { stdout: { write: (text) => output.push(text) }, stderr: { write: (text) => errors.push(text) } };

  assert.equal(main([], streams), 2);
  assert.match(errors.join(''), /--budgets FILE is required/);
  assert.equal(main(['--help'], streams), 0);
  assert.match(output.join(''), /^Usage: editor-perf-report\.mjs/);
});

test('the command line exits 0 and reports an over budget result', (t) => {
  const dir = tempDir(t);
  const budgets = join(dir, 'budgets.json');
  const candidate = join(dir, 'candidate.txt');
  writeFileSync(budgets, JSON.stringify(budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', allocsMax: 0 })));
  writeFileSync(candidate, benchHeader(REFERENCE_CPU) + benchLine(SMALL, 1000, 0, 140) + 'PASS\n');

  const run = runCli(['--budgets', budgets, candidate]);

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /1 over budget/);
  assert.match(run.stdout, /⚠️ over: allocs 140 > 0/);
  assert.equal(run.stderr, '');
});

test('the command line shows changes against a base', (t) => {
  const dir = tempDir(t);
  const budgets = join(dir, 'budgets.json');
  const candidate = join(dir, 'candidate.txt');
  const base = join(dir, 'base.txt');
  writeFileSync(budgets, JSON.stringify(budgetsOf({ pattern: '^BenchmarkEditorViewPaint/', allocsMax: 0 })));
  writeFileSync(candidate, benchHeader(REFERENCE_CPU) + benchLine(SMALL, 150, 0, 0));
  writeFileSync(base, benchHeader(OTHER_CPU) + benchLine(SMALL, 100, 0, 0));

  const run = runCli(['--budgets', budgets, '--base', base, candidate]);

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /\+50\.0% ns\/op, allocs =/);
  assert.match(run.stdout, /Base machine: darwin\/arm64, Intel.*not comparable/);
});

test('the command line exits 1 for malformed or unreadable input', (t) => {
  const dir = tempDir(t);
  const candidate = join(dir, 'candidate.txt');
  const malformed = join(dir, 'malformed.json');
  const invalid = join(dir, 'invalid.json');
  const empty = join(dir, 'empty.txt');
  const good = join(dir, 'good.json');
  writeFileSync(candidate, benchHeader(REFERENCE_CPU) + benchLine(SMALL, 1000, 0, 0));
  writeFileSync(malformed, '{"schema": 1');
  writeFileSync(invalid, JSON.stringify({ schema: 1, referenceMachine: { label: 'x', kind: 'y', cpu: 'z' }, budgets: [{ pattern: '^A/' }] }));
  writeFileSync(empty, 'FAIL\texample.com/editor [build failed]\n');
  writeFileSync(good, JSON.stringify(budgetsOf({ pattern: '^A/', nsMax: 1 })));

  const badJson = runCli(['--budgets', malformed, candidate]);
  const badSchema = runCli(['--budgets', invalid, candidate]);
  const missingBudgets = runCli(['--budgets', join(dir, 'missing.json'), candidate]);
  const missingCandidate = runCli(['--budgets', good, join(dir, 'missing.txt')]);
  const noResults = runCli(['--budgets', good, empty]);

  assert.equal(badJson.status, 1);
  assert.match(badJson.stderr, /invalid budget file .*invalid JSON/);
  assert.equal(badSchema.status, 1);
  assert.match(badSchema.stderr, /budgets\[0\]\.why/);
  assert.equal(missingBudgets.status, 1);
  assert.equal(missingCandidate.status, 1);
  assert.equal(noResults.status, 1);
  assert.match(noResults.stderr, /contains no benchmark results/);
  for (const run of [badJson, badSchema, missingBudgets, missingCandidate, noResults]) {
    assert.equal(run.stdout, '');
  }
});

test('the command line exits 2 for usage errors', (t) => {
  const dir = tempDir(t);
  const budgets = join(dir, 'budgets.json');
  const candidate = join(dir, 'candidate.txt');
  writeFileSync(budgets, JSON.stringify(budgetsOf({ pattern: '^A/', nsMax: 1 })));
  writeFileSync(candidate, benchLine(SMALL, 1, 0, 0));

  for (const args of [
    [],
    [candidate],
    ['--budgets', budgets],
    ['--budgets', budgets, '--bogus', candidate],
    ['--budgets', budgets, candidate, candidate],
    ['--budgets'],
  ]) {
    const run = runCli(args);
    assert.equal(run.status, 2, `${args.join(' ')}: ${run.stderr}`);
    assert.match(run.stderr, /Usage: editor-perf-report\.mjs/);
  }
});
