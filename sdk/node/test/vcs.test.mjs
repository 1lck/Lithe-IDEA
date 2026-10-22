import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createBackend, isVcsId, PluginError, PluginSdkError, VCS_ERRORS } from '../src/index.mjs';
import { ERROR_CODES, VCS_OPERATIONS } from '../src/protocol.mjs';
import { TestHost } from './harness.mjs';

const model = JSON.parse(readFileSync(new URL('../../../shared/fixtures/vcs/model-v1.json', import.meta.url), 'utf8'));

const OFFER = { litheVcs: { versions: [1] } };
const ROOT = { path: '/workspace/legacy' };

/** The four operations every provider answers, echoing what they received. */
function required(overrides = {}) {
  return {
    status: () => ({ changes: [] }),
    baseContent: (params) => ({ content: `base of ${params.path}`, binary: false }),
    checkin: () => ({ revision: { id: '2' } }),
    rollback: () => {},
    ...overrides,
  };
}

test('every VCS operation negotiates a capability of the contract, and the IDs follow Core', () => {
  const svn = model.providers.find((provider) => provider.vcs === 'svn');
  // The fixture provider declares every operation-backed capability.
  assert.deepEqual(
    Object.values(VCS_OPERATIONS).map(({ capability }) => capability).sort(),
    Object.keys(svn.capabilities).sort(),
  );
  for (const id of ['svn', 'hg', 'p4-helix', 'a1']) assert.ok(isVcsId(id), id);
  for (const id of ['', 'SVN', '1svn', 'svn_x', 'é', 'a'.repeat(33)]) assert.ok(!isVcsId(id), id);
});

test('a provider declaration is checked when it is made', () => {
  const declare = (...args) => () => createBackend().vcs(...args);
  const code = (expected) => (error) => error instanceof PluginSdkError && error.code === expected;
  assert.throws(declare('SVN', required()), code('sdk.vcs.invalidID'));
  assert.throws(declare('git', required()), code('sdk.vcs.reserved'));
  assert.throws(declare('svn', required({ push: () => ({}) })), code('sdk.vcs.unknownOperation'));
  assert.throws(declare('svn', { status: () => ({}) }), code('sdk.vcs.missingOperation'));
  assert.throws(declare('svn', required(), { locks: true }), code('sdk.vcs.unknownTrait'));
  assert.throws(declare('svn', required({ history: 'not a function' })), TypeError);
  assert.throws(() => createBackend().vcs('svn', required()).vcs('hg', required()), code('sdk.vcs.duplicate'));
  assert.throws(
    () => createBackend({ capabilities: { experimental: { litheVcs: { version: 1 } } } }),
    code('sdk.capabilities.reserved'),
  );
  // lithe/vcs/* belongs to the typed handlers, never to onRequest.
  assert.throws(() => createBackend().onRequest('lithe/vcs/status', () => {}), code('sdk.method.reserved'));
});

test('initialize answers the VCS and the capabilities its handlers and traits imply', async () => {
  const backend = createBackend().vcs(
    'svn',
    required({ fileOperation: () => {}, resolve: () => {}, history: () => ({ entries: [], nextCursor: null }) }),
    { push: false, staging: false },
  );
  const host = new TestHost(backend);
  const { result } = await host.initialize(OFFER);
  assert.deepEqual(result.capabilities.experimental.litheVcs, {
    version: 1,
    vcs: 'svn',
    capabilities: { baseContent: 1, checkin: 1, conflicts: 1, fileOperations: 1, history: 1, rollback: 1, status: 1 },
  });
  assert.deepEqual(backend.negotiated, { functions: false, build: false, vcs: true });
  await host.close();

  const distributed = new TestHost(createBackend().vcs('hg', required(), { push: true }));
  // Traits are capabilities without an operation; a false trait is not claimed.
  const answer = (await distributed.initialize(OFFER)).result.capabilities.experimental.litheVcs;
  assert.deepEqual(answer.capabilities, { baseContent: 1, checkin: 1, push: 1, rollback: 1, status: 1 });
  await distributed.close();
});

