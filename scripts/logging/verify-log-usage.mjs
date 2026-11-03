#!/usr/bin/env node
// A small source lexer keeps comments/string contents and test modules out of counts.
import { readFile, readdir } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT } from './generate-log-events.mjs';

export const RULES = {
  'swift.nslog': ['NSLog is a bypass', 'emit a generated LogEvent'],
  'swift.stderr': ['direct stderr write', 'emit a generated LogEvent (or document a machine protocol exception)'],
  'swift.os-log': ['os_log is a bypass', 'emit a generated LogEvent'],
  'swift.logger': ['os.log Logger is a bypass', 'emit a generated LogEvent'],
  'swift.record': ['string-based record(level:)', 'construct the generated event and pass it to the typed sink'],
  'rust.eprintln': ['eprintln! is a bypass', 'use diagnostics::catalog metadata and the structured log encoder'],
  'rust.println': ['println! is a bypass', 'use diagnostics::catalog metadata and the structured log encoder'],
  'rust.dbg': ['dbg! is a bypass', 'use a generated debug event'],
};

export function maskSource(source, language) {
  const chars = source.split('');
  const blank = (start, end) => { for (let at = start; at < end; at++) if (chars[at] !== '\n' && chars[at] !== '\r') chars[at] = ' '; };
  let at = 0;
  while (at < source.length) {
    const start = at;
    if (source.startsWith('//', at)) {
      at = source.indexOf('\n', at);
      if (at < 0) at = source.length;
    } else if (source.startsWith('/*', at)) {
      let depth = 1; at += 2;
      while (at < source.length && depth) {
        if (source.startsWith('/*', at)) { depth++; at += 2; }
        else if (source.startsWith('*/', at)) { depth--; at += 2; }
        else at++;
      }
    } else {
      const raw = language === 'rust' ? /^(?:br|r)(#*)"/.exec(source.slice(at)) : /^(#+)("""|")/.exec(source.slice(at));
      if (raw) {
        const terminator = language === 'rust' ? `"${raw[1]}` : `${raw[2]}${raw[1]}`;
        const end = source.indexOf(terminator, at + raw[0].length);
        at = end < 0 ? source.length : end + terminator.length;
      } else if (source[at] === '"') {
        const delimiter = source.startsWith('"""', at) && language === 'swift' ? '"""' : '"';
        at += delimiter.length;
        while (at < source.length && !source.startsWith(delimiter, at)) {
          if (source[at] === '\\') at += 2;
          else at++;
        }
        at = Math.min(source.length, at + delimiter.length);
      } else if (language === 'rust' && source[at] === "'" && /^'(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^'\n\\])'/u.test(source.slice(at))) {
        const literal = /^'(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^'\n\\])'/u.exec(source.slice(at))[0];
        at += literal.length;
      } else { at++; continue; }
    }
    blank(start, at);
  }
  return chars.join('');
}

function maskRustTests(code) {
  const chars = code.split('');
  // Find the attributed item itself; attributes can be separated by comments or other attributes.
  const attribute = /#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]/g;
  for (const match of code.matchAll(attribute)) {
    let at = match.index + match[0].length;
    while (at < code.length) {
      if (/\s/.test(code[at])) { at++; continue; }
      if (code.startsWith('#[', at)) {
        let depth = 1; at += 2;
        while (at < code.length && depth) { if (code[at] === '[') depth++; if (code[at] === ']') depth--; at++; }
        continue;
      }
      break;
    }
    const start = at;
    while (at < code.length && !'{;'.includes(code[at])) at++;
    if (code[at] === '{') {
      let depth = 1; at++;
      while (at < code.length && depth) { if (code[at] === '{') depth++; if (code[at] === '}') depth--; at++; }
    } else at++;
    for (let index = start; index < at; index++) if (chars[index] !== '\n') chars[index] = ' ';
  }
  return chars.join('');
}

