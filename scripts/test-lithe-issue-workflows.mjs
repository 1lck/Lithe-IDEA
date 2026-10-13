import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const workflowSource = (name) => readFileSync(new URL(`../.github/workflows/${name}.yml`, import.meta.url), 'utf8');
const gateSource = workflowSource('lithe-issue-form-gate');
const prioritySource = workflowSource('lithe-issue-priority');
const logicUrl = new URL('../.github/lithe-issue-form/logic.mjs', import.meta.url).href;

// Execute the actual checked-in github-script body with deterministic API doubles.
// Pass a local process double so tests do not mutate shared environment variables.
async function run(source, fixture) {
  const marker = '          script: |\n';
  assert.equal(source.split(marker).length, 2);
  const body = source.split(marker)[1].split('\n').map((line) => line.slice(12)).join('\n');
  await new AsyncFunction('github', 'context', 'core', 'process', body)(
    fixture.github, fixture.context, { info() {}, warning() {} },
    { env: { ISSUE_FORM_LOGIC: logicUrl } },
  );
}

function fixture({ archived = false, permission = 'read', onRead = () => {}, sender = 'alice' } = {}) {
  const issue = { number: 1, state: 'open', user: { login: 'alice', type: 'User' }, labels: [], title: '[Bug] example', body: '### Priority / 优先级\nP1' };
  const context = { repo: { owner: 'example', repo: 'test' }, issue: { number: 1 }, payload: { issue: structuredClone(issue), sender: { login: sender } }, serverUrl: 'https://github.com' };
  const comments = [];
  const removals = [];
  let reads = 0;
  const github = {
    rest: {
      issues: {
        get: async () => {
          const snapshot = structuredClone(issue);
          onRead(issue, ++reads);
          return { data: snapshot };
        },
        getLabel: async () => ({ data: { archived_at: archived ? '2026-01-01T00:00:00Z' : null } }),
        addLabels: async ({ labels }) => {
          for (const name of labels) if (!issue.labels.some((label) => label.name === name)) issue.labels.push({ name });
        },
        removeLabel: async ({ name }) => {
          removals.push(name);
          issue.labels = issue.labels.filter((label) => label.name !== name);
        },
        listComments: async () => ({ data: comments }),
        createComment: async ({ body }) => comments.push({ user: { login: 'github-actions[bot]', type: 'Bot' }, body }),
        update: async ({ state, state_reason }) => Object.assign(issue, { state, state_reason }),
      },
      repos: { getCollaboratorPermissionLevel: async () => ({ data: { permission, role_name: permission } }) },
    },
    paginate: async (method, args) => (await method(args)).data,
  };
  return { issue, context, github, comments, removals };
}

test('author close then reopen is checked again, without duplicating comments', async () => {
  assert.match(gateSource, /types: \[opened, reopened\]/);
  const f = fixture();
  f.issue.state = 'closed';
  await run(gateSource, f);
  assert.equal(f.comments.length, 0);
  f.context.payload.action = 'reopened';
  f.issue.state = 'open';
  await run(gateSource, f);
  assert.equal(f.issue.state, 'closed');
  assert.equal(f.issue.state_reason, 'not_planned');
  assert.equal(f.comments.length, 1);
  f.issue.state = 'open';
  await run(gateSource, f);
  assert.equal(f.issue.state, 'closed');
  assert.equal(f.comments.length, 1);
});

test('another actor reopening an external issue is respected', async () => {
  const f = fixture({ sender: 'maintainer' });
  f.context.payload.action = 'reopened';
  await run(gateSource, f);
  assert.equal(f.issue.state, 'open');
  assert.equal(f.comments.length, 0);
});

test('archived form labels disable closing even when getLabel succeeds', async () => {
  const f = fixture({ archived: true });
  await run(gateSource, f);
  assert.equal(f.issue.state, 'open');
  assert.equal(f.comments.length, 0);
});

test('priority synchronization preserves form labels applied after its read', async () => {
  // opened payload and priority snapshot have no form label. GitHub applies it
  // before priority writes; gate starts only after priority has finished.
  const f = fixture({ onRead(issue, count) {
    if (count === 1) issue.labels.push({ name: 'issue-form:bug' });
  } });
  f.issue.labels.push({ name: 'P2' }, { name: 'claimed' });
  await run(prioritySource, f);
  assert.deepEqual(f.removals, ['P2']);
  assert.deepEqual(f.issue.labels.map((label) => label.name).sort(), ['P1', 'bug', 'claimed', 'issue-form:bug']);
  await run(gateSource, f);
  assert.equal(f.issue.state, 'open');
  assert.equal(f.comments.length, 0);
});

test('a form label appearing between gate reads prevents closing', async () => {
  const f = fixture({ onRead(issue, count) {
    if (count === 1) issue.labels.push({ name: 'issue-form:feature' });
  } });
  await run(gateSource, f);
  assert.equal(f.issue.state, 'open');
  assert.equal(f.comments.length, 0);
});

test('permission lookup failure leaves the issue open', async () => {
  const f = fixture();
  f.github.rest.repos.getCollaboratorPermissionLevel = async () => { throw new Error('unavailable'); };
  await run(gateSource, f);
  assert.equal(f.issue.state, 'open');
  assert.equal(f.comments.length, 0);
});

test('maintainer authors can still submit without form labels', async () => {
  for (const permission of ['write', 'maintain', 'admin']) {
    const f = fixture({ permission });
    await run(gateSource, f);
    assert.equal(f.issue.state, 'open');
    assert.equal(f.comments.length, 0);
  }
});