test('a host that does not offer litheVcs gets no provider and no VCS answers', async () => {
  const backend = createBackend().vcs('svn', required());
  const host = new TestHost(backend);
  const { result } = await host.initialize({ litheVcs: { versions: [2] } });
  assert.deepEqual(result.capabilities.experimental, {});
  assert.equal(backend.negotiated.vcs, false);
  const refused = await host.request('lithe/vcs/status', { root: ROOT, tool: null });
  assert.equal(refused.error.code, ERROR_CODES.methodNotFound);
  await host.close();
});

test('handlers receive the planned params and answer with the reply object', async () => {
  const received = [];
  const backend = createBackend().vcs(
    'svn',
    required({
      status: (params) => {
        received.push(params);
        return { changes: [{ path: 'a.txt', status: 'modified' }] };
      },
      cleanup: () => undefined,
      update: () => 'not an object',
    }),
  );
  const host = new TestHost(backend);
  await host.initialize(OFFER);
  const params = { includeIgnored: false, root: ROOT, tool: { executable: '/usr/bin/svn' } };
  const status = await host.request('lithe/vcs/status', params);
  assert.deepEqual(status.result, { changes: [{ path: 'a.txt', status: 'modified' }] });
  assert.deepEqual(received, [params]);
  // A handler that returns nothing answers the empty reply of rollback-like operations.
  assert.deepEqual((await host.request('lithe/vcs/cleanup', { root: ROOT, tool: null })).result, {});
  // A reply that is not an object is a backend bug, reported without internals.
  const invalid = await host.request('lithe/vcs/update', { root: ROOT, tool: null });
  assert.equal(invalid.error.code, ERROR_CODES.internalError);
  // An operation the backend did not declare is not one of its capabilities.
  assert.equal((await host.request('lithe/vcs/annotate', { root: ROOT })).error.code, ERROR_CODES.methodNotFound);
  await host.close();
});

test('provider failures carry the contract code Core passes on', async () => {
  const backend = createBackend().vcs(
    'svn',
    required({
      checkin: () => {
        throw new PluginError(VCS_ERRORS.outOfDate, 'Update the working copy before committing.');
      },
    }),
  );
  const host = new TestHost(backend);
  await host.initialize(OFFER);
  const failed = await host.request('lithe/vcs/checkin', { paths: ['a.txt'], message: 'Fix', root: ROOT, tool: null });
  assert.deepEqual(failed.error, {
    code: ERROR_CODES.requestFailed,
    message: 'Update the working copy before committing.',
    data: { code: 'vcs.outOfDate' },
  });
  await host.close();
});

test('commands a handler runs are reported to the host unless it opts out', async () => {
  const script = "process.stderr.write('warning: x'); process.exit(3)";
  const backend = createBackend().vcs(
    'svn',
    required({
      status: async (params, context) => {
        const reported = await context.run(process.execPath, ['-e', script]);
        await context.run(process.execPath, ['-e', 'process.exit(0)'], { report: false });
        return { changes: [], exitCode: reported.exitCode };
      },
    }),
  );
  const host = new TestHost(backend);
  await host.initialize(OFFER);
  const status = await host.request('lithe/vcs/status', { root: ROOT, tool: null });
  assert.equal(status.result.exitCode, 3);
  const executions = host.messages.filter((message) => message.method === 'lithe/vcs/execution');
  assert.equal(executions.length, 1);
  const [{ params }] = executions;
  assert.deepEqual(params.command, [process.execPath, '-e', script]);
  assert.equal(params.exitCode, 3);
  assert.equal(params.stderr, 'warning: x');
  assert.ok(Number.isInteger(params.durationMilliseconds) && params.durationMilliseconds >= 0);
  // The report precedes the response that used its result.
  assert.ok(host.messages.indexOf(executions[0]) < host.messages.indexOf(status));
  await host.close();
});
