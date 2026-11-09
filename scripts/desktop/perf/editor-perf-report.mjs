#!/usr/bin/env node
// Turns `go test -bench` output of the editor benchmarks into a Markdown report and judges each
// result against the budgets in desktop/benchmarks/editor-budgets.json.
//
// Usage:
//   node scripts/desktop/perf/editor-perf-report.mjs --budgets FILE [--base FILE] CANDIDATE
//
// The report never fails the build: budget overruns are findings, so the exit code is 0 even when
// every budget is exceeded. Exit 2 means a usage error, exit 1 means unreadable or malformed input.

import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const SIZE_UNITS = { B: 1, KiB: 1024, MiB: 1024 ** 2, GiB: 1024 ** 3 };
const SIZE_SEGMENT = /^(\d+)(B|KiB|MiB|GiB)$/;
const GOMAXPROCS_SUFFIX = /-\d+$/;
const NOT_JUDGED_CPU = 'not judged: CPU differs from the reference machine';
const NEVER_FAILS_NOTE = 'This report never fails the build; overruns are findings to fix or to justify in the PR.';

const BUDGET_KEYS = new Set(['pattern', 'why', 'nsMax', 'bytesMax', 'allocsMax', 'scaleMax', 'metricsMax']);
const LIMIT_KEYS = new Set(['constant', 'perTextByte']);

class UsageError extends Error {}

// ---------------------------------------------------------------------------------------------
// Parsing benchmark output
// ---------------------------------------------------------------------------------------------

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

// Parses the value/unit pairs that follow the iteration count of a benchmark line. Returns null
// when any value is not a finite number, so a diagnostic line that merely starts with "Benchmark"
// is ignored instead of producing a bogus result.
function parsePairs(fields) {
  const pairs = [];
  for (let index = 2; index + 1 < fields.length; index += 2) {
    const value = Number(fields[index]);
    if (!Number.isFinite(value)) return null;
    pairs.push([fields[index + 1], value]);
  }
  return pairs.length > 0 ? pairs : null;
}

// Parses `go test -bench` output. Repeated lines of one benchmark (-count N) collapse into the
// median of each value, because a single slow sample must not decide a budget verdict.
export function parseBenchOutput(text) {
  const machine = { goos: null, goarch: null, cpu: null };
  const collected = new Map();
  for (const line of text.split(/\r?\n/)) {
    const header = /^(goos|goarch|cpu): (.*)$/.exec(line);
    if (header) {
      if (machine[header[1]] === null) machine[header[1]] = header[2].trim();
      continue;
    }
    if (!line.startsWith('Benchmark')) continue;
    const fields = line.trim().split(/\s+/);
    if (!/^\d+$/.test(fields[1] ?? '')) continue;
    const pairs = parsePairs(fields);
    if (pairs === null) continue;
    const name = fields[0].replace(GOMAXPROCS_SUFFIX, '');
    let entry = collected.get(name);
    if (entry === undefined) {
      entry = { samples: 0, units: new Map() };
      collected.set(name, entry);
    }
    entry.samples += 1;
    for (const [unit, value] of pairs) {
      const values = entry.units.get(unit);
      if (values === undefined) entry.units.set(unit, [value]);
      else values.push(value);
    }
  }

  const results = new Map();
  for (const [name, entry] of collected) {
    const medians = new Map([...entry.units].map(([unit, values]) => [unit, median(values)]));
    const take = (unit) => {
      const value = medians.get(unit);
      medians.delete(unit);
      return value ?? null;
    };
    const nsPerOp = take('ns/op');
    const bytesPerOp = take('B/op');
    const allocsPerOp = take('allocs/op');
    results.set(name, {
      samples: entry.samples,
      nsPerOp,
      bytesPerOp,
      allocsPerOp,
      metrics: Object.fromEntries(medians),
    });
  }
  return { machine, results };
}

// Returns the size in bytes named by the last path segment of a benchmark name, or null.
export function parseSizeBytes(name) {
  const segment = name.slice(name.lastIndexOf('/') + 1);
  const match = SIZE_SEGMENT.exec(segment);
  return match === null ? null : Number(match[1]) * SIZE_UNITS[match[2]];
}

