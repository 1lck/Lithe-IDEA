// Explicit source diagnostic only. The Python supervisor owns the hard case/suite
// deadlines and Windows job before releasing this process. No product is started.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:net';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const SOURCE = Buffer.from('source-original\0bytes\r\n');

export function bounded(promise, ms, label, timers = globalThis) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = timers.setTimeout(() => reject(new Error(`${label} deadline`)), ms);
  })]).finally(() => timers.clearTimeout(timer));
}

export function snapshotTree(root) {
  if (!existsSync(root)) return [];
  const rows = [];
  function visit(path) {
    const stat = lstatSync(path, { bigint: true });
    assert(!stat.isSymbolicLink(), 'diagnostic fixture must not traverse links');
    const row = { path: relative(root, path).replaceAll('\\', '/') || '.',
      kind: stat.isDirectory() ? 'directory' : 'file',
      identity: { dev: String(stat.dev), ino: String(stat.ino), birthtimeNs: String(stat.birthtimeNs) } };
    if (stat.isFile()) {
      const bytes = readFileSync(path);
      Object.assign(row, { bytes: bytes.length, sha256: hash(bytes), base64: bytes.toString('base64') });
    }
    rows.push(row);
    if (stat.isDirectory()) for (const name of readdirSync(path).sort()) if (name !== '.svn') visit(join(path, name));
  }
  visit(root);
  return rows;
}

function item(snapshot, path) { return snapshot.tree.find(row => row.path === path); }
function schedule(snapshot, path, expected) {
  const entry = [...snapshot.statusXml.matchAll(/<entry\s+path="([^"]+)"\s*>([\s\S]*?)<\/entry>/g)]
    .find(match => match[1].replaceAll('\\', '/') === path);
  assert(entry, `missing WC status for ${path}`);
  assert.match(entry[2], new RegExp(`\\bitem="${expected}"`), `${path} WC schedule`);
}

export async function finalize(record, actions) {
  for (const [name, action] of Object.entries(actions)) {
    try { record[name] = await action(); }
    catch (error) { record[`${name}Error`] = String(error); }
  }
}

export function assertObservation(name, before, after, reply) {
  const source = item(before, 'source.txt');
  assert(source && source.sha256 === hash(SOURCE), 'original source bytes required');
  if (name === 'missing-leaf') {
    assert.deepEqual(reply.result, {});
    assert(!reply.error);
    assert(!item(after, 'source.txt'));
    assert.equal(item(after, 'target.txt')?.kind, 'file');
    assert.equal(item(after, 'target.txt')?.sha256, source.sha256);
    assert(!item(after, 'target.txt/source.txt'));
    schedule(after, 'source.txt', 'deleted');
    schedule(after, 'target.txt', 'added');
    return { diagnosis: 'exact-leaf-success', exactLeaf: true, safetyPass: false,
      limitation: 'single unopposed diagnostic success does not establish atomic no-replacement' };
  }
  if (name === 'target-file') {
    assert(reply.error, 'Provider must report the observed SVN obstruction failure');
    assert.match(JSON.stringify(reply.error), /E155033/);
    assert.deepEqual(item(after, 'source.txt'), source, 'failure preserves source bytes and identity');
    assert.deepEqual(item(after, 'target.txt'), item(before, 'target.txt'), 'failure preserves intruder bytes and identity');
    assert(!item(after, 'target.txt/source.txt'));
    schedule(before, 'target.txt', 'unversioned');
    schedule(after, 'source.txt', 'normal');
    schedule(after, 'target.txt', 'added');
    return { diagnosis: 'failure-with-wc-metadata-side-effect', exactLeaf: false, safetyPass: false,
      refreshRequired: true, wcMetadataChanged: true };
  }
  assert.equal(name, 'target-directory');
  assert.deepEqual(reply.result, {});
  assert(!reply.error);
  assert(!item(after, 'source.txt'));
  assert.equal(item(after, 'target.txt')?.kind, 'directory');
  assert.deepEqual(item(after, 'target.txt')?.identity, item(before, 'target.txt')?.identity);
  assert.equal(item(after, 'target.txt/source.txt')?.sha256, source.sha256);
  schedule(after, 'source.txt', 'deleted');
  schedule(after, 'target.txt/source.txt', 'added');
  return { diagnosis: 'provider-success-wrong-endpoint', exactLeaf: false, safetyPass: false, refreshRequired: true };
}

