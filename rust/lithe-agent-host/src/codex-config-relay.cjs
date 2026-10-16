#!/usr/bin/env node
'use strict';

// Preserve the complete native App Server. The ACP adapter replaces its
// custom provider table, so apply public retry options at thread creation.
const { spawn } = require('node:child_process');
const { Transform } = require('node:stream');
const { StringDecoder } = require('node:string_decoder');
const { request: httpRequest } = require('node:http');
const executable = process.env.LITHE_CODEX_EXECUTABLE;
const retries = Number(process.env.LITHE_CODEX_STREAM_RETRIES);
const nativeRecovery = process.env.LITHE_CODEX_NATIVE_RECOVERY !== '0';
const contextURL = process.env.LITHE_CODEX_CONTEXT_URL;
const observationBase = process.env.LITHE_CODEX_OBSERVATION_BASE;
if (!executable || !Number.isInteger(retries) || retries < 0 || retries > 100 || process.argv.slice(2).join(' ') !== 'app-server') {
  process.stderr.write('Codex retry configuration is unavailable.\n');
  process.exit(1);
}
const env = { ...process.env };
delete env.LITHE_CODEX_EXECUTABLE;
delete env.LITHE_CODEX_STREAM_RETRIES;
delete env.LITHE_CODEX_NATIVE_RECOVERY;
delete env.LITHE_CODEX_CONTEXT_URL;
delete env.LITHE_CODEX_OBSERVATION_BASE;
env.CODEX_PATH = executable;
const options = { env, stdio: ['pipe', 'pipe', 'inherit'] };
// Match upstream's Windows launcher support, including npm's codex.cmd.
const native = process.platform === 'win32'
  ? spawn(`"${executable}" app-server`, { ...options, shell: true })
  : spawn(executable, ['app-server'], options);
const turns = new Map();
let sequence = 0;
const pendingResumes = new Map();
const contextCaptures = new Map();
const MAX_CAPTURES = 32;
const pendingAccounts = new Map();
let unrestrictedAccount = false;
let observedThread = false;

// A custom inference origin is independent in native Codex's routing owner.
// Allow it only after native discovery confirms the ordinary unrestricted
// backend. Managed/resident/unknown accounts keep their original native route.
function configureObservation(message) {
  if (!observationBase) return;
  if (message.method === 'account/read') {
    unrestrictedAccount = false;
    pendingAccounts.clear();
    boundedSet(pendingAccounts, message.id, true);
  }
  if (!['thread/start', 'thread/resume', 'thread/fork'].includes(message.method)) return;
  const config = message.params?.config;
  if (!config || config.openai_base_url !== observationBase) return;
  if (!unrestrictedAccount) config.openai_base_url = '';
  else observedThread = true;
}

function observeAccount(message) {
  if (!observationBase) return;
  if (message.method === 'account/updated' || message.method === 'account/login/completed') {
    unrestrictedAccount = false;
    // Discovery begun before an identity/workspace change cannot authorize
    // the new route, even when the native account keeps the same email.
    pendingAccounts.clear();
    if (observedThread) native.kill();
  }
  if (!pendingAccounts.has(message.id)) return;
  pendingAccounts.delete(message.id);
  const result = message.result;
  unrestrictedAccount = !message.error && result?.account?.type === 'chatgpt'
    && result.workspaceRouting?.backendOrigin === 'https://chatgpt.com'
    && result.workspaceRouting?.accountRoutingOverride === 'NO_CONSTRAINT';
  if (!unrestrictedAccount && observedThread) native.kill();
}

// The Host arms a random ticket before its ACP load. This channel carries only
// actual native counters, never transcript content, provider URLs or secrets.
function contextExchange(action, payload) {
  if (!contextURL) return Promise.resolve(null);
  return new Promise(resolve => {
    try {
      // node:http connects directly to this launch's loopback listener; user
      // HTTP proxy settings and redirects must never route the capability out.
      const request = httpRequest(`${contextURL}/${action}`, { method: 'POST', agent: false, timeout: 1000 }, response => {
        let body = '';
        response.on('data', chunk => {
          body += chunk.toString();
          if (body.length > 4096) { response.destroy(); resolve(null); }
        });
        response.on('error', () => resolve(null));
        response.on('end', () => {
          try { resolve(response.statusCode === 200 ? JSON.parse(body) : null); }
          catch { resolve(null); }
        });
      });
      request.on('timeout', () => { request.destroy(); resolve(null); });
      request.on('error', () => resolve(null));
      request.end(JSON.stringify(payload));
    } catch { resolve(null); } // Optional observation cannot break native transport.
  });
}

function boundedSet(map, key, value) {
  map.delete(key);
  if (map.size >= MAX_CAPTURES) map.delete(map.keys().next().value);
  map.set(key, value);
}

function prepareContext(message) {
  if (message.method !== 'thread/resume' || !contextURL || typeof message.params?.threadId !== 'string') return message;
  return contextExchange('capture', { sessionId: message.params.threadId }).then(capture => {
    if (typeof capture?.ticket !== 'string' || capture.ticket.length > 64) return message;
    const item = { sessionId: message.params.threadId, ticket: capture.ticket };
    // Codex deliberately skips token-usage replay on the cheap excludeTurns
    // path for legacy histories. Reuse its full native restore to obtain it.
    message.params.excludeTurns = false;
    boundedSet(pendingResumes, message.id, item);
    contextCaptures.delete(item.sessionId);
    return message;
  });
}

