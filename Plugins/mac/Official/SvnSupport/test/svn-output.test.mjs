// Parses output recorded from svn 1.15 by record-fixtures.sh; edge cases svn
// does not produce in that scenario are written inline.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  changeOf,
  classifyFailure,
  committedRevision,
  conflictedPaths,
  isRevisionNumber,
  lacksBase,
  lacksHistory,
  notWorkingCopy,
  onlyAlreadyVersioned,
  parseBlame,
  parseInfo,
  parseLog,
  parseStatus,
  relativePath,
  statusChanges,
  svnCodes,
  svnEnvironment,
  target,
} from '../provider/svn-output.mjs';

const fixture = (name) => readFileSync(new URL(`fixtures/${name}`, import.meta.url), 'utf8');
const revision = (id) => ({ id, display: `r${id}`, kind: 'number' });
const change = (path, status, { oldPath = null, flags = [] } = {}) => ({ path, oldPath, status, flags });

test('svn runs with a UTF-8 character set and English messages, keeping the rest', () => {
  const environment = { PATH: '/usr/bin', HOME: '/home/u', LC_ALL: 'de_DE', LANGUAGE: 'de', LANG: 'de_DE.UTF-8' };
  assert.deepEqual(svnEnvironment(environment, 'darwin'), {
    PATH: '/usr/bin',
    HOME: '/home/u',
    LANG: 'de_DE.UTF-8',
    LC_CTYPE: 'UTF-8',
    LC_MESSAGES: 'C',
  });
  assert.equal(svnEnvironment(environment, 'linux').LC_CTYPE, 'C.UTF-8');
  assert.equal(environment.LC_ALL, 'de_DE', 'the given environment is not changed');
});

test('a target ends with @ so svn never reads part of the name as a peg revision', () => {
  assert.equal(target('a@b.txt'), 'a@b.txt@');
  assert.equal(target('src/main.c'), 'src/main.c@');
});

test('failures map to contract codes from the outermost svn code', () => {
  const kinds = {
    'update-locked.txt': 'workingCopyLocked',
    'commit-out-of-date.txt': 'outOfDate',
    'move-unversioned.txt': null,
    'cat-unversioned.txt': null,
  };
  for (const [name, kind] of Object.entries(kinds)) {
    assert.equal(classifyFailure(fixture(`errors/${name}`)).kind, kind, name);
  }
  for (const [stderr, kind] of [
    ["svn: E155036: The working copy at '/w' is too old (format 10) to work with client version '1.15.0'", 'workingCopyUnsupported'],
    ['svn: E170001: Authorization failed', 'authenticationFailed'],
    ['svn: E230001: Server SSL certificate verification failed: issuer is not trusted', 'authenticationFailed'],
    ['svn: E215004: No more credentials or we tried too many times.\nsvn: E170001: Authentication failed', 'authenticationFailed'],
    ["svn: E155015: Aborting commit: '/w/a.txt' remains in conflict", 'conflict'],
    ['svn: E170013: Unable to connect to a repository', null],
  ]) {
    assert.equal(classifyFailure(stderr).kind, kind, stderr);
  }
  assert.deepEqual(svnCodes(fixture('errors/cat-unversioned.txt')), ['W200005', 'E200009', 'E200009']);
  assert.match(classifyFailure('').message, /without an error message/);
  const long = `svn: E170013: ${'é'.repeat(3000)}`;
  assert.ok(Buffer.byteLength(classifyFailure(long).message) <= 4000);
});

test('a path without a base or history is told apart from a failure', () => {
  assert.ok(lacksBase(fixture('errors/cat-added.txt')));
  assert.ok(lacksBase(fixture('errors/cat-unversioned.txt')));
  assert.ok(lacksBase(fixture('errors/move-unversioned.txt')));
  assert.ok(!lacksBase(fixture('errors/update-locked.txt')));
  assert.ok(lacksHistory(fixture('errors/log-added.txt')));
  assert.ok(lacksHistory(fixture('errors/blame-added.txt')));
  assert.ok(!lacksHistory(fixture('errors/commit-out-of-date.txt')));
  assert.ok(onlyAlreadyVersioned(fixture('errors/add-versioned.txt')));
  assert.ok(!onlyAlreadyVersioned(fixture('errors/cat-unversioned.txt')));
  assert.ok(notWorkingCopy(fixture('errors/status-outside.txt')));
  assert.ok(!notWorkingCopy(''));
});

