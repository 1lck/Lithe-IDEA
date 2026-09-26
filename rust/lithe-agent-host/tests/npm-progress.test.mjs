import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import test from 'node:test';

// Local HTTP only: prove byte accounting does not consume or modify npm's stream.
test('npm observer counts archive bytes and preserves Node options and response data', { timeout: 5000 }, async (t) => {
  const archive = Buffer.alloc(256 * 1024, 37);
  const server = http.createServer((request, response) => {
    if (request.url === '/redirect.tgz') {
      response.writeHead(302, { location: '/package.tgz' });
      response.end('not a package');
    } else if (request.url === '/package.tgz') {
      // Deliberately omit Content-Length; progress must not invent a total.
      response.writeHead(200);
      response.end(archive);
    } else response.end('registry metadata');
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const source = await readFile(new URL('../src/npm-progress.mjs', import.meta.url), 'utf8');
  const observer = `data:text/javascript,${encodeURIComponent(source)}`;
  const port = server.address().port;
  const script = `
    const http = require('node:http');
    async function download(path) {
      return await new Promise((resolve, reject) => {
        http.get('http://127.0.0.1:${port}' + path, response => {
          const body = [];
          response.on('data', data => body.push(data));
          response.on('end', () => resolve(Buffer.concat(body)));
          response.on('error', reject);
        }).on('error', reject);
      });
    }
    (async () => {
      await download('/metadata');
      await download('/redirect.tgz');
      const bytes = await download('/package.tgz');
      console.log(JSON.stringify({ length: bytes.length, valid: bytes.every(b => b === 37), options: process.env.NODE_OPTIONS }));
    })().catch(error => { console.error(error); process.exitCode = 1; });
  `;
  const { stdout, stderr } = await new Promise((resolve, reject) => {
    execFile(process.execPath, ['-e', script], {
      timeout: 4000, killSignal: 'SIGKILL', maxBuffer: 1024 * 1024,
      env: { ...process.env, NODE_OPTIONS: `--max-old-space-size=256 --import=${observer}`,
             LITHE_NPM_ORIGINAL_NODE_OPTIONS: '--max-old-space-size=256' },
    }, (error, stdout, stderr) => error ? reject(error) : resolve({ stdout, stderr }));
  });
  assert.deepEqual(JSON.parse(stdout), { length: archive.length, valid: true, options: '--max-old-space-size=256' });
  const events = stderr.split('\n').filter(line => line.startsWith('LITHE_NPM_PROGRESS '))
    .map(line => JSON.parse(line.slice('LITHE_NPM_PROGRESS '.length)));
  assert.ok(events.some(event => event.stage === 'downloading'));
  assert.equal(events.at(-1).downloadedBytes, archive.length);
  assert.equal(events.at(-1).stage, 'installing');
  assert.ok(events.every(event => !('totalBytes' in event) && !('url' in event)));
});
