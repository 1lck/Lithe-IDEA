import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  ALLOWED_LABELS, GATE_MARKER, ISSUE_FORMS, decideIssueFormGate, gateComment, hasGateComment, isMaintainerPermission, labelNames, missingAllowedLabels,
} from '../.github/lithe-issue-form/logic.mjs';

const readPermission = { permission: 'read', role_name: 'read' };
const issueBy = (login, overrides = {}) => ({
  number: 1, state: 'open', user: { login, type: 'User' }, labels: [], body: '', ...overrides,
});
const decide = (issue, authorPermission, extra = {}) =>
  decideIssueFormGate({ issue, sender: { login: issue.user.login }, authorPermission, ...extra });

test('every issue form declares its gate label', () => {
  for (const form of ISSUE_FORMS) {
    const source = readFileSync(new URL(`../.github/ISSUE_TEMPLATE/${form.template}`, import.meta.url), 'utf8');
    assert.match(source, new RegExp(`^\\s*-\\s*${form.label}\\s*$`, 'm'), `${form.template} must list ${form.label}`);
  }
});

test('non-maintainer issues from the bug and feature forms stay open', () => {
  assert.deepEqual(decide(issueBy('alice', { labels: [{ name: 'bug' }, { name: 'issue-form:bug' }] }), readPermission), { action: 'allow', reason: 'issue-form' });
  assert.deepEqual(decide(issueBy('alice', { labels: [{ name: 'enhancement' }, { name: 'issue-form:feature' }] }), readPermission), { action: 'allow', reason: 'issue-form' });
});

test('a blank non-maintainer issue is closed', () => {
  assert.deepEqual(decide(issueBy('alice', { body: null }), readPermission), { action: 'close', reason: 'not-from-issue-form' });
});

test('an API or CLI issue with a non-empty body but no form label is closed', () => {
  const issue = issueBy('alice', { title: '[Bug] crash', body: 'please support this', labels: [{ name: 'bug' }] });
  assert.deepEqual(decide(issue, readPermission), { action: 'close', reason: 'not-from-issue-form' });
});

test('regression #988: an outside user with an empty body is closed', () => {
  const issue = issueBy('outside-user', { title: '能否做一个热更新的功能', body: null, labels: [{ name: 'review: low' }] });
  assert.equal(decide(issue, { permission: 'none', role_name: 'none' }).action, 'close');
});

test('write, maintain, and admin authors may open blank issues', () => {
  for (const level of ['write', 'maintain', 'admin']) {
    assert.deepEqual(decide(issueBy('maintainer'), { permission: level, role_name: level }), { action: 'allow', reason: 'maintainer' });
  }
  // Custom roles keep their base level in the legacy permission field.
  assert.equal(decide(issueBy('custom'), { permission: 'write', role_name: 'release-manager' }).action, 'allow');
  assert.equal(isMaintainerPermission({ permission: 'read', role_name: 'triage' }), false);
  assert.equal(isMaintainerPermission(null), false);
});

test('uncertain inputs never close an issue', () => {
  assert.deepEqual(decide(issueBy('alice'), null), { action: 'skip', reason: 'permission-unknown' });
  assert.deepEqual(decide(issueBy('alice'), readPermission, { missingLabels: ['issue-form:bug'] }), { action: 'skip', reason: 'form-labels-missing' });
  assert.equal(decide(issueBy('alice', { state: 'closed' }), readPermission).action, 'skip');
  assert.equal(decide(issueBy('alice', { pull_request: { url: 'x' } }), readPermission).action, 'skip');
  assert.equal(decideIssueFormGate({ issue: issueBy('alice'), sender: { login: 'maintainer' }, authorPermission: readPermission }).reason, 'opened-by-another-actor');
  assert.equal(decideIssueFormGate({ issue: null }).action, 'skip');
});

test('bot authors are allowed', () => {
  assert.equal(decide(issueBy('dependabot[bot]', { user: { login: 'dependabot[bot]', type: 'Bot' } }), readPermission).action, 'allow');
});

test('label helpers accept string and object labels', () => {
  assert.deepEqual(labelNames(['bug', { name: 'issue-form:bug' }, {}, null]), ['bug', 'issue-form:bug']);
  assert.deepEqual(missingAllowedLabels(['issue-form:bug']), ['issue-form:feature']);
  assert.deepEqual(missingAllowedLabels(ALLOWED_LABELS), []);
});

test('the gate comment is bilingual, links every form, and never echoes issue text', () => {
  const body = gateComment({ login: 'alice', serverUrl: 'https://github.com', owner: '1lck', repo: 'Lithe-IDEA' });
  assert.ok(body.startsWith(GATE_MARKER));
  assert.match(body, /@alice/);
  assert.match(body, /Issue 表单/);
  assert.match(body, /issue forms/);
  assert.ok(body.includes('https://github.com/1lck/Lithe-IDEA/issues/new?template=bug_report.yml'));
  assert.ok(body.includes('https://github.com/1lck/Lithe-IDEA/issues/new?template=feature_request.yml'));
  assert.ok(body.includes('https://github.com/1lck/Lithe-IDEA/issues/new/choose'));
});

test('only the workflow bot comment counts as an existing gate comment', () => {
  assert.equal(hasGateComment([{ user: { login: 'alice', type: 'User' }, body: GATE_MARKER }]), false);
  assert.equal(hasGateComment([{ user: { login: 'github-actions[bot]', type: 'Bot' }, body: `${GATE_MARKER}\nclosed` }]), true);
  assert.equal(hasGateComment([]), false);
});