function peer(child, wire, fail) {
  let buffer = Buffer.alloc(0), sequence = 0;
  const pending = new Map();
  child.stdout.on('data', bytes => {
    try {
      buffer = Buffer.concat([buffer, bytes]);
      assert(buffer.length <= 4e6, 'Provider output budget');
      for (;;) {
        const header = buffer.indexOf('\r\n\r\n');
        if (header < 0) break;
        const match = /Content-Length: (\d+)/i.exec(buffer.subarray(0, header).toString());
        assert(match && +match[1] <= 4e6);
        const end = header + 4 + +match[1];
        if (buffer.length < end) break;
        const message = JSON.parse(buffer.subarray(header + 4, end));
        buffer = buffer.subarray(end);
        wire.push({ direction: 'received', message });
        pending.get(message.id)?.resolve(message);
        pending.delete(message.id);
      }
    } catch (error) { fail(error); }
  });
  child.on('error', fail);
  child.on('close', () => { for (const request of pending.values()) request.reject(new Error('Provider exited during request')); pending.clear(); });
  const send = message => {
    const bytes = Buffer.from(JSON.stringify(message));
    wire.push({ direction: 'sent', message });
    child.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${bytes.length}\r\n\r\n`), bytes]));
  };
  return { request(method, params) {
    const id = ++sequence;
    const response = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    send({ jsonrpc: '2.0', id, method, params });
    return bounded(response, 12000, method).finally(() => pending.delete(id));
  }, notify(method, params) { send({ jsonrpc: '2.0', method, params }); } };
}

export async function diagnose(inputs, name, root, runtime, report) {
  const record = { name, events: [], wire: [], commands: [], status: 'error', safetyPass: false };
  const checkpoint = () => writeFileSync(report, JSON.stringify(record, null, 2));
  let child, server, exitPromise, asynchronousError;
  const sockets = new Set();
  const svn = join(inputs.svnRoot, 'bin/svn.exe');
  const wc = join(root, 'wc');
  const env = { ...process.env, APPDATA: join(root, 'appdata'), LOCALAPPDATA: join(root, 'localappdata') };
  const started = performance.now();
  const run = (exe, args, cwd = root) => {
    const start = performance.now();
    try {
      const stdout = execFileSync(exe, args, { cwd, env, timeout: 8000, maxBuffer: 4e6, encoding: 'utf8', windowsHide: true });
      record.commands.push({ exe, args, exitCode: 0, durationMs: performance.now() - start, stdout });
      return stdout;
    } catch (error) {
      record.commands.push({ exe, args, exitCode: error.status, durationMs: performance.now() - start,
        stdout: String(error.stdout), stderr: String(error.stderr), error: String(error) });
      throw error;
    }
  };
  const snapshot = () => ({ tree: snapshotTree(wc),
    statusXml: run(svn, ['status', '--xml', '--verbose', '--no-ignore'], wc),
    infoXml: run(svn, ['info', '--xml', '--depth', 'infinity'], wc) });
  try {
    assert(!existsSync(root), 'exclusive fresh case directory');
    mkdirSync(root); mkdirSync(env.APPDATA); mkdirSync(env.LOCALAPPDATA);
    run(join(inputs.svnRoot, 'bin/svnadmin.exe'), ['create', join(root, 'repo')]);
    run(svn, ['--non-interactive', 'checkout', pathToFileURL(join(root, 'repo')).href, wc]);
    writeFileSync(join(wc, 'source.txt'), SOURCE);
    run(svn, ['add', 'source.txt'], wc); run(svn, ['commit', '-m', 'diagnostic initial'], wc);
    record.initial = snapshot();
    checkpoint();
    let gated = false;
    server = createServer(socket => {
      sockets.add(socket); socket.on('close', () => sockets.delete(socket));
      socket.on('error', error => { asynchronousError ??= error; });
      let input = '';
      socket.on('data', bytes => {
        try {
          input += bytes.toString(); assert(input.length < 65536, 'gate event budget');
          for (;;) {
            const newline = input.indexOf('\n'); if (newline < 0) break;
            const event = JSON.parse(input.slice(0, newline)); input = input.slice(newline + 1);
            record.events.push(event);
            if (event.phase === 'before-svn') {
              if (event.argv.includes('move')) {
                assert(!gated); gated = true;
                assert.deepEqual(event.argv.slice(-2), ['source.txt@', 'target.txt']);
                assert(!existsSync(join(wc, 'target.txt')));
                record.beforeInjection = snapshot();
                checkpoint();
                if (name === 'target-file') writeFileSync(join(wc, 'target.txt'), Buffer.from('intruder-do-not-overwrite\0'), { flag: 'wx' });
                if (name === 'target-directory') mkdirSync(join(wc, 'target.txt'));
                record.before = snapshot();
                record.events.push({ phase: 'injected-after-provider-status-before-svn-start', name });
                checkpoint();
              }
              socket.write('release\n');
            }
          }
        } catch (error) { asynchronousError ??= error; socket.destroy(); }
      });
    });
    await bounded(new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); }), 3000, 'gate listen');
    child = spawn(inputs.node, [join(runtime, 'svn-provider.mjs'), '--stdio'], { cwd: root,
      env: { ...env, R16_REAL_SVN: svn, R16_GATE_PORT: String(server.address().port) },
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    exitPromise = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
    record.providerPid = child.pid; record.stderr = '';
    child.stderr.on('data', bytes => {
      record.stderr += bytes.toString();
      if (record.stderr.length > 4e6) { asynchronousError ??= new Error('stderr budget'); child.kill(); }
    });
    child.stdin.on('error', error => { asynchronousError ??= error; });
    const rpc = peer(child, record.wire, error => { asynchronousError ??= error; child.kill(); });
    record.initialize = await rpc.request('initialize', { processId: process.pid, capabilities: { experimental: { litheVcs: { versions: [1] } } } });
    assert.equal(record.initialize.result.capabilities.experimental.litheVcs.capabilities.fileOperations, 1);
    rpc.notify('initialized', {});
    const params = { root: { path: wc }, tool: { executable: inputs.gate } };
    record.statusReply = await rpc.request('lithe/vcs/status', params);
    assert(!record.statusReply.error, 'actual Provider status must precede the injection gate');
    record.reply = await rpc.request('lithe/vcs/fileOperation', { ...params, kind: 'move', from: 'source.txt', to: 'target.txt' });
    if (asynchronousError) throw asynchronousError;
    assert(gated);
    assert(record.events.some(event => event.phase === 'svn-exited'));
    record.after = snapshot();
    record.observation = assertObservation(name, record.before, record.after, record.reply);
    record.shutdown = await rpc.request('shutdown', null); rpc.notify('exit'); child.stdin.end();
    record.providerExit = await bounded(exitPromise, 3000, 'provider exit');
    assert.equal(record.providerExit.code, 0);
    record.status = 'diagnosis-matched';
  } catch (error) { record.error = error.stack; }
  finally {
    // Evidence capture and every cleanup run even when an assertion/handler throws.
    await finalize(record, {
      final: () => existsSync(wc) ? snapshot() : null,
      socketCleanup: async () => {
        for (const socket of sockets) socket.destroy();
        if (server) await bounded(new Promise(resolve => server.close(resolve)), 3000, 'gate close');
        return { sockets: sockets.size, closed: true };
      },
      processCleanup: async () => {
        if (!child) return null;
        if (child.exitCode === null && child.signalCode === null) child.kill();
        return bounded(exitPromise, 3000, 'cleanup provider exit');
      },
    });
    record.durationMs = performance.now() - started;
    record.processTreeOwner = 'external Windows job; supervisor terminates and verifies zero active members on every exit';
    writeFileSync(report, JSON.stringify(record, null, 2));
  }
  return record.status === 'diagnosis-matched' && !record.finalError && !record.socketCleanupError && !record.processCleanupError ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  assert.equal(process.env.LITHE_VCS_DIAGNOSTIC_OWNER, 'windows-job-supervisor',
    'use the Python diagnostic entry with external case/suite deadlines');
  if (process.argv[2] === '--snapshot') {
    const [, input, wc, report] = process.argv.slice(2);
    const inputs = JSON.parse(readFileSync(input, 'utf8').replace(/^\uFEFF/, ''));
    const record = { tree: snapshotTree(wc), operationOutcome: 'unknown', refreshRequired: true };
    try {
      record.statusXml = execFileSync(join(inputs.svnRoot, 'bin/svn.exe'), ['status', '--xml', '--verbose', '--no-ignore'],
        { cwd: wc, timeout: 8000, maxBuffer: 4e6, encoding: 'utf8', windowsHide: true });
    } catch (error) { record.statusError = String(error); process.exitCode = 1; }
    finally { writeFileSync(report, JSON.stringify(record, null, 2)); }
  } else {
    const [input, name, root, runtime, report] = process.argv.slice(2);
    process.exitCode = await diagnose(JSON.parse(readFileSync(input, 'utf8').replace(/^\uFEFF/, '')), name, root, runtime, report);
  }
}
