#!/usr/bin/env node

// Offline diagnostic assertions only; never launch an installed Provider or SVN.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runProcess} from '../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';
import {parseJUnitCases} from '../../.agents/skills/write-stable-tests/scripts/parse-junit-cases.mjs';
import {writeTestReportArtifacts} from '../../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--report' || !args[1].endsWith('.json')) {
  throw new Error('Usage: node scripts/plugins/test-plugin-vcs-move-diagnostic.mjs --report <path.json>');
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const report = path.resolve(args[1]);
const result = await runProcess({command: process.execPath,
  args: ['--test', '--test-timeout=15000', '--test-reporter=junit',
    path.join(root, 'scripts/plugins/host-acceptance/vcs-move-diagnostic_test.mjs')],
  cwd: root, timeoutMs: 60000});
const tests = parseJUnitCases(result.stdout);
if (!tests.length || result.code !== 0 || result.timedOut) {
  tests.push({name: 'diagnostic assertion runner', status: result.timedOut ? 'timeout' : 'failed',
    durationMs: result.durationMs, maxMs: 60000,
    details: `exit=${result.code}, timedOut=${result.timedOut}; ${result.stderr}`});
}
fs.mkdirSync(path.dirname(report), {recursive: true});
fs.writeFileSync(report.replace(/\.json$/, '.log'), result.stdout + result.stderr);
fs.writeFileSync(report, JSON.stringify({schemaVersion: 1, runner: 'node', warnMs: 1000,
  maxMs: 15000, suite: {timedOut: result.timedOut, durationMs: result.durationMs}, tests}, null, 2) + '\n');
writeTestReportArtifacts(report);
console.log(`Recorded ${tests.length} diagnostic assertion results.`);
if (tests.some(test => !['passed', 'skipped'].includes(test.status)
    || (test.status === 'passed' && test.durationMs >= (test.maxMs ?? 15000)))) process.exitCode = 1;