test('info names the working revision, URL, and repository path of the root', () => {
  assert.deepEqual(parseInfo(fixture('info.xml')), {
    revision: '12',
    url: 'file:///tmp/lab/repo/trunk',
    repositoryPath: '/trunk',
  });
  // svn before 1.8 printed no relative URL; the repository path is derived.
  assert.deepEqual(
    parseInfo(`<info><entry revision="3"><url>https://h/r/branches/my%20fix</url>
      <repository><root>https://h/r</root></repository></entry></info>`),
    { revision: '3', url: 'https://h/r/branches/my%20fix', repositoryPath: '/branches/my fix' },
  );
  assert.equal(
    parseInfo('<info><entry revision="1"><url>https://h/r</url><relative-url>^/</relative-url></entry></info>').repositoryPath,
    '/',
  );
  assert.throws(() => parseInfo('<info></info>'), /no entry/);
});

const RECORDED_CHANGES = [
  change('a@b.txt', 'modified'),
  change('added.txt', 'added'),
  change('copied.txt', 'copied'),
  change('copy-of-template.txt', 'deleted'),
  change('docs/readme.txt', 'conflicted', { flags: ['treeConflict'] }),
  change('lib', 'switched'),
  change('lost.txt', 'missing'),
  change('moved.txt', 'renamed', { oldPath: 'after.txt' }),
  change('replaced.txt', 'replaced'),
  change('src/main.c', 'modified'),
  change('src/util.c', 'conflicted'),
  change('src/util.c.mine', 'unversioned'),
  change('src/util.c.r10', 'unversioned'),
  change('src/util.c.r12', 'unversioned'),
  change('unversioned.txt', 'unversioned'),
  change('with space.txt', 'modified', { flags: ['propertiesModified'] }),
  change('ünïcödé.txt', 'modified'),
];

test('status maps every recorded working copy state to a contract change', () => {
  const entries = parseStatus(fixture('status.xml'), 'darwin');
  // The move source is reported by its destination; an unchanged locked file
  // and the external's own working copy are not changes of this root.
  assert.deepEqual(statusChanges(entries), RECORDED_CHANGES);
  assert.equal(entries.get('after.txt').movedTo, 'moved.txt');
  assert.equal(entries.get('locked.txt').locked, true);
  assert.equal(entries.get('vendor-docs').item, 'external');
  assert.deepEqual(conflictedPaths(entries), ['docs/readme.txt', 'src/util.c']);
});

test('status with ignored files adds them as ignored', () => {
  const changes = statusChanges(parseStatus(fixture('status-no-ignore.xml'), 'darwin'));
  assert.deepEqual(
    changes.filter((item) => item.status === 'ignored'),
    [change('build.log', 'ignored')],
  );
  assert.equal(changes.length, RECORDED_CHANGES.length + 1);
});

test('status leaves out the root itself and converts Windows separators', () => {
  const xml = `<status><target path=".">
    <entry path="."><wc-status item="normal" props="modified"/></entry>
    <entry path="src\\a.txt"><wc-status item="modified" props="modified" moved-from="old\\a.txt"><lock><owner>a</owner></lock></wc-status></entry>
    <entry path="src\\b.txt"><wc-status item="added" props="none" moved-from="old\\b.txt"/></entry>
    <entry path="incomplete"><wc-status item="incomplete" props="none"/></entry>
    <entry path="obstructed"><wc-status item="obstructed" props="none"/></entry>
    <entry path="merged.txt"><wc-status item="merged" props="none"/></entry>
    <entry path="props.txt"><wc-status item="normal" props="conflicted"/></entry>
  </target></status>`;
  assert.deepEqual(statusChanges(parseStatus(xml, 'win32')), [
    change('src/a.txt', 'modified', { flags: ['propertiesModified', 'locked'] }),
    change('src/b.txt', 'renamed', { oldPath: 'old/b.txt' }),
    change('obstructed', 'typeChanged'),
    change('merged.txt', 'modified'),
    change('props.txt', 'conflicted'),
  ]);
  assert.equal(relativePath('src\\a.txt', 'darwin'), 'src\\a.txt', 'a backslash is a name character on macOS');
  assert.equal(relativePath('.', 'darwin'), null);
});

