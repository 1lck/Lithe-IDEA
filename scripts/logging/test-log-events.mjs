import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, cp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { ROOT, GENERIC_DESCRIPTIONS, generate, validateCatalog, loadCatalog, planGeneration } from './generate-log-events.mjs';
import { scanSource, compareUsage, verify } from './verify-log-usage.mjs';

const event = () => ({ id: 'app.test.finished', channel: 'app', level: 'info', message: 'Test finished', owner: 'lithe-core', fields: {} });
const catalog = e => [{ version: 1, root: 'app', events: [e] }];
const field = (type, extra = {}) => ({ type, required: true, description: 'Context supplied by the catalog validation test case', ...extra });

test('field descriptions reject type boilerplate and require event-specific context', { timeout: 1000 }, () => {
  assert.equal(GENERIC_DESCRIPTIONS.length, 10);
  for (const description of GENERIC_DESCRIPTIONS) {
    const e = event();
    e.fields.value = field('token', { description });
    assert.throws(() => validateCatalog(catalog(e)), /generic description/, description);
    e.fields.value.description = `  ${description}  `;
    assert.throws(() => validateCatalog(catalog(e)), /generic description/);
  }
  for (const description of ['short context', '123456789012345', '  123456789012345  ']) {
    const e = event();
    e.fields.value = field('token', { description });
    assert.throws(() => validateCatalog(catalog(e)), /at least 16 characters/);
  }
  const e = event();
  e.fields.value = field('token', { description: 'Git subcommand that ran, e.g. fetch or push' });
  assert.doesNotThrow(() => validateCatalog(catalog(e)));
  delete e.fields.value.description;
  assert.throws(() => validateCatalog(catalog(e)), /description: expected nonempty string/);
});

test('rejects invalid catalogs before generation', { timeout: 1000 }, () => {
  const cases = [
    ['unknown type', e => { e.fields.value = field('raw'); }, /unknown type/],
    ['text without reason', e => { e.fields.value = field('text'); }, /text requires reason/],
    ['undeclared placeholder', e => { e.message = 'Result {missing}'; }, /undeclared field/],
    ['channel root', e => { e.channel = 'unknown'; }, /channel root/],
    ['duration suffix', e => { e.fields.elapsed_ms = field('duration'); }, /must not end in _ms/],
    ['reserved field', e => { e.fields.seq = field('int'); }, /reserved/],
    ['encoded collision', e => { e.fields.elapsed = field('duration'); e.fields.elapsed_ms = field('int'); }, /collision/],
    ['channel type', e => { e.channel = 'app/{provider}'; e.fields.provider = field('token'); }, /required id/],
    ['optional channel', e => { e.channel = 'app/{provider}'; e.fields.provider = field('id', { required: false }); }, /required id/],
    ['path traversal', e => { e.channel = 'app/../bad'; }, /segment/],
    ['span collision', e => { e.span = { failureLevel: 'error' }; e.fields.duration = field('int'); }, /automatic fields/],
    ['malformed message', e => { e.message = 'Result {missing'; }, /malformed/],
    ['generated parameter collision', e => { e.span = { failureLevel: 'error' }; e.fields.state = field('token'); }, /parameter collision/],
    ['unknown property', e => { e.extra = true; }, /unknown property/],
  ];
  for (const [name, edit, pattern] of cases) {
    const e = event(); edit(e);
    assert.throws(() => validateCatalog(catalog(e)), pattern, name);
  }
  const e = event();
  const duplicate = catalog(e); duplicate[0].events.push(structuredClone(e));
  assert.throws(() => validateCatalog(duplicate), /duplicate id/);
  const collision = catalog({ ...e, id: 'app.test.operation', span: { failureLevel: 'error' } });
  collision[0].events.push({ ...e, id: 'app.test.operation.started' });
  assert.throws(() => validateCatalog(collision), /duplicate id/);
});

test('span expansion has debug starts and typed terminal metadata', { timeout: 1000 }, () => {
  const e = event(); e.id = 'app.test.operation'; e.span = { failureLevel: 'error' };
  const { events } = validateCatalog(catalog(e));
  assert.deepEqual(events.map(e => [e.id, e.level]), [
    ['app.test.operation.failed', 'error'], ['app.test.operation.finished', 'info'], ['app.test.operation.started', 'debug'],
  ]);
  assert.equal(events[0].fields.error.type, 'error');
  assert.equal(events[1].fields.duration.type, 'duration');
  assert.deepEqual(events[2].fields, {});
});

