#!/usr/bin/env node
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { publishAutoBuild, selectPlugins, ghCommand, validateBuildIdentity, runCommand } from './publish-autobuild.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const source = 'a'.repeat(40);
const pluginBytes = Buffer.from('already signed upstream ZIP');
const registered = { id: 'php', tagPrefix: 'plugin-php-v' };
function version(value, names = [`PHP-${value}.zip`]) {
  return { version: value, downloads: names.map(name => ({ downloadURL: `https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/plugin-php-v${value}/${name}`, sha256: hash(pluginBytes) })) };
}
function catalog(versions = [version('1.0.0')]) {
  return [{ schemaVersion: 1, plugins: [registered] }, { schemaVersion: 1, plugins: [{ id: 'php', versions }, { id: 'java', versions: [{ version: '9.0.0' }] }] }];
}

function fixture(t, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lithe-autobuild-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dist = path.join(root, 'dist'), temp = path.join(root, 'temp');
  fs.mkdirSync(dist); fs.mkdirSync(temp);
  const config = { repository: 'example/lithe', source, build: options.build ?? '20261015.124354', timestamp: options.timestamp ?? '2026-10-15T12:43:54Z', version: '0.4.0', dist, runnerTemp: temp };
  function write(name, bytes) { const file = path.join(dist, name); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
  for (const platform of ['arm64', 'x86_64', 'windows-x64']) {
    write(`identity-${platform}.json`, JSON.stringify({ source, build: config.build, timestamp: config.timestamp, version: config.version }));
    const name = `Lithe-${config.version}-${platform}.${platform === 'windows-x64' ? 'exe' : 'dmg'}`;
    write(name, name); write(`${name}.sha256`, `${hash(name)}  ${name}\n`);
  }
  for (const architecture of ['arm64', 'x86_64']) {
    const names = [`Lithe-preview-${config.build}-${architecture}.zip`, `${options.appName ?? 'Lithe'}${config.build}-${options.baselineBuild ?? '58.1'}-${architecture}.delta`];
    for (const name of names) write(`sparkle-${architecture}/${name}`, name);
    write(`sparkle-${architecture}/orphan.delta`, 'not in manifest');
    const quote = architecture === 'arm64' ? "'" : '"';
    const enclosures = names.map(name => `<enclosure url=${quote}https://github.com/example/lithe/releases/download/AutoBuild/${name}${quote} length="${Buffer.byteLength(name)}" sparkle:edSignature="${Buffer.alloc(64).toString('base64')}"/>`);
    write(`sparkle-${architecture}/appcast-preview-${architecture}.xml`, `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>${config.build}</sparkle:version><pubDate>${new Date(config.timestamp).toUTCString()}</pubDate>${enclosures[0]}<sparkle:deltas>${enclosures[1]}</sparkle:deltas></item></channel></rss>`);
  }
  const stale = ['Lithe-0.3.0-arm64.dmg', 'Lithe-preview-58.1-arm64.zip', 'PHP-0.9.0.zip', 'old-windows.exe'];
  let assets = stale.map((name, i) => ({ id: i + 1, name, size: 1, state: 'uploaded', digest: `sha256:${hash('x')}` }));
  const remoteBytes = new Map(), legacyBytes = new Map(), legacyAssets = [];
  if (options.legacyBaselineTimestamp) for (const architecture of ['arm64', 'x86_64']) {
    const name = `appcast-preview-${architecture}.xml`;
    const bytes = Buffer.from(`<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>58.1</sparkle:version><pubDate>${new Date(options.legacyBaselineTimestamp).toUTCString()}</pubDate></item></channel></rss>`);
    legacyBytes.set(name, bytes);
    legacyAssets.push({ id: 90 + legacyAssets.length, name, size: bytes.length, state: 'uploaded' });
  }
  if (!options.bootstrap) for (const architecture of ['arm64', 'x86_64']) {
    const name = `appcast-preview-${architecture}.xml`;
    const baselineBuild = options.baselineBuild ?? '58.1';
    const baselineTime = options[`${architecture}BaselineTimestamp`] ?? options.baselineTimestamp ?? '2026-10-14T12:43:54Z';
    if (options.missingBaseline === architecture) continue;
    const bytes = Buffer.from(options.malformedBaseline ? '<rss>' : `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>${baselineBuild}</sparkle:version><pubDate>${new Date(baselineTime).toUTCString()}</pubDate></item></channel></rss>`);
    assets.push({ id: 90 + assets.length, name, size: bytes.length, state: 'uploaded', digest: `sha256:${hash(bytes)}` });
    remoteBytes.set(name, bytes);
  }
  let downloadAttempts = 0;
  let releaseTitle = 'AutoBuild';
  let id = 100, exists = !options.bootstrap, legacy = true, legacyRef = true, ref = 'b'.repeat(40);
  const calls = [];
  const [registry, index] = catalog();
  function interrupt(stage) {
    if (options.failAt !== stage) return;
    options.failAt = undefined;
    throw new Error(`HTTP 422 interrupted at ${stage}`);
  }
  const run = (command, args) => {
    calls.push([command, ...args]);
    if (command === 'git') {
      if (args[0] === 'fetch') { assert.equal(args.at(-1), config.source); return ''; }
      assert.match(args[1], new RegExp(`^${config.source}:Plugins/marketplace/`));
      return JSON.stringify(args[1].endsWith('official-plugins.json') ? registry : index);
    }
    if (command === 'ruby') return runCommand(command, args);
    assert.equal(command, 'gh');
    if (args[0] === 'release') {
      if (args[1] === 'download') {
        const directory = args[args.indexOf('--dir') + 1], name = args[args.indexOf('--pattern') + 1];
        const file = path.join(directory, name);
        assert.ok(!fs.existsSync(file), 'each bounded retry removes partial downloads');
        if (!['AutoBuild', 'preview-0.3.0'].includes(args[2]) && options.retryDownload && downloadAttempts++ === 0) {
          fs.writeFileSync(file, 'partial'); throw new Error('HTTP 503');
        }
        fs.writeFileSync(file, args[2] === 'AutoBuild' ? remoteBytes.get(name) : args[2] === 'preview-0.3.0' ? legacyBytes.get(name) : options.badSHA ? 'corrupt ZIP' : pluginBytes);
        return '';
      }
      if (args[1] === 'create') { assert.equal(exists, false); exists = true; assets = []; remoteBytes.clear(); releaseTitle = args[args.indexOf('--title') + 1]; return ''; }
      if (args[1] === 'upload') {
        const file = args[3], name = path.basename(file);
        if (options.failUpload && (options.failUpload === true || name.endsWith('.xml'))) throw new Error('HTTP 422 upload failed');
        interrupt(`upload:${name}`);
        if (options.failAt === `starter:${name}`) {
          assets = assets.filter(asset => asset.name !== name);
          remoteBytes.delete(name);
          assets.push({ id: id++, name, size: 0, state: 'starter', digest: null });
          interrupt(`starter:${name}`);
        }
        const bytes = fs.readFileSync(file); remoteBytes.set(name, bytes);
        assets = assets.filter(asset => asset.name !== name);
        assets.push({ id: id++, name, size: bytes.length, state: 'uploaded', digest: options.noDigest ? null : `sha256:${options.badDigest ? hash('corrupt') : hash(bytes)}` });
        interrupt(`uploaded:${name}`);
        return '';
      }
      if (args[1] === 'edit') {
        interrupt('metadata');
        releaseTitle = args[args.indexOf('--title') + 1];
        assert.equal(releaseTitle, validateBuildIdentity(config.build, config.timestamp));
        const notes = fs.readFileSync(args[args.indexOf('--notes-file') + 1], 'utf8');
        assert.ok(notes.includes(releaseTitle));
        assert.match(notes, /普通用户建议使用 Stable/); assert.match(notes, /Ordinary users should use the Stable/);
        return '';
      }
    }
    if (args.includes('--paginate')) {
      if (['arm64', 'x86_64'].every(architecture => remoteBytes.get(`appcast-preview-${architecture}.xml`)?.equals(fs.readFileSync(path.join(dist, `sparkle-${architecture}/appcast-preview-${architecture}.xml`))))) interrupt('verification');
      return JSON.stringify([args.some(arg => arg.includes('/releases/2/assets')) ? legacyAssets : assets]);
    }
    const endpoint = args.find(arg => arg.startsWith('repos/'));
    if (args.includes('DELETE')) {
      if (endpoint.includes('/assets/')) { assets = assets.filter(asset => asset.id !== Number(endpoint.split('/').at(-1))); interrupt('cleanup'); }
      else if (endpoint.endsWith('/releases/2')) { legacy = false; interrupt('legacy-release'); }
      else if (endpoint.endsWith('/git/refs/tags/preview-0.3.0')) { legacyRef = false; interrupt('legacy-tag'); }
      else assert.fail(`Unexpected deletion ${endpoint}`);
      return '';
    }
    if (args.includes('PATCH')) { interrupt('tag'); assert.ok(args.includes('force=true')); ref = args.find(arg => arg.startsWith('sha=')).slice(4); return '{}'; }
    if (endpoint.endsWith('/releases/tags/AutoBuild')) { if (!exists) throw new Error('HTTP 404'); return JSON.stringify({ id: 1, name: releaseTitle, prerelease: true, draft: false }); }
    if (endpoint.endsWith('/git/ref/tags/AutoBuild')) return JSON.stringify({ object: { sha: ref } });
    if (endpoint.endsWith('/releases/tags/preview-0.3.0')) { if (!legacy) throw new Error('HTTP 404'); return JSON.stringify({ id: 2 }); }
    if (endpoint.endsWith('/git/ref/tags/preview-0.3.0')) { if (!legacyRef) throw new Error('HTTP 404'); return '{}'; }
    assert.fail(`Unexpected command: ${command} ${args.join(' ')}`);
  };
  return { config, run, calls, temp, dist, stale, index, remoteBytes, assets: () => assets, state: () => ({ ref, legacy, legacyRef }), removeAsset: name => { assets = assets.filter(asset => asset.name !== name); remoteBytes.delete(name); } };
}
const deletes = f => f.calls.filter(call => call.includes('DELETE'));
const uploads = f => f.calls.filter(call => call[1] === 'release' && call[2] === 'upload');

for (const appName of ['Lithe', 'Lithe-Dev']) {
  await test(`publication accepts ${appName} Sparkle delta names for both architectures`, { timeout: 5000 }, t => {
    const f = fixture(t, { appName, build: '20261017.074424', timestamp: '2026-10-17T07:44:24Z', baselineBuild: '20261016.101031', baselineTimestamp: '2026-10-16T10:10:31Z' });
    const manifest = publishAutoBuild(f.config, { run: f.run });
    for (const architecture of ['arm64', 'x86_64']) {
      const name = `${appName}20261017.074424-20261016.101031-${architecture}.delta`;
      assert.ok(manifest.includes(name));
      assert.deepEqual(f.remoteBytes.get(name), Buffer.from(name));
    }
    assert.deepEqual(f.assets().map(asset => asset.name).sort(), manifest);
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });

  for (const [reason, rename] of [
    ['target build', name => name.replace('20261015.124354', '20261015.1243540')],
    ['architecture', name => name.replace('-arm64.delta', '-x86_64.delta')],
    ['application name', name => name.replace(appName, `${appName}-Other`)],
    ['asset path', name => `../${name}`],
    ['extension', name => `${name}.zip`],
  ]) await test(`${appName} delta with unexpected ${reason} fails before release mutation`, { timeout: 5000 }, t => {
    const f = fixture(t, { appName });
    const directory = path.join(f.dist, 'sparkle-arm64');
    const feed = path.join(directory, 'appcast-preview-arm64.xml');
    const name = `${appName}${f.config.build}-58.1-arm64.delta`;
    const unexpected = rename(name);
    fs.writeFileSync(path.join(directory, path.basename(unexpected)), name);
    fs.writeFileSync(feed, fs.readFileSync(feed, 'utf8').replace(name, unexpected));
    assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Unexpected appcast asset/);
    assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
    assert.ok(!f.calls.some(call => call.includes('PATCH') || call.includes('create') || call.includes('edit')));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}

for (const failAt of [
  'uploaded:autobuild-publication.json',
  'starter:autobuild-publication.json',
  'starter:appcast-preview-arm64.xml',
  'starter:appcast-preview-x86_64.xml',
  'upload:Lithe-0.4.0-windows-x64.exe',
  'uploaded:Lithe-preview-20261015.124354-arm64.zip',
  'uploaded:appcast-preview-arm64.xml',
  'upload:appcast-preview-x86_64.xml',
  'verification', 'tag', 'metadata', 'cleanup', 'legacy-release', 'legacy-tag',
]) await test(`same publication resumes after ${failAt}`, { timeout: 5000 }, t => {
  const f = fixture(t, { failAt });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  assert.deepEqual(fs.readdirSync(f.temp), []);
  const names = publishAutoBuild(f.config, { run: f.run });
  assert.deepEqual(f.assets().map(asset => asset.name).sort(), names);
  assert.deepEqual(f.state(), { ref: source, legacy: false, legacyRef: false });
  const checkpoint = JSON.parse(f.remoteBytes.get('autobuild-publication.json'));
  assert.equal(checkpoint.source, source);
  assert.equal(checkpoint.build, f.config.build);
  assert.equal(checkpoint.timestamp, f.config.timestamp);
  assert.equal(checkpoint.version, f.config.version);
  for (const asset of checkpoint.assets) {
    assert.equal(hash(f.remoteBytes.get(asset.name)), asset.sha256);
    assert.equal(f.remoteBytes.get(asset.name).length, asset.size);
  }
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

await test('same identity with changed installer bytes fails before mutation', { timeout: 5000 }, t => {
  const f = fixture(t, { failAt: 'upload:appcast-preview-x86_64.xml' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  const installer = `Lithe-${f.config.version}-windows-x64.exe`;
  fs.writeFileSync(path.join(f.dist, installer), 'different but locally checksummed bytes');
  fs.writeFileSync(path.join(f.dist, `${installer}.sha256`), `${hash('different but locally checksummed bytes')}  ${installer}\n`);
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Conflicting AutoBuild publication/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE') || call.includes('edit')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

await test('checkpoint is uploaded before installers and feeds and binds every target asset', { timeout: 5000 }, t => {
  const f = fixture(t);
  const names = publishAutoBuild(f.config, { run: f.run });
  assert.equal(path.basename(uploads(f)[0][4]), 'autobuild-publication.json');
  const checkpoint = JSON.parse(f.remoteBytes.get('autobuild-publication.json'));
  assert.equal(checkpoint.schemaVersion, 1);
  assert.equal(checkpoint.repository, f.config.repository);
  assert.deepEqual(checkpoint.assets.map(asset => asset.name), names.filter(name => name !== 'autobuild-publication.json'));
});

await test('same build without its publication checkpoint remains rejected', { timeout: 5000 }, t => {
  const f = fixture(t); publishAutoBuild(f.config, { run: f.run });
  f.removeAsset('autobuild-publication.json');
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE')));
});

for (const bootstrap of [false, true]) await test(`same plan repairs a missing feed after interrupted clobber (bootstrap=${bootstrap})`, { timeout: 5000 }, t => {
  const f = fixture(t, { bootstrap, failAt: 'upload:appcast-preview-x86_64.xml' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  f.removeAsset('appcast-preview-x86_64.xml');
  const names = publishAutoBuild(f.config, { run: f.run });
  assert.deepEqual(f.assets().map(asset => asset.name).sort(), names);
  assert.deepEqual(f.state(), { ref: source, legacy: false, legacyRef: false });
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

for (const change of ['source', 'plugin', 'feed']) await test(`same identity rejects changed ${change} before any mutation`, { timeout: 5000 }, t => {
  const f = fixture(t, { failAt: 'uploaded:autobuild-publication.json' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  if (change === 'source') {
    f.config.source = 'c'.repeat(40);
    for (const platform of ['arm64', 'x86_64', 'windows-x64']) {
      const file = path.join(f.dist, `identity-${platform}.json`);
      fs.writeFileSync(file, JSON.stringify({ ...JSON.parse(fs.readFileSync(file, 'utf8')), source: f.config.source }));
    }
  } else if (change === 'plugin') {
    f.index.plugins[0].versions = [version('1.1.0')];
  } else {
    const file = path.join(f.dist, 'sparkle-arm64/appcast-preview-arm64.xml');
    fs.appendFileSync(file, '\n');
  }
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Conflicting AutoBuild publication/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE') || call.includes('edit')));
});

await test('a newer committed checkpoint blocks older retries before feeds change', { timeout: 5000 }, t => {
  const f = fixture(t, { failAt: 'uploaded:autobuild-publication.json' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  const name = 'autobuild-publication.json';
  const checkpoint = JSON.parse(f.remoteBytes.get(name));
  checkpoint.build = '20261016.000001'; checkpoint.timestamp = '2026-10-16T00:00:01Z';
  f.remoteBytes.set(name, Buffer.from(JSON.stringify(checkpoint) + '\n'));
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Conflicting AutoBuild publication/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE')));
});

await test('a later publication may replace an older checkpoint', { timeout: 5000 }, t => {
  const previous = fixture(t, { failAt: 'uploaded:autobuild-publication.json' });
  assert.throws(() => publishAutoBuild(previous.config, { run: previous.run }), /interrupted at/);
  const f = fixture(t, { build: '20261016.000001', timestamp: '2026-10-16T00:00:01Z' });
  const name = 'autobuild-publication.json', bytes = previous.remoteBytes.get(name);
  f.remoteBytes.set(name, bytes);
  f.assets().push({ id: 200, name, size: bytes.length, state: 'uploaded', digest: `sha256:${hash(bytes)}` });
  publishAutoBuild(f.config, { run: f.run });
  assert.equal(JSON.parse(f.remoteBytes.get(name)).build, f.config.build);
});

await test('exact checkpoint does not allow a different uploaded feed at the same instant', { timeout: 5000 }, t => {
  const f = fixture(t); publishAutoBuild(f.config, { run: f.run });
  const name = 'appcast-preview-arm64.xml';
  f.remoteBytes.set(name, Buffer.concat([f.remoteBytes.get(name), Buffer.from('\n')]));
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE')));
});

await test('same plan resumes and verifies bytes when GitHub omits asset digests', { timeout: 5000 }, t => {
  const f = fixture(t, { noDigest: true, failAt: 'tag' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  const names = publishAutoBuild(f.config, { run: f.run });
  assert.deepEqual(f.assets().map(asset => asset.name).sort(), names);
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

for (const corrupt of ['json', 'schema', 'identity']) await test(`invalid publication checkpoint (${corrupt}) fails before mutation`, { timeout: 5000 }, t => {
  const f = fixture(t, { failAt: 'uploaded:autobuild-publication.json' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  const name = 'autobuild-publication.json';
  const checkpoint = JSON.parse(f.remoteBytes.get(name));
  if (corrupt === 'schema') checkpoint.schemaVersion = 2;
  if (corrupt === 'identity') checkpoint.build = '20261015.124353';
  f.remoteBytes.set(name, Buffer.from(corrupt === 'json' ? '{broken' : JSON.stringify(checkpoint)));
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }));
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

await test('starter feed without a matching checkpoint cannot bypass baseline checks', { timeout: 5000 }, t => {
  const f = fixture(t, { failAt: 'starter:appcast-preview-arm64.xml' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
  f.removeAsset('autobuild-publication.json');
  const count = f.calls.length;
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Invalid published appcast baseline/);
  assert.ok(!f.calls.slice(count).some(call => call.includes('upload') || call.includes('PATCH') || call.includes('DELETE')));
});

await test('latest numeric version wins; all variants deduplicate and bundled Java is excluded', { timeout: 5000 }, () => {
  const [registry, index] = catalog([version('1.9.0'), version('1.10.0', ['PHP-arm.zip', 'PHP-x64.zip', 'PHP-arm.zip']), version('2.0.0-beta')]);
  assert.deepEqual(selectPlugins(registry, index).map(item => item.name), ['PHP-arm.zip', 'PHP-x64.zip']);
});
await test('untrusted URLs and conflicting index hashes are rejected', { timeout: 5000 }, () => {
  const [registry, index] = catalog();
  index.plugins[0].versions[0].downloads[0].downloadURL = 'https://github.com/attacker/repo/releases/download/plugin-php-v1.0.0/PHP.zip';
  assert.throws(() => selectPlugins(registry, index), /Untrusted/);
  const [r, i] = catalog();
  const duplicate = structuredClone(i.plugins[0].versions[0].downloads[0]); duplicate.sha256 = '0'.repeat(64);
  i.plugins[0].versions[0].downloads.push(duplicate);
  assert.throws(() => selectPlugins(r, i), /Conflicting/);
});
await test('publication accepts legacy baseline, uploads data before feeds and repeats idempotently', { timeout: 5000 }, t => {
  const f = fixture(t);
  const manifest = publishAutoBuild(f.config, { run: f.run });
  assert.deepEqual(f.assets().map(asset => asset.name).sort(), manifest);
  for (const stale of f.stale) assert.ok(!manifest.includes(stale));
  assert.ok(!manifest.includes('orphan.delta'));
  const uploadCalls = uploads(f), firstXML = uploadCalls.findIndex(call => call[4].endsWith('.xml'));
  assert.ok(firstXML > 0); assert.ok(uploadCalls.slice(firstXML).every(call => call[4].endsWith('.xml')));
  const firstDelete = f.calls.findIndex(call => call.includes('DELETE'));
  assert.ok(firstDelete > f.calls.findLastIndex(call => call[2] === 'upload'));
  assert.equal(deletes(f).length, f.stale.length + 2);
  assert.ok(f.calls.some(call => call.includes('PATCH') && call.includes(`sha=${source}`) && call.includes('force=true')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
  const count = deletes(f).length;
  assert.deepEqual(publishAutoBuild(f.config, { run: f.run }), manifest);
  assert.equal(deletes(f).length, count);
});
await test('bootstrap creates exactly AutoBuild before uploading', { timeout: 5000 }, t => {
  const f = fixture(t, { bootstrap: true }); publishAutoBuild(f.config, { run: f.run });
  const create = f.calls.find(call => call[2] === 'create');
  assert.equal(create[3], 'AutoBuild'); assert.equal(create[create.indexOf('--title') + 1], 'AutoBuild — 构建自 2026-10-15 12:43:54 UTC');
});
await test('bad plugin SHA prevents every release mutation and cleans staging', { timeout: 5000 }, t => {
  const f = fixture(t, { badSHA: true });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Plugin SHA-256 mismatch/);
  assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
  assert.ok(!f.calls.some(call => call.includes('PATCH') || call.includes('create') || call.includes('edit')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});
for (const failUpload of [true, 'xml']) await test(`failed ${failUpload === true ? 'data' : 'XML'} upload never prunes or retires legacy release`, { timeout: 5000 }, t => {
  const f = fixture(t, { failUpload });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /upload failed/);
  assert.equal(deletes(f).length, 0); assert.ok(!f.calls.some(call => call.includes('PATCH')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});
await test('remote digest verification failure prevents cleanup and tag movement', { timeout: 5000 }, t => {
  const f = fixture(t, { badDigest: true });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Published digest mismatch/);
  assert.equal(deletes(f).length, 0); assert.ok(!f.calls.some(call => call.includes('PATCH')));
});
for (const [field, wrong] of [['source', 'b'.repeat(40)], ['build', '58.1'], ['timestamp', '2026-10-15T12:43:55Z'], ['version', '0.3.0']]) await test(`Windows and macOS must share exact pinned ${field}`, { timeout: 5000 }, t => {
  const f = fixture(t);
  const identity = { source, build: f.config.build, timestamp: f.config.timestamp, version: f.config.version, [field]: wrong };
  fs.writeFileSync(path.join(f.dist, 'identity-windows-x64.json'), JSON.stringify(identity));
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Artifact identity mismatch: windows-x64/);
  assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
});
await test('transient gh failures have a fixed retry budget and permanent failures stop immediately', { timeout: 5000 }, () => {
  let calls = 0, cleanups = 0;
  assert.throws(() => ghCommand(['release', 'download'], () => { calls++; throw new Error('HTTP 503'); }, () => cleanups++), /503/);
  assert.equal(calls, 3); assert.equal(cleanups, 3);
  calls = 0;
  assert.throws(() => ghCommand([], () => { calls++; throw new Error('HTTP 403'); }), /403/);
  assert.equal(calls, 1);
});

await test('missing server digests trigger bounded byte verification before cleanup', { timeout: 5000 }, t => {
  const f = fixture(t, { noDigest: true });
  const manifest = publishAutoBuild(f.config, { run: f.run });
  const verified = f.calls.filter(call => call[2] === 'download' && call[3] === 'AutoBuild');
  assert.equal(verified.length, manifest.length * 2 + 2);
  assert.ok(f.calls.findIndex(call => call[2] === 'download' && call[3] === 'AutoBuild') < f.calls.findIndex(call => call.includes('DELETE')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});
await test('plugin download retries discard partial bytes before SHA verification', { timeout: 5000 }, t => {
  const f = fixture(t, { retryDownload: true });
  publishAutoBuild(f.config, { run: f.run });
  assert.equal(f.calls.filter(call => call[2] === 'download' && call[3] !== 'AutoBuild').length, 2);
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

await test('new publishers require exact UTC compact identity from the same ISO second', { timeout: 5000 }, () => {
  assert.equal(validateBuildIdentity('20261015.000005', '2026-10-15T00:00:05Z'), 'AutoBuild — 构建自 2026-10-15 00:00:05 UTC');
  runCommand('ruby', ['scripts/autobuild-identity.rb', '--identity', '20261015.000005', '2026-10-15T00:00:05Z']);
  for (const [build, timestamp] of [
    ['58.1', '2026-10-15T12:43:54Z'],
    ['20261015.124355', '2026-10-15T12:43:54Z'],
    ['20260230.124354', '2026-02-30T12:43:54Z'],
    ['20261015.124354', '2026-10-15T12:43:54+00:00'],
    ['20261015.124354', '2026-10-15T12:43:54.000Z'],
  ]) {
    assert.throws(() => validateBuildIdentity(build, timestamp), /AutoBuild/);
    assert.throws(() => runCommand('ruby', ['scripts/autobuild-identity.rb', '--identity', build, timestamp]), /ruby scripts\/autobuild-identity\.rb failed/);
  }
  assert.throws(() => runCommand('ruby', ['scripts/autobuild-identity.rb', '--identity', '20261015.000005']), /ruby scripts\/autobuild-identity\.rb failed/);
});
for (const baselineTimestamp of ['2026-10-15T12:43:54Z', '2026-10-15T12:43:55Z', '2026-10-16T00:00:00Z']) {
  await test(`same-second or backward build fails before mutation: ${baselineTimestamp}`, { timeout: 5000 }, t => {
    const f = fixture(t, { baselineTimestamp });
    assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer than appcast baseline/);
    assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
    assert.ok(!f.calls.some(call => call.includes('PATCH') || call.includes('create') || call.includes('edit')));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}
await test('both appcast baselines must be older even when only Intel is ahead', { timeout: 5000 }, t => {
  const f = fixture(t, { x86_64BaselineTimestamp: '2026-10-15T12:43:55Z' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer than appcast baseline/);
  assert.equal(uploads(f).length, 0);
});
await test('timestamp baseline identity must agree with its published date', { timeout: 5000 }, t => {
  const f = fixture(t, { baselineBuild: '20261014.124353' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /baseline identity\/date mismatch/);
  assert.equal(uploads(f).length, 0);
});
await test('a later UTC day accepts a valid timestamp baseline', { timeout: 5000 }, t => {
  const f = fixture(t, { baselineBuild: '20261014.124354' });
  publishAutoBuild(f.config, { run: f.run });
  assert.ok(uploads(f).length > 0);
});
for (const [name, options, message] of [
  ['missing feed with an existing ZIP', { missingBaseline: 'arm64' }, /Missing published appcast baseline/],
  ['malformed published feed', { malformedBaseline: true }, /Expected one AutoBuild update|REXML/],
]) {
  await test(`${name} fails before any release mutation`, { timeout: 5000 }, t => {
    const f = fixture(t, options);
    assert.throws(() => publishAutoBuild(f.config, { run: f.run }), message);
    assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
    assert.ok(!f.calls.some(call => call.includes('PATCH') || call.includes('create') || call.includes('edit')));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}
await test('local appcast pubDate must equal the shared build instant', { timeout: 5000 }, t => {
  const f = fixture(t);
  const file = path.join(f.dist, 'sparkle-arm64/appcast-preview-arm64.xml');
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('12:43:54', '12:43:53'));
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /Wrong AutoBuild feed identity or timestamp/);
  assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
});

for (const failAt of ['upload:autobuild-publication.json', 'starter:autobuild-publication.json']) {
  for (const [plan, build, timestamp, accepts] of [
    ['older', '20261013.124354', '2026-10-13T12:43:54Z', false],
    ['same-second', '20261014.124354', '2026-10-14T12:43:54Z', false],
    ['original', '20261015.124354', '2026-10-15T12:43:54Z', true],
    ['newer', '20261016.000001', '2026-10-16T00:00:01Z', true],
  ]) await test(`interrupted migration retains the legacy baseline for ${plan} plan after ${failAt}`, { timeout: 5000 }, t => {
    const f = fixture(t, { bootstrap: true, legacyBaselineTimestamp: '2026-10-14T12:43:54Z', failAt });
    assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
    assert.equal(f.assets().length, failAt.startsWith('starter:') ? 1 : 0);
    assert.equal(f.state().legacy, true);
    assert.deepEqual(fs.readdirSync(f.temp), []);
    const next = fixture(t, { build, timestamp });
    fs.cpSync(next.dist, f.dist, { recursive: true });
    Object.assign(f.config, { build, timestamp });
    const count = f.calls.length;
    if (accepts) {
      const names = publishAutoBuild(f.config, { run: f.run });
      assert.deepEqual(f.assets().map(asset => asset.name).sort(), names);
      assert.deepEqual(f.state(), { ref: source, legacy: false, legacyRef: false });
    } else {
      assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer/);
      assert.ok(!f.calls.slice(count).some(call => call.includes('create') || call.includes('upload') || call.includes('PATCH') || call.includes('DELETE') || call.includes('edit')));
      assert.equal(f.state().legacy, true);
    }
    assert.ok(f.calls.slice(count).some(call => call[2] === 'download' && call[3] === 'preview-0.3.0'));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}

for (const failAt of ['uploaded:autobuild-publication.json', 'uploaded:appcast-preview-arm64.xml']) {
  await test(`same plan resumes migration while legacy feeds remain after ${failAt}`, { timeout: 5000 }, t => {
    const f = fixture(t, { bootstrap: true, legacyBaselineTimestamp: '2026-10-14T12:43:54Z', failAt });
    assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /interrupted at/);
    const count = f.calls.length;
    const names = publishAutoBuild(f.config, { run: f.run });
    assert.deepEqual(f.assets().map(asset => asset.name).sort(), names);
    assert.deepEqual(f.state(), { ref: source, legacy: false, legacyRef: false });
    assert.ok(f.calls.slice(count).some(call => call[2] === 'download' && call[3] === 'preview-0.3.0'));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}

await test('existing AutoBuild feeds do not bypass a newer legacy preview baseline', { timeout: 5000 }, t => {
  const f = fixture(t, { legacyBaselineTimestamp: '2026-10-16T00:00:00Z' });
  assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer/);
  assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
  assert.ok(!f.calls.some(call => call.includes('create') || call.includes('PATCH') || call.includes('edit')));
  assert.deepEqual(fs.readdirSync(f.temp), []);
});

for (const [timestamp, accepts] of [['2026-10-14T12:43:54Z', true], ['2026-10-15T12:43:54Z', false], ['2026-10-16T00:00:00Z', false]]) {
  await test(`initial migration validates the legacy preview baseline: ${timestamp}`, { timeout: 5000 }, t => {
    const f = fixture(t, { bootstrap: true, legacyBaselineTimestamp: timestamp });
    if (accepts) {
      publishAutoBuild(f.config, { run: f.run });
      assert.ok(uploads(f).length > 0);
    } else {
      assert.throws(() => publishAutoBuild(f.config, { run: f.run }), /strictly newer/);
      assert.equal(uploads(f).length, 0); assert.equal(deletes(f).length, 0);
      assert.ok(!f.calls.some(call => call.includes('create') || call.includes('PATCH')));
    }
    assert.ok(f.calls.some(call => call[2] === 'download' && call[3] === 'preview-0.3.0'));
    assert.deepEqual(fs.readdirSync(f.temp), []);
  });
}
