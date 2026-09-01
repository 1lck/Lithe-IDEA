import test from 'node:test';
import assert from 'node:assert/strict';
import {
  claimMarker, claimStatus, hasProgressSince, isActiveClaim, isMaintainer, isPullRequestIssue, latestProgressDate, parseCommand, parseMarker, releaseMarker, releaseMatchesClaim,
} from '../.github/lithe-issue-claim/logic.mjs';

const now = new Date('2026-09-01T00:00:00Z');

test('only exact claim commands are accepted', () => {
  assert.equal(parseCommand('/assign'), '/assign');
  assert.equal(parseCommand(' /unassign\n'), '/unassign');
  assert.equal(parseCommand('/assign please'), null);
  assert.equal(parseCommand('progress update'), null);
});

test('pull requests are excluded and maintainer associations are explicit', () => {
  assert.equal(isPullRequestIssue({ pull_request: { url: 'x' } }), true);
  assert.equal(isPullRequestIssue({}), false);
  assert.equal(isMaintainer('OWNER'), true);
  assert.equal(isMaintainer('MEMBER'), true);
  assert.equal(isMaintainer('CONTRIBUTOR'), false);
});

test('claim lifecycle warns after 30 days and releases after seven more', () => {
  const claim = parseMarker(claimMarker('alice', '2026-08-01T00:00:00Z'), '<!-- lithe-claim:');
  assert.deepEqual(claim, { login: 'alice', isoDate: '2026-08-01T00:00:00Z' });
  assert.equal(claimStatus(claim, null, now), 'warn');
  const warning = { login: 'alice', isoDate: '2026-08-25T00:00:00Z' };
  assert.equal(claimStatus(claim, warning, now), 'release');
});

test('a substantive assignee comment resets the inactivity window', () => {
  assert.equal(hasProgressSince([
    { user: { login: 'alice' }, created_at: '2026-08-20T00:00:00Z', body: 'PR is in progress' },
  ], 'alice', '2026-08-01T00:00:00Z'), true);
  assert.equal(hasProgressSince([
    { user: { login: 'alice' }, created_at: '2026-08-20T00:00:00Z', body: '/assign' },
  ], 'alice', '2026-08-01T00:00:00Z'), false);
  assert.equal(latestProgressDate([
    { user: { login: 'alice' }, created_at: '2026-08-20T00:00:00Z', body: 'first update' },
    { user: { login: 'alice' }, created_at: '2026-08-25T00:00:00Z', body: 'latest update' },
  ], 'alice', '2026-08-01T00:00:00Z'), '2026-08-25T00:00:00Z');
});

test('a release tombstone allows a later claimant to take over', () => {
  const claim = parseMarker(claimMarker('alice', '2026-08-01T00:00:00Z'), '<!-- lithe-claim:');
  const release = parseMarker(releaseMarker('alice', '2026-08-10T00:00:00Z'), '<!-- lithe-claim-release:');
  assert.equal(isActiveClaim(claim, release), false);
  assert.equal(isActiveClaim(claim, { login: 'bob', isoDate: '2026-08-10T00:00:00Z' }), true);
  assert.equal(isActiveClaim(claim, null), true);
  const bobClaim = parseMarker(claimMarker('bob', '2026-08-20T00:00:00Z'), '<!-- lithe-claim:');
  const aliceRelease = parseMarker(releaseMarker('alice', '2026-08-25T00:00:00Z'), '<!-- lithe-claim-release:');
  assert.equal(releaseMatchesClaim(aliceRelease, bobClaim), false);
  assert.equal(isActiveClaim(bobClaim, aliceRelease), true);
  const bobRelease = parseMarker(releaseMarker('bob', '2026-08-28T00:00:00Z'), '<!-- lithe-claim-release:');
  assert.equal(releaseMatchesClaim(bobRelease, bobClaim), true);
  assert.equal(isActiveClaim(bobClaim, bobRelease), false);
});