test('an unknown svn item is not reported as a change', () => {
  assert.equal(changeOf('x', { item: 'future', props: 'none', locked: false, treeConflicted: false }), null);
});

test('root history maps repository paths to the root and recognizes a move', () => {
  const entries = parseLog(fixture('log-root.xml'), '/trunk');
  const byId = new Map(entries.map((entry) => [entry.revision.id, entry]));
  assert.deepEqual(
    entries.map((entry) => entry.revision.id),
    ['12', '11', '10', '8', '6', '5', '4', '3', '2', '1'],
  );
  assert.deepEqual(byId.get('4'), {
    revision: revision('4'),
    author: 'alice',
    date: byId.get('4').date,
    message: 'Rename, copy, and set a property',
    changes: [
      change('after.txt', 'renamed', { oldPath: 'before.txt' }),
      change('copy-of-template.txt', 'copied', { oldPath: 'template.txt' }),
      change('keep.txt', 'modified'),
    ],
    changesTruncated: false,
  });
  assert.match(byId.get('4').date, /^\d{4}-\d\d-\d\dT/);
  assert.deepEqual(byId.get('6').changes, [change('replaced.txt', 'replaced')]);
  assert.deepEqual(byId.get('5').changes, [change('gone.txt', 'deleted')]);
  assert.equal(byId.get('8').message, '', 'an empty message stays empty');
  assert.deepEqual(byId.get('10').changes, [], 'a property change of the root has no root-relative path');
  assert.equal(byId.get('2').message, 'Add sources\n\nSecond paragraph with <markup> & "quotes".');
  assert.ok(byId.get('2').changes.some((item) => item.path === 'a@b.txt' && item.status === 'added'));
});

test('file history follows the file through its rename', () => {
  const entries = parseLog(fixture('log-file.xml'), '/trunk');
  assert.deepEqual(
    entries.map((entry) => entry.revision.id),
    ['4', '2'],
  );
});

test('history leaves out paths outside the root and keeps outside copy sources unnamed', () => {
  const xml = `<log><logentry revision="9"><author>a</author>
    <paths>
      <path action="A" copyfrom-path="/branches/x/a.txt" copyfrom-rev="8">/trunk/a.txt</path>
      <path action="M">/branches/x/b.txt</path>
      <path action="M">/trunk-other/c.txt</path>
      <path action="A" copyfrom-path="/trunk/old" copyfrom-rev="8">/trunk/new</path>
      <path action="D">/trunk/old</path>
    </paths></logentry>
    <logentry revision="8"/></log>`;
  const [entry, bare] = parseLog(xml, '/trunk');
  assert.deepEqual(entry.changes, [change('a.txt', 'copied'), change('new', 'renamed', { oldPath: 'old' })]);
  assert.deepEqual(bare, {
    revision: revision('8'),
    author: null,
    date: null,
    message: '',
    changes: [],
    changesTruncated: false,
  });
  assert.deepEqual(
    parseLog(xml, '/')[0].changes.map((item) => item.path),
    ['trunk/a.txt', 'branches/x/b.txt', 'trunk-other/c.txt', 'trunk/new'],
  );
  assert.deepEqual(parseLog(xml, null)[0].changes, [], 'without a known root path no change is placed');
});

test('blame names a revision per line, null for local changes, and each revision once', () => {
  const { lines, revisions } = parseBlame(fixture('blame-local.xml'));
  assert.deepEqual(lines, ['2', '3', '2', '3', null]);
  assert.deepEqual([...revisions.keys()], ['2', '3']);
  assert.deepEqual(revisions.get('3'), {
    revision: revision('3'),
    author: 'bob',
    date: revisions.get('3').date,
    message: null,
  });
  assert.deepEqual(parseBlame(fixture('blame.xml')).lines, ['2', '8']);
  assert.throws(() => parseBlame('<blame/>'), /no target/);
});

test('commit output names the new revision; nothing committed names none', () => {
  assert.equal(committedRevision(fixture('commit.txt')), '14');
  assert.equal(committedRevision(''), null);
});

test('revision numbers are plain non-negative integers', () => {
  for (const value of ['0', '1', '1234567']) assert.ok(isRevisionNumber(value), value);
  for (const value of ['', '01', '-1', 'HEAD', '1:2', '1.5', 5, null, '12345678901234567']) {
    assert.ok(!isRevisionNumber(value), String(value));
  }
});
