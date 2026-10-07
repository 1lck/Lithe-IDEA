#!/usr/bin/env node
'use strict';

// Preserve the complete native App Server. The ACP adapter replaces its
// custom provider table, so apply public retry options at thread creation.
const { spawn } = require('node:child_process');
const { Transform } = require('node:stream');
const { StringDecoder } = require('node:string_decoder');
const executable = process.env.LITHE_CODEX_EXECUTABLE;
const retries = Number(process.env.LITHE_CODEX_STREAM_RETRIES);
if (!executable || !Number.isInteger(retries) || retries < 0 || retries > 100 || process.argv.slice(2).join(' ') !== 'app-server') {
  process.stderr.write('Codex retry configuration is unavailable.\n');
  process.exit(1);
}
const env = { ...process.env };
delete env.LITHE_CODEX_EXECUTABLE;
delete env.LITHE_CODEX_STREAM_RETRIES;
env.CODEX_PATH = executable;
const options = { env, stdio: ['pipe', 'pipe', 'inherit'] };
// Match upstream's Windows launcher support, including npm's codex.cmd.
const native = process.platform === 'win32'
  ? spawn(`"${executable}" app-server`, { ...options, shell: true })
  : spawn(executable, ['app-server'], options);
const turns = new Map();
let sequence = 0;

function configure(message) {
  if (!['thread/start', 'thread/resume', 'thread/fork'].includes(message.method)) return message;
  const provider = message.params?.config?.model_providers?.['custom-gateway'];
  if (!provider || typeof provider !== 'object' || Array.isArray(provider)) return message;
  provider.request_max_retries = 0;
  provider.stream_max_retries = retries;
  // Remove competing dotted overrides before the native unordered override
  // map is applied. The selected gateway table owns this route and budget.
  for (const key of Object.keys(message.params.config)) {
    if (key === 'model_providers.custom-gateway' || key.startsWith('model_providers.custom-gateway.') || key === 'features.unbounded_connection_retries') delete message.params.config[key];
  }
  const features = message.params.config.features ??= {};
  features.unbounded_connection_retries = false;
  return message;
}

function preserveFailure(message) {
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
      let end;
      try {
        while ((end = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, end);
          pending = pending.slice(end + 1);
          this.push(line.trim() ? JSON.stringify(map(JSON.parse(line))) + '\n' : '\n');
        }
        done();
      } catch { done(new Error('Codex sent an invalid protocol message')); }
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
