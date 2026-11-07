import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, cp, rm, readFile, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { ROOT, GENERIC_DESCRIPTIONS, generate, validateCatalog, loadCatalog, planGeneration } from './generate-log-events.mjs';
import { scanSource, scanRepository, compareUsage, verify } from './verify-log-usage.mjs';

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
    ['path traversal', e => { e.channel = 'app/..'; }, /segment/],
    ['unsupported depth', e => { e.channel = 'app/a/b'; }, /channel shape/],
    ['Windows device', e => { e.channel = 'app/con.txt'; }, /segment/],
    ['Windows trailing dot', e => { e.channel = 'app/git.'; }, /segment/],
    ['span collision', e => { e.span = { failureLevel: 'error' }; e.fields.duration = field('int'); }, /automatic fields/],
    ['malformed message', e => { e.message = 'Result {missing'; }, /malformed/],
    ['generated parameter collision', e => { e.span = { failureLevel: 'error' }; e.fields.state = field('token'); }, /parameter collision/],
    ['unknown property', e => { e.extra = true; }, /unknown property/],
  ];
  for (const [name, edit, pattern] of cases) {
    const e = event(); edit(e);
    assert.throws(() => validateCatalog(catalog(e)), pattern, name);
  }
  const plugin = { ...event(), id: 'plugins.test.finished', channel: 'plugins/example' };
  assert.throws(() => validateCatalog([{ version: 1, root: 'plugins', events: [plugin] }]), /channel shape/);
  const e = event();
  const duplicate = catalog(e); duplicate[0].events.push(structuredClone(e));
  assert.throws(() => validateCatalog(duplicate), /duplicate id/);
  const collision = catalog({ ...e, id: 'app.test.operation', span: { failureLevel: 'error' } });
  collision[0].events.push({ ...e, id: 'app.test.operation.started' });
  assert.throws(() => validateCatalog(collision), /duplicate id/);
});

