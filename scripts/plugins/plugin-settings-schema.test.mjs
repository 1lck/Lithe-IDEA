import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const schema = JSON.parse(readFileSync(new URL('../../shared/contracts/plugins/v1/plugin-manifest.schema.json', import.meta.url), 'utf8'));
const textSetting = schema.$defs.setting.allOf.find((rule) => rule.if.properties.type.const === 'text');
const cases = [
  {
    name: 'text defaults',
    pattern: textSetting.then.properties.default.pattern,
    valid: ['', 'dev', 'a-b', '\u4e2d\u6587', 'a\u2028b', 'a\u2029b'],
    invalid: ['-dev', 'dev\n', '\n', 'dev\r', 'dev\r\n', 'a\nb', 'dev\t', 'dev\u0000', 'dev\u0085'],
  },
  {
    name: 'option values and settings page IDs',
    pattern: schema.$defs.settingToken.pattern,
    valid: ['elixir', 'build-system_2.0', '-'],
    invalid: ['', 'elixir\n', 'elixir\r\n', 'elixir\u2028', 'elixir\u2029', 'a\nb', 'has space'],
  },
  {
    name: 'settings action IDs',
    pattern: schema.$defs.settingAction.properties.id.pattern,
    valid: ['rebuildPlt', 'a', 'action2'],
    invalid: ['', 'rebuildPlt\n', 'rebuildPlt\r\n', 'rebuildPlt\u2028', 'rebuildPlt\u2029', 'a\nb', 'Bad', 'rebuild-plt'],
  },
  {
    name: 'settings action function IDs',
    pattern: schema.$defs.settingAction.properties.function.pattern,
    valid: ['dialyzer.rebuild', 'refresh', 'action2.runNow'],
    invalid: ['', 'dialyzer.rebuild\n', 'dialyzer.rebuild\r\n', 'dialyzer.rebuild\u2028', 'dialyzer.rebuild\u2029', 'a\nb', 'Dialyzer.rebuild', 'dialyzer.', 'dialyzer..rebuild'],
  },
];

for (const { name, pattern, valid, invalid } of cases) {
  test(`${name} use the same strict boundary in JavaScript and Python`, { timeout: 10_000 }, () => {
    const values = [...valid, ...invalid];
    const expected = values.map((_, index) => index < valid.length);
    assert.deepEqual(values.map((value) => new RegExp(pattern, 'u').test(value)), expected, 'ECMAScript');

    // Cross-engine integration: Python's '$' accepts a final LF, unlike
    // ECMAScript without multiline mode. Exercise the checked-in patterns.
    const result = execFileSync('python3', ['-c', [
      'import json, re, sys',
      'data = json.load(sys.stdin)',
      'pattern = re.compile(data["pattern"])',
      'json.dump([pattern.search(value) is not None for value in data["values"]], sys.stdout)',
    ].join('\n')], {
      input: JSON.stringify({ pattern, values }),
      encoding: 'utf8',
      timeout: 5_000,
      maxBuffer: 64 * 1024,
    });
    assert.deepEqual(JSON.parse(result), expected, 'Python');
  });
}