export function scanSource(file, source) {
  if (/(^|\/)(?:tests|Tests)(\/|$)/.test(file) || file.endsWith('/tests.rs')) return [];
  const language = file.endsWith('.swift') ? 'swift' : 'rust';
  let code = maskSource(source, language);
  if (language === 'rust') code = maskRustTests(code);
  const patterns = language === 'swift' ? [
    ['swift.nslog', /\bNSLog\s*\(/g],
    ['swift.stderr', /\bFileHandle\s*\.\s*standardError\s*\.\s*write\s*\(/g],
    ['swift.os-log', /\bos_log\s*\(/g],
    ['swift.record', /(?:\.|\?\.)\s*record\s*\(\s*level\s*:/g],
    ...(/\bimport\s+os\s*\.\s*log\b/.test(code) ? [['swift.logger', /\bLogger\s*\(/g]] : []),
  ] : ['eprintln', 'println', 'dbg'].map(name => [`rust.${name}`, new RegExp(`\\b${name}\\s*!\\s*[(\\[{]`, 'g')]);
  return patterns.flatMap(([rule, pattern]) => [...code.matchAll(pattern)].map(match => ({
    file, rule, column: match.index - source.lastIndexOf('\n', match.index), line: source.slice(0, match.index).split('\n').length,
    excerpt: source.split('\n')[source.slice(0, match.index).split('\n').length - 1].trim(),
  }))).sort((a, b) => a.line - b.line || a.column - b.column);
}

async function files(directory, extension) {
  const entries = await readdir(directory, { withFileTypes: true });
  const results = await Promise.all(entries.filter(entry => !['Tests', 'tests'].includes(entry.name)).map(async entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? files(full, extension) : entry.name.endsWith(extension) ? [full] : [];
  }));
  return results.flat().sort();
}
export async function scanRepository(root = ROOT) {
  const groups = await Promise.all([files(path.join(root, 'macos/Sources'), '.swift'), files(path.join(root, 'rust/lithe-core/src'), '.rs')]);
  return (await Promise.all(groups.flat().map(async file => scanSource(path.relative(root, file).split(path.sep).join('/'), await readFile(file, 'utf8'))))).flat();
}
function validatePolicy(policy, label, permanent) {
  if (policy.version !== 1 || !Array.isArray(policy.entries)) throw new Error(`${label}: invalid format`);
  const keys = new Set();
  for (const entry of policy.entries) {
    const key = `${entry.file}:${entry.rule}`;
    if (typeof entry.file !== 'string' || !/^(macos\/Sources\/.*\.swift|rust\/lithe-core\/src\/.*\.rs)$/.test(entry.file) || entry.file.split('/').some(part => part === '..') || !Object.hasOwn(RULES, entry.rule) || !Number.isSafeInteger(entry.count) || entry.count <= 0 || keys.has(key) || !entry.reason?.trim()) throw new Error(`${label}: invalid or duplicate entry ${key}`);
    if (!permanent && entry.reason !== (entry.file.startsWith('rust/') ? 'PR3：经运行时事件流交给宿主' : '待 PR2/PR3 迁移')) throw new Error(`${label}: expected migration reason for ${key}`);
    keys.add(key);
  }
}
export function compareUsage(violations, allowlist, baseline) {
  validatePolicy(allowlist, 'allowlist', true); validatePolicy(baseline, 'baseline', false);
  const counts = new Map();
  for (const violation of violations) {
    const key = `${violation.file}:${violation.rule}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const expected = new Map();
  for (const entry of [...allowlist.entries, ...baseline.entries]) {
    const key = `${entry.file}:${entry.rule}`;
    if (expected.has(key)) throw new Error(`policy overlap: ${key}`);
    expected.set(key, entry.count);
  }
  const problems = [];
  for (const key of new Set([...counts.keys(), ...expected.keys()])) {
    const actual = counts.get(key) ?? 0;
    const limit = expected.get(key) ?? 0;
    if (actual > limit) {
      problems.push(`${key}: ${actual} violations exceed baseline ${limit}`);
      for (const item of violations.filter(item => `${item.file}:${item.rule}` === key)) problems.push(`${item.file}:${item.line}: ${item.rule}: ${RULES[item.rule][0]}; ${RULES[item.rule][1]}`);
    } else if (actual < limit) problems.push(`${key}: baseline ${limit} exceeds actual ${actual}; tighten baseline/allowlist (收紧基线)`);
  }
  return problems;
}
export async function verify(root = ROOT) {
  const [violations, allowlist, baseline] = await Promise.all([
    scanRepository(root),
    readFile(path.join(root, 'scripts/logging/log-usage-allowlist.json'), 'utf8').then(JSON.parse),
    readFile(path.join(root, 'scripts/logging/log-usage-baseline.json'), 'utf8').then(JSON.parse),
  ]);
  const problems = compareUsage(violations, allowlist, baseline);
  if (problems.length) throw new Error(problems.join('\n'));
  return { violations, allowlist, baseline };
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(path.resolve(process.argv[1]))).href) {
  if (process.argv.length > 2) { console.error('usage: node scripts/logging/verify-log-usage.mjs'); process.exitCode = 1; }
  else verify().then(({ violations, allowlist }) => console.log(`Log usage verified: ${violations.length - allowlist.entries.reduce((sum, entry) => sum + entry.count, 0)} migration violations; ${allowlist.entries.reduce((sum, entry) => sum + entry.count, 0)} permanent exceptions`)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