test('changed is a past-tense outcome; arbitrary stages remain invalid', { timeout: 1000 }, () => {
  const e = event(); e.id = 'app.test.stage_changed';
  assert.doesNotThrow(() => validateCatalog(catalog(e)));
  e.id = 'app.test.stage_change';
  assert.throws(() => validateCatalog(catalog(e)), /past tense/);
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

test('usage gate has no stock quota and allowlist counts stay exact', { timeout: 1000 }, () => {
  const violation = { file: 'macos/Sources/Example.swift', rule: 'swift.nslog', line: 3 };
  const empty = { version: 1, entries: [] };
  const allowlist = { version: 1, entries: [{ file: violation.file, rule: violation.rule, count: 1, reason: 'Machine-read protocol line consumed by the test runner' }] };
  assert.match(compareUsage([violation], empty).join('\n'), /Example.swift:3.*emit a generated/);
  assert.deepEqual(compareUsage([violation], allowlist), []);
  assert.match(compareUsage([violation, violation], allowlist).join('\n'), /exceed allowlist 1/);
  assert.match(compareUsage([], allowlist).join('\n'), /lower the allowlist count/);
});

test('checked-in catalog and log usage agree with current sources', { timeout: 15000 }, async () => {
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

test('failure usage rules distinguish discarded statements from expressions', { timeout: 1000 }, () => {
  const file = 'macos/Sources/Example.swift';
  const positives = ['try? work()', '_ = try? work()', 'defer { try? work() }', 'x(); try? work()', 'catch { return }', 'catch {\n return nil\n}', 'catch let error {\n break\n}', 'catch { continue }', 'print(1)', 'debugPrint(1)'];
  const expected = ['swift.discarded-try', 'swift.discarded-try', 'swift.discarded-try', 'swift.discarded-try', 'swift.catch-exit', 'swift.catch-exit', 'swift.catch-exit', 'swift.catch-exit', 'swift.print', 'swift.print'];
  positives.forEach((s, i) => assert.deepEqual(scanSource(file, s).map(v => v.rule), [expected[i]], s));
  for (const s of ['let x = try? work()', 'if let x = try? work() {}', 'guard let x = try? work() else {}', 'return try? work()', 'call(try? work())', 'call(\n try? work()\n)', 'let a = [\n try? work()\n]', 'let x = "try? work(); print(1)"', '// try? work()', '/* catch { return } */', 'catch { log(error); return }', 'catch { return nil\n x = 1\n}', 'catch {\nreturn nil\nprint(1)\n}']) {
    assert.equal(scanSource(file, s).filter(v => v.rule !== 'swift.print').length, 0, s);
  }
  const rust = 'rust/lithe-core/src/example.rs';
  assert.deepEqual(scanSource(rust, 'fn f() { work().ok(); let _ = tx.send(1); }').map(v => v.rule), ['rust.discarded-ok', 'rust.let-underscore']);
  for (const s of ['let x = work().ok();', 'return work().ok();', '// let _ = work();', 'let s = "work().ok();";', '#[cfg(test)] mod tests { let _ = work(); work().ok(); }']) assert.deepEqual(scanSource(rust, s), [], s);
});

test('Rust test file exclusion requires a complete tests suffix', { timeout: 1000 }, () => {
  const source = 'fn f() { let _ = work(); }';
  for (const file of ['tests.rs', 'rust/lithe-core/src/tests.rs', 'rust/lithe-core/src/remote/sessions_integration_tests.rs']) {
    assert.deepEqual(scanSource(file, source), [], file);
  }
  for (const file of ['rust/lithe-core/src/contests.rs', 'rust/lithe-core/src/tests_helper.rs', 'rust/lithe-core/src/test.rs']) {
    assert.deepEqual(scanSource(file, source).map(v => v.rule), ['rust.let-underscore'], file);
  }
});

test('line exemptions require an active comment and a nonempty concrete reason', { timeout: 1000 }, () => {
  const file = 'macos/Sources/Example.swift';
  for (const s of ['try? work() // log-exempt: best effort cleanup', '// log-exempt: best effort cleanup\ntry? work()']) assert.deepEqual(scanSource(file, s), []);
  for (const s of ['// log-exempt: \ntry? work()', 'try? work() // log-exempt: a b']) assert.ok(scanSource(file, s).some(v => v.rule === 'usage.invalid-exemption'));
  for (const s of ['let s = "// log-exempt: ignored"\ntry? work()', '/* // log-exempt: ignored */\ntry? work()', '// log-exempt: cleanup\n\ntry? work()']) assert.ok(scanSource(file, s).some(v => v.rule === 'swift.discarded-try'));
  assert.deepEqual(scanSource('rust/lithe-core/src/example.rs', '#[cfg(test)] mod tests {\n// log-exempt: \nlet _ = work();\n}'), []);
  assert.equal(scanSource(file, '// log-exempt: \n// log-exempt: valid reason').filter(v => v.rule === 'usage.invalid-exemption').length, 1);
  // A marker cannot hide a logging bypass: print/NSLog/eprintln! stay reportable.
  for (const s of ['print("x") // log-exempt: debugging aid', '// log-exempt: legacy\nNSLog("x")']) assert.ok(scanSource(file, s).some(v => v.rule === 'swift.print' || v.rule === 'swift.nslog'));
  assert.ok(scanSource('rust/lithe-core/src/example.rs', '// log-exempt: legacy\neprintln!("x");').some(v => v.rule === 'rust.eprintln'));
});

test('discarded failures fail without a marker and cannot be allowlisted', { timeout: 1000 }, () => {
  for (const rule of ['swift.discarded-try', 'swift.catch-exit', 'rust.discarded-ok', 'rust.let-underscore']) {
    const file = rule.startsWith('rust.') ? 'rust/lithe-core/src/example.rs' : 'macos/Sources/Example.swift';
    const violation = {file, rule, line: 1};
    assert.match(compareUsage([violation], {version:1, entries:[]}).join('\n'), new RegExp(`${file.replace(/\./g, '\\.')}:1: ${rule.replace('.', '\\.')}`));
    assert.throws(() => compareUsage([violation], {version:1, entries:[{file, rule, count:1, reason:'legacy code'}]}), /allowlist: invalid/);
  }
});

test('generated references use catalog channel, event identity and operation', { timeout: 1000 }, async () => {
  const source = await readFile(path.join(ROOT, 'macos/Sources/LitheModuleAPI/Logging/LogEvents.generated.swift'), 'utf8');
  assert.match(source, /public var reference: LogRecordReference/);
  assert.match(source, /LogRecordReference\(channel: channel.rawValue, event: Self.id, op: operationID\)/);
});


test('helper production roots are gated while remote server and standalone binaries are excluded', { timeout: 5000 }, async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'lithe-helper-log-usage-'));
  try {
    const roots = ['macos/Sources', ...['core', 'core-rules', 'agent-host', 'git-host', 'ide-host', 'remote'].map(name => `rust/lithe-${name}/src`)];
    await Promise.all(roots.map(directory => mkdir(path.join(root, directory), { recursive: true })));
    const included = ['core-rules', 'agent-host', 'git-host', 'ide-host', 'remote'].map(name => `rust/lithe-${name}/src/production.rs`);
    const excluded = ['rust/lithe-remote/src/server/worker.rs', 'rust/lithe-remote/src/bin/server.rs', 'rust/lithe-ide-host/src/bin/mcp.rs'];
    await Promise.all([...included, ...excluded].map(async file => {
      await mkdir(path.dirname(path.join(root, file)), { recursive: true });
      await writeFile(path.join(root, file), 'fn run() { eprintln!("failure"); let _ = operation(); }');
    }));
    const findings = await scanRepository(root);
    assert.deepEqual([...new Set(findings.map(f => f.file))].sort(), included.sort());
    for (const file of included) {
      assert.deepEqual(findings.filter(f => f.file === file).map(f => f.rule), ['rust.eprintln', 'rust.let-underscore']);
      const bypass = findings.find(f => f.file === file && f.rule === 'rust.eprintln');
      assert.deepEqual(compareUsage([bypass], { version: 1, entries: [{ file, rule: bypass.rule, count: 1, reason: 'Test of helper path validation for a machine protocol exception' }] }), []);
    }
    assert.equal(scanSource(included[0], '#[cfg(all(test, unix))] mod tests { fn run() { let _ = operation(); eprintln!("test"); } }').length, 0);
    assert.equal(scanSource(included[0], '#[cfg(all(unix, feature = "client"))] fn run() { let _ = operation(); }').length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