// Resolves a budget limit for a document of sizeBytes. A limit is a plain number or
// {constant, perTextByte}; the latter scales with the document and cannot be resolved without a size.
export function limitFor(limit, sizeBytes) {
  if (typeof limit === 'number') return limit;
  if (limit === null || typeof limit !== 'object') return null;
  if (limit.perTextByte !== undefined && (sizeBytes === null || sizeBytes === undefined)) return null;
  return (limit.constant ?? 0) + (limit.perTextByte ?? 0) * (sizeBytes ?? 0);
}

// ---------------------------------------------------------------------------------------------
// Budget file
// ---------------------------------------------------------------------------------------------

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isNonNegativeNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

function validateLimit(value, where) {
  if (isNonNegativeNumber(value)) return;
  if (!isObject(value)) {
    throw new Error(`${where}: expected a non-negative number or {constant, perTextByte}`);
  }
  const keys = Object.keys(value);
  if (keys.length === 0) throw new Error(`${where}: expected constant or perTextByte`);
  for (const key of keys) {
    if (!LIMIT_KEYS.has(key)) throw new Error(`${where}: unknown key "${key}"`);
    if (!isNonNegativeNumber(value[key])) throw new Error(`${where}.${key}: expected a non-negative number`);
  }
}

// Validates a parsed budget file and throws an Error naming the offending field. The check is
// strict (unknown keys are errors) because a misspelled limit would otherwise silently disable a budget.
export function validateBudgets(value) {
  if (!isObject(value)) throw new Error('the budget file must contain a JSON object');
  if (value.schema !== 1) throw new Error('schema: expected 1');
  const reference = value.referenceMachine;
  if (!isObject(reference)) throw new Error('referenceMachine: expected an object');
  for (const key of ['label', 'kind', 'cpu']) {
    if (typeof reference[key] !== 'string' || reference[key] === '') {
      throw new Error(`referenceMachine.${key}: expected a non-empty string`);
    }
  }
  if (!Array.isArray(value.budgets)) throw new Error('budgets: expected an array');
  value.budgets.forEach((budget, index) => {
    const where = `budgets[${index}]`;
    if (!isObject(budget)) throw new Error(`${where}: expected an object`);
    for (const key of Object.keys(budget)) {
      if (!BUDGET_KEYS.has(key)) throw new Error(`${where}: unknown key "${key}"`);
    }
    if (typeof budget.pattern !== 'string' || budget.pattern === '') {
      throw new Error(`${where}.pattern: expected a non-empty regular expression string`);
    }
    try {
      new RegExp(budget.pattern);
    } catch (error) {
      throw new Error(`${where}.pattern: invalid regular expression: ${error.message}`);
    }
    if (typeof budget.why !== 'string' || budget.why === '') {
      throw new Error(`${where}.why: expected a non-empty string`);
    }
    for (const key of ['nsMax', 'bytesMax', 'allocsMax']) {
      if (budget[key] !== undefined) validateLimit(budget[key], `${where}.${key}`);
    }
    if (budget.scaleMax !== undefined && !(typeof budget.scaleMax === 'number' && budget.scaleMax > 0)) {
      throw new Error(`${where}.scaleMax: expected a positive number`);
    }
    if (budget.metricsMax !== undefined) {
      if (!isObject(budget.metricsMax)) throw new Error(`${where}.metricsMax: expected an object keyed by unit`);
      for (const [unit, limit] of Object.entries(budget.metricsMax)) {
        validateLimit(limit, `${where}.metricsMax["${unit}"]`);
      }
    }
  });
  return value;
}

// Parses and validates the text of a budget file.
export function parseBudgets(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new Error(`invalid JSON: ${error.message}`);
  }
  return validateBudgets(value);
}

// ---------------------------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------------------------

function trimNumber(value, digits) {
  return String(Number(value.toPrecision(digits)));
}