test('generation is deterministic; check detects drift without writes; invalid catalog writes nothing', { timeout: 15000 }, async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'lithe-log-events-'));
  try {
    await cp(path.join(ROOT, 'shared/logging'), path.join(root, 'shared/logging'), { recursive: true });
    await generate(root);
    const { outputs } = await planGeneration(root);
    for (const [file, text] of outputs) assert.equal(await readFile(path.join(root, file), 'utf8'), text);
    await generate(root, true);
    const target = path.join(root, 'macos/Sources/LitheModuleAPI/Logging/LogEvents.generated.swift');
    await writeFile(target, 'drift\n');
    await assert.rejects(generate(root, true), /drifted/);
    assert.equal(await readFile(target, 'utf8'), 'drift\n');
    const input = path.join(root, 'shared/logging/events/update.json');
    const invalid = JSON.parse(await readFile(input, 'utf8'));
    invalid.events[0].fields.bad = field('unknown');
    await writeFile(input, JSON.stringify(invalid));
    await assert.rejects(generate(root), /unknown type/);
    assert.equal(await readFile(target, 'utf8'), 'drift\n');
    // Exercise the actual CLI's nonzero check path from a separate checkout-shaped directory.
    await cp(path.join(ROOT, 'scripts/logging'), path.join(root, 'scripts/logging'), { recursive: true });
    const cli = spawnSync(process.execPath, [path.join(root, 'scripts/logging/generate-log-events.mjs'), '--check'], { encoding: 'utf8', timeout: 5000 });
    assert.notEqual(cli.status, 0);
    assert.match(cli.stderr, /unknown type/);
    delete invalid.events[0].fields.bad;
    await writeFile(input, JSON.stringify(invalid));
    const drift = spawnSync(process.execPath, [path.join(root, 'scripts/logging/generate-log-events.mjs'), '--check'], { encoding: 'utf8', timeout: 5000 });
    assert.notEqual(drift.status, 0); assert.match(drift.stderr, /drifted/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('usage scanner ignores comments, literal contents and bounded cfg(test) items', { timeout: 1000 }, () => {
  const swift = 'import os.log\n// NSLog("ignored")\nlet text = "NSLog(ignored)"\nNSLog("real")\nFileHandle\n.standardError.write(data)\nos_log("value")\nlet log = Logger()\nlogger?.record(\nlevel: "warning", scope: "app", message: "value")';
  assert.deepEqual(scanSource('macos/Sources/Example.swift', swift).map(e => e.rule), ['swift.nslog', 'swift.stderr', 'swift.os-log', 'swift.logger', 'swift.record']);
  const rust = '// eprintln!("ignored")\nlet value = r##"dbg!(x)"##;\n#[cfg(test)]\nmod checks { fn check() { eprintln!("test"); let s = "}"; } }\nfn production() { eprintln!("real"); println!("real"); dbg!(1); }\n';
  assert.deepEqual(scanSource('rust/lithe-core/src/example.rs', rust).map(e => e.rule), ['rust.eprintln', 'rust.println', 'rust.dbg']);
  assert.equal(scanSource('macos/Tests/Example.swift', swift).length, 0);
  assert.equal(scanSource('rust/lithe-core/src/tests.rs', rust).length, 0);
});

test('usage baseline forbids growth and requires tightening after migration', { timeout: 1000 }, () => {
  const violation = { file: 'macos/Sources/Example.swift', rule: 'swift.nslog', line: 3 };
  const empty = { version: 1, entries: [] };
  const baseline = { version: 1, entries: [{ file: violation.file, rule: violation.rule, count: 1, reason: '待 PR2/PR3 迁移' }] };
  assert.deepEqual(compareUsage([violation], empty, baseline), []);
  assert.match(compareUsage([violation, violation], empty, baseline).join('\n'), /Example.swift:3.*emit a generated/);
  assert.match(compareUsage([], empty, baseline).join('\n'), /tighten baseline/);
  assert.match(compareUsage([violation], empty, empty).join('\n'), /exceed baseline 0/);
});

test('checked-in catalog and baseline agree with current sources', { timeout: 15000 }, async () => {
  const contract = await loadCatalog();
  assert.ok(contract.events.length > 0);
  await generate(ROOT, true);
  await verify();
});

// These are actual host inputs; output/argv/source fields must remain undeclared.
test('macOS performance events preserve numeric evidence without raw payloads', { timeout: 1000 }, async () => {
  const { events } = await loadCatalog();
  const opening = events.find(event => event.id === 'perf.editor.open_measured');
  assert.equal(opening.fields.model.type, 'duration');
  assert.equal(opening.fields.utf16_length.type, 'int');
  assert.equal(opening.fields.reused.type, 'bool');
  assert.equal(Object.hasOwn(opening.fields, 'text'), false);
  const latency = events.find(event => event.id === 'perf.settings.latency_measured');
  for (const key of ['input_ns', 'received_ns', 'selected_ns', 'time_ns']) assert.equal(latency.fields[key].type, 'int');
  const git = events.find(event => event.id === 'perf.git.command_finished');
  assert.equal(Object.hasOwn(git.fields, 'arguments'), false);
  assert.equal(Object.hasOwn(git.fields, 'output'), false);
});