function observeContext(message) {
  const pending = pendingResumes.get(message.id);
  if (pending) {
    pendingResumes.delete(message.id);
    if (!message.error && message.result?.thread?.id === pending.sessionId) {
      boundedSet(contextCaptures, pending.sessionId, pending);
    }
  }
  if (message.method === 'turn/started') contextCaptures.delete(message.params?.threadId);
  if (message.method !== 'thread/tokenUsage/updated') return message;
  const capture = contextCaptures.get(message.params?.threadId);
  const usage = message.params?.tokenUsage;
  const used = usage?.last?.totalTokens, size = usage?.modelContextWindow;
  if (capture && Number.isSafeInteger(used) && used >= 0 && Number.isSafeInteger(size) && size > 0) {
    contextCaptures.delete(capture.sessionId);
    void contextExchange('report', { ...capture, used, size });
  }
  return message;
}

function configure(message) {
  configureObservation(message);
  if (!nativeRecovery) return prepareContext(message);
  if (!['thread/start', 'thread/resume', 'thread/fork'].includes(message.method)) return message;
  const provider = message.params?.config?.model_providers?.['custom-gateway'];
  if (!provider || typeof provider !== 'object' || Array.isArray(provider)) return prepareContext(message);
  provider.request_max_retries = 0;
  provider.stream_max_retries = retries;
  // Remove competing dotted overrides before the native unordered override
  // map is applied. The selected gateway table owns this route and budget.
  for (const key of Object.keys(message.params.config)) {
    if (key === 'model_providers.custom-gateway' || key.startsWith('model_providers.custom-gateway.') || key === 'features.unbounded_connection_retries') delete message.params.config[key];
  }
  const features = message.params.config.features ??= {};
  features.unbounded_connection_retries = false;
  return prepareContext(message);
}

function preserveFailure(message) {
  observeAccount(message);
  observeContext(message);
  if (!nativeRecovery) return message;
  if (message.method === 'turn/started') turns.set(message.params.threadId, message.params.turn.id);
  if (message.method === 'turn/completed' && turns.get(message.params.threadId) === message.params.turn.id) turns.delete(message.params.threadId);
  if (message.method !== 'error' || !message.params?.error) return message;
  // AIR keeps a retry warning's message but drops codexErrorInfo and details.
  // Carry the original structured native failure through that string field;
  // only the Lithe host decodes this envelope, never assistant/model text.
  const error = message.params.error;
  error.message = JSON.stringify({ litheCodexFailure: {
    message: String(error.additionalDetails || error.message).slice(0, 4096),
    codexErrorInfo: error.codexErrorInfo ?? null,
    turnId: message.params.turnId,
    willRetry: message.params.willRetry,
    activeTurn: turns.get(message.params.threadId) === message.params.turnId,
    sequence: ++sequence,
  } });
  return message;
}

function jsonLines(map) {
  let pending = '';
  const decoder = new StringDecoder('utf8');
  return new Transform({
    transform(chunk, encoding, done) {
      pending += decoder.write(chunk);
      if (pending.length > 128 * 1024 * 1024) return done(new Error('Codex protocol message is too large'));
      const drain = () => { try {
        let end;
        while ((end = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, end);
          pending = pending.slice(end + 1);
          if (!line.trim()) { this.push('\n'); continue; }
          const mapped = map(JSON.parse(line));
          if (mapped && typeof mapped.then === 'function') {
            mapped.then(value => { this.push(JSON.stringify(value) + '\n'); drain(); }, () => done(new Error('Codex protocol mapping failed')));
            return;
          }
          this.push(JSON.stringify(mapped) + '\n');
        }
        done();
      } catch { done(new Error('Codex sent an invalid protocol message')); } };
      drain();
    },
    flush(done) {
      pending += decoder.end();
      if (pending.trim()) done(new Error('Codex sent an incomplete protocol message'));
      else done();
    },
  });
}
const input = jsonLines(configure);
const output = jsonLines(preserveFailure);
let stopped = false;
let transportFailed = false;
function stop() {
  if (stopped) return;
  stopped = true;
  input.destroy(); output.destroy(); native.stdin.destroy();
  native.kill();
  // The owning Rust host also terminates the complete process tree.
  const deadline = setTimeout(() => native.kill('SIGKILL'), 1000);
  deadline.unref();
}
for (const stream of [input, output, native.stdin, native.stdout, process.stdin, process.stdout]) stream.on('error', () => {
  transportFailed = true;
  process.exitCode = 1;
  process.stderr.write('Codex protocol transport failed.\n');
  stop();
});
native.on('error', () => { process.stderr.write('Could not start Codex.\n'); process.exitCode = 1; stop(); });
native.on('close', code => { process.exitCode = transportFailed ? 1 : code ?? 1; process.stdin.destroy(); input.destroy(); output.destroy(); });
process.on('SIGTERM', stop); process.on('SIGINT', stop);
process.stdin.on('end', stop);
process.stdin.pipe(input).pipe(native.stdin);
native.stdout.pipe(output).pipe(process.stdout);