function formatNs(ns) {
  if (ns < 1e3) return `${trimNumber(ns, 3)} ns`;
  if (ns < 1e6) return `${trimNumber(ns / 1e3, 3)} µs`;
  if (ns < 1e9) return `${trimNumber(ns / 1e6, 3)} ms`;
  return `${trimNumber(ns / 1e9, 3)} s`;
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${trimNumber(bytes, 3)} B`;
  if (bytes < 1024 ** 2) return `${trimNumber(bytes / 1024, 3)} KiB`;
  if (bytes < 1024 ** 3) return `${trimNumber(bytes / 1024 ** 2, 3)} MiB`;
  return `${trimNumber(bytes / 1024 ** 3, 3)} GiB`;
}

function formatCount(count) {
  return Number.isInteger(count) ? String(count) : trimNumber(count, 4);
}

// Formats a size the way benchmark names spell it (100KiB, 10MiB).
function formatSize(bytes) {
  for (const unit of ['GiB', 'MiB', 'KiB']) {
    if (bytes >= SIZE_UNITS[unit] && bytes % SIZE_UNITS[unit] === 0) return `${bytes / SIZE_UNITS[unit]}${unit}`;
  }
  return `${bytes}B`;
}

// Custom metrics whose unit ends in B (for example retained-B) count bytes and read better scaled.
function formatMetric(unit, value) {
  return /(^|[^A-Za-z])B$/.test(unit) ? formatBytes(value) : trimNumber(value, 4);
}

function formatSigned(value, digits) {
  const text = value.toFixed(digits);
  return value > 0 ? `+${text}` : text;
}

function overBy(value, limit) {
  return limit > 0 ? ` (+${Math.round((value / limit - 1) * 100)}%)` : '';
}

function describeMachine(machine) {
  if (!machine || (!machine.goos && !machine.goarch && !machine.cpu)) return 'unknown';
  const platform = [machine.goos, machine.goarch].filter(Boolean).join('/');
  return [platform, machine.cpu].filter(Boolean).join(', ');
}

function describeReference(reference) {
  if (!reference) return 'none';
  return `${reference.label} (${reference.kind}), ${reference.cpu}`;
}

function cpuMatchesReference(machine, reference) {
  return Boolean(reference?.cpu) && machine?.cpu === reference.cpu;
}

function escapeCell(text) {
  return String(text).replaceAll('|', '\\|');
}

// ---------------------------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------------------------

// Finds the smallest-size sibling of a result: same name prefix, different last segment, size known.
function smallestSibling(candidate, name) {
  const prefix = name.slice(0, name.lastIndexOf('/'));
  let smallest = null;
  for (const [otherName, other] of candidate.results) {
    if (otherName.slice(0, otherName.lastIndexOf('/')) !== prefix) continue;
    const size = parseSizeBytes(otherName);
    if (size === null || other.nsPerOp === null) continue;
    if (smallest === null || size < smallest.size) smallest = { size, nsPerOp: other.nsPerOp };
  }
  return smallest;
}

function evaluateResult(candidate, name, result, budget, timeJudged) {
  const sizeBytes = parseSizeBytes(name);
  const row = { name, result, sizeBytes, budget, status: 'none', findings: [], notes: [], timeNote: null, vsBase: null };
  if (budget === null) return row;

  let judged = 0;
  const upper = (label, value, limit, format) => {
    judged += 1;
    if (value > limit) row.findings.push(`${label} ${format(value)} > ${format(limit)}${overBy(value, limit)}`);
  };
  const resolve = (label, limit) => {
    const resolved = limitFor(limit, sizeBytes);
    if (resolved === null) row.notes.push(`${label} not judged: document size unknown`);
    return resolved;
  };

  if (budget.nsMax !== undefined) {
    if (!timeJudged) {
      row.timeNote = NOT_JUDGED_CPU;
    } else if (result.nsPerOp === null) {
      row.notes.push('time not recorded');
    } else {
      const limit = resolve('time', budget.nsMax);
      if (limit !== null) upper('time', result.nsPerOp, limit, formatNs);
    }
  }
  if (budget.bytesMax !== undefined) {
    if (result.bytesPerOp === null) {
      row.notes.push('B/op not recorded');
    } else {
      const limit = resolve('B/op', budget.bytesMax);
      if (limit !== null) upper('B/op', result.bytesPerOp, limit, formatBytes);
    }
  }
  if (budget.allocsMax !== undefined) {
    if (result.allocsPerOp === null) {
      row.notes.push('allocs/op not recorded');
    } else {
      const limit = resolve('allocs', budget.allocsMax);
      if (limit !== null) upper('allocs', result.allocsPerOp, limit, formatCount);
    }
  }
  for (const [unit, metricLimit] of Object.entries(budget.metricsMax ?? {})) {
    const value = result.metrics?.[unit];
    if (value === undefined) {
      // A benchmark that stops reporting its metric would silently disable the budget.
      judged += 1;
      row.findings.push(`${unit} missing`);
      continue;
    }
    const limit = resolve(unit, metricLimit);
    if (limit !== null) upper(unit, value, limit, (number) => formatMetric(unit, number));
  }
  if (budget.scaleMax !== undefined && sizeBytes !== null && result.nsPerOp !== null) {
    const smallest = smallestSibling(candidate, name);
    if (smallest !== null && smallest.size < sizeBytes && smallest.nsPerOp > 0) {
      const ratio = result.nsPerOp / smallest.nsPerOp;
      judged += 1;
      const text = `scale ${ratio.toFixed(2)}x vs ${formatSize(smallest.size)}`;
      if (ratio > budget.scaleMax) row.findings.push(`${text} > ${budget.scaleMax}x`);
      else row.notes.push(`${text} <= ${budget.scaleMax}x`);
    }
  }

  if (row.findings.length > 0) row.status = 'over';
  else row.status = judged > 0 ? 'within' : 'unjudged';
  return row;
}

function compareToBase(result, baseResult) {
  const comparison = { nsPercent: null, allocsDelta: null };
  if (result.nsPerOp !== null && baseResult.nsPerOp !== null && baseResult.nsPerOp > 0) {
    comparison.nsPercent = (result.nsPerOp / baseResult.nsPerOp - 1) * 100;
  }
  if (result.allocsPerOp !== null && baseResult.allocsPerOp !== null) {
    comparison.allocsDelta = result.allocsPerOp - baseResult.allocsPerOp;
  }
  return comparison;
}

// Judges every candidate result against the first budget whose pattern matches its name. Rows
// carry the verdict (status: none, within, over or unjudged) and the findings behind it.
export function evaluate(candidate, budgets, base = null) {
  const timeJudged = cpuMatchesReference(candidate.machine, budgets.referenceMachine);
  const compiled = (budgets.budgets ?? []).map((budget) => ({ budget, regex: new RegExp(budget.pattern) }));
  const rows = [];
  for (const [name, result] of candidate.results) {
    const entry = compiled.find((item) => item.regex.test(name));
    const row = evaluateResult(candidate, name, result, entry ? entry.budget : null, timeJudged);
    if (base) {
      const baseResult = base.results.get(name);
      row.vsBase = baseResult === undefined ? { isNew: true } : compareToBase(result, baseResult);
    }
    rows.push(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------------------------

function nsCell(row) {
  if (row.result.nsPerOp === null) return '';
  const text = formatNs(row.result.nsPerOp);
  return row.timeNote ? `${text} (${row.timeNote})` : text;
}

function metricsCell(row) {
  return Object.entries(row.result.metrics ?? {})
    .map(([unit, value]) => `${unit}: ${formatMetric(unit, value)}`)
    .join(', ');
}

function baseCell(row) {
  if (!row.vsBase) return '—';
  if (row.vsBase.isNew) return 'new';
  const parts = [];
  if (row.vsBase.nsPercent !== null) parts.push(`${formatSigned(row.vsBase.nsPercent, 1)}% ns/op`);
  if (row.vsBase.allocsDelta !== null) {
    parts.push(row.vsBase.allocsDelta === 0 ? 'allocs =' : `allocs ${formatSigned(row.vsBase.allocsDelta, 0)}`);
  }
  return parts.length > 0 ? parts.join(', ') : '—';
}

function budgetCell(row) {
  switch (row.status) {
    case 'over':
      return `⚠️ over: ${[...row.findings, ...row.notes].join('; ')}`;
    case 'within':
      return row.notes.length > 0 ? `✅ within (${row.notes.join('; ')})` : '✅ within';
    case 'unjudged':
      return row.notes.length > 0 ? `— not judged (${row.notes.join('; ')})` : '— not judged';
    default:
      return '— no budget';
  }
}

// Renders the report. context carries machine, referenceMachine and (with --base) baseMachine.
export function renderMarkdown(rows, context = {}) {
  const count = (status) => rows.filter((row) => row.status === status).length;
  const unjudged = count('unjudged');
  const sizes = rows.map((row) => row.sizeBytes).filter((size) => size !== null);
  const reference = context.referenceMachine ?? null;
  const timeJudged = cpuMatchesReference(context.machine, reference);

  const lines = ['# Editor performance report', ''];
  lines.push(`- Machine: ${describeMachine(context.machine)}`);
  lines.push(`- Reference machine: ${describeReference(reference)}`);
  lines.push(`- Time budgets: ${timeJudged ? 'judged (the CPU matches the reference machine)' : NOT_JUDGED_CPU}`);
  lines.push(`- Large size: ${sizes.length > 0 ? formatSize(Math.max(...sizes)) : 'none seen'}`);
  if (context.baseMachine) {
    const comparable = context.baseMachine.cpu === context.machine?.cpu;
    lines.push(
      `- Base machine: ${describeMachine(context.baseMachine)}` +
        (comparable ? '' : ' (differs from this machine, so changes vs base are not comparable)'),
    );
  }
  lines.push('');
  lines.push(
    `Summary: ${rows.length} ${rows.length === 1 ? 'result' : 'results'}, ${count('within')} within budget, ${count('over')} over budget, ` +
      `${count('none')} without budget${unjudged > 0 ? `, ${unjudged} not judged` : ''}`,
  );
  lines.push('');
  lines.push('| Benchmark | ns/op | B/op | allocs/op | extra metrics | vs base | Budget |');
  lines.push('| --- | ---: | ---: | ---: | --- | --- | --- |');
  for (const row of rows) {
    const { result } = row;
    lines.push(
      `| ${[
        row.name,
        nsCell(row),
        result.bytesPerOp === null ? '' : formatBytes(result.bytesPerOp),
        result.allocsPerOp === null ? '' : formatCount(result.allocsPerOp),
        metricsCell(row),
        baseCell(row),
        budgetCell(row),
      ]
        .map(escapeCell)
        .join(' | ')} |`,
    );
  }
  lines.push('', NEVER_FAILS_NOTE, '');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------------------------

function usage() {
  return [
    'Usage: editor-perf-report.mjs --budgets FILE [--base FILE] CANDIDATE',
    '',
    '  --budgets FILE  budget file (desktop/benchmarks/editor-budgets.json)',
    '  --base FILE     earlier `go test -bench` output to show changes against',
    '  CANDIDATE       `go test -bench` output to report',
    '',
    'Prints a Markdown report. Budget overruns are findings and never change the exit code.',
    'Exit codes: 0 report printed, 1 unreadable or malformed input, 2 usage error.',
  ].join('\n');
}

function parseArgs(argv) {
  const args = { budgets: null, base: null, candidate: null, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
    } else if (arg === '--budgets' || arg === '--base') {
      const value = argv[index + 1];
      if (value === undefined) throw new UsageError(`${arg} requires a value`);
      args[arg.slice(2)] = value;
      index += 1;
    } else if (arg.startsWith('-')) {
      throw new UsageError(`unknown option ${arg}`);
    } else if (args.candidate === null) {
      args.candidate = arg;
    } else {
      throw new UsageError(`unexpected extra argument ${arg}`);
    }
  }
  if (!args.help) {
    if (args.budgets === null) throw new UsageError('--budgets FILE is required');
    if (args.candidate === null) throw new UsageError('a CANDIDATE benchmark output file is required');
  }
  return args;
}

function readInput(path, what) {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    throw new Error(`cannot read ${what} ${path}: ${error.message}`);
  }
}

function readBenchFile(path, what) {
  const parsed = parseBenchOutput(readInput(path, what));
  if (parsed.results.size === 0) throw new Error(`${what} ${path} contains no benchmark results`);
  return parsed;
}

// Runs the command line and returns the exit code. The streams parameter exists for tests.
export function main(argv, streams = {}) {
  const stdout = streams.stdout ?? process.stdout;
  const stderr = streams.stderr ?? process.stderr;
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    stderr.write(`editor-perf-report: ${error.message}\n\n${usage()}\n`);
    return 2;
  }
  if (args.help) {
    stdout.write(`${usage()}\n`);
    return 0;
  }

  let candidate;
  let base = null;
  let budgets;
  try {
    const budgetText = readInput(args.budgets, 'budget file');
    try {
      budgets = parseBudgets(budgetText);
    } catch (error) {
      throw new Error(`invalid budget file ${args.budgets}: ${error.message}`);
    }
    candidate = readBenchFile(args.candidate, 'benchmark output');
    if (args.base !== null) base = readBenchFile(args.base, 'base benchmark output');
  } catch (error) {
    stderr.write(`editor-perf-report: ${error.message}\n`);
    return 1;
  }

  const rows = evaluate(candidate, budgets, base);
  stdout.write(
    `${renderMarkdown(rows, {
      machine: candidate.machine,
      referenceMachine: budgets.referenceMachine,
      baseMachine: base ? base.machine : null,
    })}\n`,
  );
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
