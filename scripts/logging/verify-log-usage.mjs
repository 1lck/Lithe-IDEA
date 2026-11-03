#!/usr/bin/env node
// A small source lexer keeps comments/string contents and test modules out of counts.
import { readFile, readdir } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT } from './generate-log-events.mjs';

export const RULES = {
  'swift.discarded-try': ['discarded try? failure', 'handle the failure or add a reasoned log-exempt marker'],
  'swift.catch-exit': ['catch exits without recording', 'record the handled failure before exiting'],
  'swift.print': ['print/debugPrint bypass', 'emit a generated LogEvent'],
  'rust.discarded-ok': ['discarded Result.ok()', 'handle or record the failure'],
  'rust.let-underscore': ['discarded possible Result', 'handle the failure or add a reasoned log-exempt marker'],
  'usage.invalid-exemption': ['log-exempt requires at least 3 non-whitespace characters', 'document the concrete reason'],
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

// Markers may justify a swallowed failure only; logging bypasses use the reviewed allowlist.
export const EXEMPTIBLE_RULES = new Set(['swift.discarded-try', 'swift.catch-exit', 'rust.discarded-ok', 'rust.let-underscore']);
export function scanSource(file, source) {
  if (/(^|\/)(?:tests|Tests)(\/|$)/.test(file) || /(?:^|\/|_)tests\.rs$/.test(file)) return [];
  const language = file.endsWith('.swift') ? 'swift' : 'rust';
  let code = maskSource(source, language);
  if (language === 'rust') code = maskRustTests(code);
  const patterns = language === 'swift' ? [
    ['swift.discarded-try', /(?:^|[;{])\s*(?:_\s*=\s*)?try\s*\?/gm],
    ['swift.catch-exit', /\bcatch\b[^{}]*\{\s*(?:return|break|continue)\b[^;{}]*;?\s*\}/g],
    ['swift.print', /\b(?:print|debugPrint)\s*\(/g],
    ['swift.nslog', /\bNSLog\s*\(/g],
    ['swift.stderr', /\bFileHandle\s*\.\s*standardError\s*\.\s*write\s*\(/g],
    ['swift.os-log', /\bos_log\s*\(/g],
    ['swift.record', /(?:\.|\?\.)\s*record\s*\(\s*level\s*:/g],
    ...(/\bimport\s+os\s*\.\s*log\b/.test(code) ? [['swift.logger', /\bLogger\s*\(/g]] : []),
  ] : [...['eprintln', 'println', 'dbg'].map(name => [`rust.${name}`, new RegExp(`\\b${name}\\s*!\\s*[(\\[{]`, 'g')]),
    ['rust.discarded-ok', /\.\s*ok\s*\(\s*\)\s*;/g],
    ['rust.let-underscore', /\blet\s+_\s*=\s*[^;]+;/g],
  ];
  const rawLines = source.split('\n');
  const exemptions = new Map();
  const invalidExemptions = [];
  for (const [index, line] of rawLines.entries()) {
    // Require an actual line comment, not a marker inside a string or block comment.
    const marker = /\/\/\s*log-exempt:\s*(.*)$/.exec(line);
    if (!marker) continue;
    const offset = rawLines.slice(0, index).reduce((sum, s) => sum + s.length + 1, 0) + marker.index;
    if (language === 'rust' && maskRustTests(code.slice(0, offset) + 'X' + code.slice(offset + 1))[offset] !== 'X') continue;
    // The comment opener must be lexically active: appending a sentinel survives masking only then.
    const probe = source.slice(0, offset) + ' LOG_EXEMPT_SENTINEL';
    if (!maskSource(probe, language).endsWith(' LOG_EXEMPT_SENTINEL')) continue;
    if (marker[1].replace(/\s/g, '').length < 3) invalidExemptions.push({file, rule: 'usage.invalid-exemption', line: index + 1, column: marker.index + 1, excerpt: line.trim()});
    else exemptions.set(index + 1, true);
  }
  const findings = patterns.flatMap(([rule, pattern]) => [...code.matchAll(pattern)].filter(match => {
    if (rule === 'swift.discarded-try') {
      const stack = [];
      for (const c of code.slice(0, match.index + match[0].indexOf('try'))) {
        if ('([{'.includes(c)) stack.push(c);
        else if (')]}'.includes(c)) stack.pop();
      }
      // A closure body starts statements even inside an argument; bare argument parentheses do not.
      if (stack.at(-1) === '(' || stack.at(-1) === '[') return false;
    }
    if (rule === 'rust.discarded-ok') {
      const before = code.slice(0, match.index);
      const statement = before.slice(Math.max(before.lastIndexOf(';'), before.lastIndexOf('{'), before.lastIndexOf('}')) + 1).trim();
      return !/\b(?:let|return|break)\b|=(?!=)/.test(statement);
    }
    if (rule === 'swift.catch-exit') {
      const body = match[0].slice(match[0].indexOf('{') + 1, -1).trim();
      // A newline beginning another statement is not part of the exit's return value.
      return !/\n\s*(?:[A-Za-z_][\w.]*\s*(?:\(|[+*\/?!-]?=(?!=))|let\b|var\b|throw\b|try\b|return\b|break\b|continue\b)/.test(body);
    }
    return true;
  }).map(match => {
    const offset = match.index + (rule === 'swift.discarded-try' ? match[0].indexOf('try') : 0);
    const line = source.slice(0, offset).split('\n').length;
    return { file, rule, column: offset - source.lastIndexOf('\n', offset), line,
      excerpt: rawLines[line - 1].trim() };
  })).filter(item => !EXEMPTIBLE_RULES.has(item.rule) || (!exemptions.has(item.line) && !exemptions.has(item.line - 1)));
  return [...invalidExemptions, ...findings].sort((a, b) => a.line - b.line || a.column - b.column);
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
// Only logging bypasses may be permanent exceptions; a discarded failure is
// either recorded or carries a reasoned log-exempt marker at the site.
export const ALLOWLIST_RULES = new Set(['swift.nslog', 'swift.stderr', 'swift.os-log', 'swift.logger', 'swift.record', 'swift.print', 'rust.eprintln', 'rust.println', 'rust.dbg']);
function validateAllowlist(allowlist) {
  if (allowlist.version !== 1 || !Array.isArray(allowlist.entries)) throw new Error('allowlist: invalid format');
  const keys = new Set();
  for (const entry of allowlist.entries) {
    const key = `${entry.file}:${entry.rule}`;
    if (typeof entry.file !== 'string' || !/^(macos\/Sources\/.*\.swift|rust\/lithe-core\/src\/.*\.rs)$/.test(entry.file) || entry.file.split('/').some(part => part === '..') || !ALLOWLIST_RULES.has(entry.rule) || !Number.isSafeInteger(entry.count) || entry.count <= 0 || keys.has(key) || !entry.reason?.trim()) throw new Error(`allowlist: invalid or duplicate entry ${key}`);
    keys.add(key);
  }
}
// There is no stock quota: every violation outside the allowlist fails, and an
// allowlist count must match the sources exactly so a freed slot cannot be reused.
export function compareUsage(violations, allowlist) {
  validateAllowlist(allowlist);
  const counts = new Map();
  for (const violation of violations) {
    const key = `${violation.file}:${violation.rule}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const expected = new Map(allowlist.entries.map(entry => [`${entry.file}:${entry.rule}`, entry.count]));
  const problems = violations.filter(v => v.rule === 'usage.invalid-exemption').map(v => `${v.file}:${v.line}: invalid log-exempt reason`);
  for (const key of new Set([...counts.keys(), ...expected.keys()])) {
    if (key.endsWith(':usage.invalid-exemption')) continue;
    const actual = counts.get(key) ?? 0;
    const limit = expected.get(key) ?? 0;
    if (actual > limit) {
      for (const item of violations.filter(item => `${item.file}:${item.rule}` === key)) problems.push(`${item.file}:${item.line}: ${item.rule}: ${RULES[item.rule][0]}; ${RULES[item.rule][1]}`);
      if (limit > 0) problems.push(`${key}: ${actual} violations exceed allowlist ${limit}`);
    } else if (actual < limit) problems.push(`${key}: allowlist ${limit} exceeds actual ${actual}; lower the allowlist count`);
  }
  return problems;
}
export async function verify(root = ROOT) {
  const [violations, allowlist] = await Promise.all([
    scanRepository(root),
    readFile(path.join(root, 'scripts/logging/log-usage-allowlist.json'), 'utf8').then(JSON.parse),
  ]);
  const problems = compareUsage(violations, allowlist);
  if (problems.length) throw new Error(problems.join('\n'));
  return { violations, allowlist };
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(path.resolve(process.argv[1]))).href) {
  if (process.argv.length > 2) { console.error('usage: node scripts/logging/verify-log-usage.mjs'); process.exitCode = 1; }
  else verify().then(({ allowlist }) => console.log(`Log usage verified: 0 violations; ${allowlist.entries.reduce((sum, entry) => sum + entry.count, 0)} permanent exceptions`)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
