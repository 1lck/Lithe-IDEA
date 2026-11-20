#!/usr/bin/env node
// Stands in for a language server so ide-compare-latency.mjs can see what an editor asks it and how
// long the server takes to answer, without changing either side: it starts the real server with the
// same arguments and working directory, passes both directions through unchanged, and writes one
// JSON line per message to the log.
//
// Usage (from the wrapper script ide-compare-latency.mjs writes in place of the server):
//   node ide-compare-lsp-proxy.mjs --real SERVER --log FILE -- [server arguments...]
//
// Bytes are forwarded as they arrive and parsed afterwards, so the proxy adds only a pipe hop to
// each message. The log names every message by direction (c2s from the editor, s2c from the
// server), kind, id, method, size and arrival time (milliseconds since the Unix epoch, fractional);
// a response also carries the method of its request and the milliseconds since that request
// arrived. The messages that set up the session (initialize, the configuration the editor answers
// with, capability registrations) are logged whole, so the settings each editor gives the server
// can be compared, and so are hovers, whose position tells the one the pointer asked for on its
// way from the one on the word; everything else is logged without its content. Nothing is written for a run
// that exchanges no messages, such as `gopls version`.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';

const FULL_BODY_METHODS = new Set([
  'initialize',
  'initialized',
  'workspace/didChangeConfiguration',
  'workspace/configuration',
  'client/registerCapability',
  'textDocument/hover',
]);

const { real, logFile, serverArgs } = parseArgs(process.argv.slice(2));
const now = () => performance.timeOrigin + performance.now();
const pending = [];
let fd = null;
const write = (record) => pending.push(`${JSON.stringify(record)}\n`);
const flush = () => {
  if (pending.length === 0) return;
  if (fd === null) fd = fs.openSync(logFile, 'a');
  fs.writeSync(fd, pending.join(''));
  pending.length = 0;
};
setInterval(flush, 500).unref();

const child = spawn(real, serverArgs, { stdio: ['pipe', 'pipe', 'inherit'] });
let started = false;
const startRecord = () => {
  if (started) return;
  started = true;
  write({ t: now(), type: 'start', proxyPid: process.pid, serverPid: child.pid, real, args: serverArgs, cwd: process.cwd() });
};

// Requests in flight, by direction of the request: an id the editor sent is answered by the server.
const inFlight = { c2s: new Map(), s2c: new Map() };
const parsers = { c2s: framer('c2s'), s2c: framer('s2c') };

process.stdin.pipe(child.stdin);
child.stdout.pipe(process.stdout);
process.stdin.on('data', (chunk) => parsers.c2s(chunk));
child.stdout.on('data', (chunk) => parsers.s2c(chunk));
child.stdin.on('error', () => {});
process.stdout.on('error', () => {});

for (const name of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(name, () => {
    if (child.exitCode === null) child.kill(name);
  });
}
child.on('error', (error) => {
  process.stderr.write(`ide-compare-lsp-proxy: cannot start ${real}: ${error.message}\n`);
  process.exit(127);
});
child.on('close', (code, signal) => {
  if (started) write({ t: now(), type: 'exit', code, signal });
  flush();
  process.exit(code ?? 1);
});

// framer returns a function that takes the bytes of one direction and logs each complete message.
function framer(dir) {
  let buffer = Buffer.alloc(0);
  return (chunk) => {
    const t = now();
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    for (;;) {
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      const header = buffer.subarray(0, headerEnd).toString('latin1');
      const match = /content-length:\s*(\d+)/i.exec(header);
      if (!match) {
        // Not the Language Server Protocol: stop parsing this direction, keep forwarding.
        buffer = Buffer.alloc(0);
        return;
      }
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      if (buffer.length < bodyStart + length) return;
      const body = buffer.subarray(bodyStart, bodyStart + length);
      buffer = buffer.subarray(bodyStart + length);
      record(dir, t, body);
    }
  };
}

function record(dir, t, body) {
  startRecord();
  let message;
  try {
    message = JSON.parse(body.toString('utf8'));
  } catch {
    write({ t, dir, type: 'unparsed', bytes: body.length });
    return;
  }
  const entry = { t, dir, bytes: body.length };
  if (message.method !== undefined && message.id !== undefined) {
    entry.type = 'request';
    entry.id = message.id;
    entry.method = message.method;
    inFlight[dir].set(message.id, { t, method: message.method });
    if (FULL_BODY_METHODS.has(message.method)) entry.params = message.params;
  } else if (message.method !== undefined) {
    entry.type = 'notification';
    entry.method = message.method;
    if (FULL_BODY_METHODS.has(message.method)) entry.params = message.params;
  } else {
    entry.type = 'response';
    entry.id = message.id;
    const requestDir = dir === 'c2s' ? 's2c' : 'c2s';
    const request = inFlight[requestDir].get(message.id);
    if (request) {
      inFlight[requestDir].delete(message.id);
      entry.method = request.method;
      entry.ms = t - request.t;
      if (FULL_BODY_METHODS.has(request.method)) entry.result = message.result;
    }
    if (message.error) entry.error = { code: message.error.code, message: String(message.error.message).slice(0, 200) };
    else if (Array.isArray(message.result)) entry.items = message.result.length;
    else if (message.result === null) entry.items = 0;
  }
  write(entry);
}

function parseArgs(args) {
  const options = { real: null, logFile: null, serverArgs: [] };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--') {
      options.serverArgs = args.slice(i + 1);
      break;
    }
    if (args[i] === '--real') options.real = args[++i];
    else if (args[i] === '--log') options.logFile = args[++i];
    else throw new Error(`unknown argument ${args[i]}`);
  }
  if (!options.real || !options.logFile) throw new Error('usage: ide-compare-lsp-proxy.mjs --real SERVER --log FILE -- [arguments]');
  options.logFile = options.logFile.replace('%p', String(process.pid));
  return options;
}
