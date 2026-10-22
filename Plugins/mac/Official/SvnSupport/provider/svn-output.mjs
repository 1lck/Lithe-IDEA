// What the Subversion provider knows about the `svn` client, without running
// it: the environment it needs, how a path is passed, how its errors map to
// the contract's codes, and how its `--xml` output becomes contract replies.
// Everything here is pure so it is tested against recorded output
// (test/fixtures/) on machines without svn.

import { parseXml } from './xml.mjs';

/**
 * The environment every svn command runs with. svn converts paths from the
 * locale's character set, and an app started from the Dock has no UTF-8
 * locale, so non-ASCII paths would fail; messages are English so the
 * commit output can be read. Everything else is the user's environment,
 * including where svn keeps its configuration and credential cache.
 *
 * @param {NodeJS.ProcessEnv} [environment]
 * @param {NodeJS.Platform} [platform]
 */
export function svnEnvironment(environment = process.env, platform = process.platform) {
  const result = { ...environment };
  delete result.LC_ALL;
  delete result.LANGUAGE;
  result.LC_MESSAGES = 'C';
  result.LC_CTYPE = platform === 'darwin' ? 'UTF-8' : 'C.UTF-8';
  return result;
}

/**
 * A working-copy path as an svn target. svn reads the text after the last
 * `@` as a peg revision, so a trailing `@` keeps `a@b.txt` a file name. A
 * move or copy destination is not a target and is passed as it is.
 */
export function target(path) {
  return `${path}@`;
}

/** Error and warning codes (`E155004`, `W150002`) svn printed, in order. */
export function svnCodes(stderr) {
  return [...stderr.matchAll(/^svn: (?:warning: )?([EW]\d{6}):/gm)].map((match) => match[1]);
}

/**
 * svn errors with a contract code, keyed by `VCS_ERRORS` names. The first
 * listed code svn printed decides, so the outermost cause wins over the
 * wrapper errors around it.
 */
const CONTRACT_ERRORS = new Map([
  // Working copy locked; previous operation not finished.
  ['E155004', 'workingCopyLocked'],
  ['E155037', 'workingCopyLocked'],
  // Format too old for this client; client too old for this format.
  ['E155036', 'workingCopyUnsupported'],
  ['E155021', 'workingCopyUnsupported'],
  // Out of date in the working copy, the repository, or the RA layer;
  // a conflict found while the server merged the commit.
  ['E155011', 'outOfDate'],
  ['E160028', 'outOfDate'],
  ['E160024', 'outOfDate'],
  ['E170004', 'outOfDate'],
  // A conflicted path is part of the operation.
  ['E155015', 'conflict'],
  // Authorization failed; no credentials left to try; certificate not trusted.
  ['E170001', 'authenticationFailed'],
  ['E215004', 'authenticationFailed'],
  ['E230001', 'authenticationFailed'],
]);

/**
 * The contract error of a failed svn command: a `VCS_ERRORS` name, or
 * `null` for a failure the host shows as a generic provider error, and the
 * message to show.
 *
 * @param {string} stderr
 * @returns {{ kind: string | null, message: string }}
 */
export function classifyFailure(stderr) {
  const codes = svnCodes(stderr);
  const kind = codes.map((code) => CONTRACT_ERRORS.get(code)).find(Boolean) ?? null;
  const message = stderr.trim() || 'svn failed without an error message.';
  return { kind, message: truncate(message, 4000) };
}

function truncate(text, bytes) {
  const encoded = Buffer.from(text, 'utf8');
  return encoded.length <= bytes ? text : `${encoded.subarray(0, bytes - 3).toString('utf8').replace(/�$/, '')}...`;
}

/** Whether svn said the path has no base to read: unversioned, added, or replaced. */
export function lacksBase(stderr) {
  const codes = new Set(svnCodes(stderr));
  return (
    codes.has('W200005') ||
    codes.has('W155010') ||
    codes.has('E155010') ||
    codes.has('E195002') ||
    /has no pristine version/.test(stderr)
  );
}

/** Whether svn said the path has no committed history yet (log, blame). */
export function lacksHistory(stderr) {
  const codes = new Set(svnCodes(stderr));
  return codes.has('E195002') || codes.has('W155010') || codes.has('E155010');
}

/**
 * Whether `svn add` only skipped targets that were already versioned, which
 * still makes it exit with an error after adding the others.
 */
export function onlyAlreadyVersioned(stderr) {
  const codes = svnCodes(stderr);
  return codes.includes('W150002') && codes.every((code) => code === 'W150002' || code === 'E200009');
}

/** svn prints `W155007` and exits 0 when the root is not a working copy. */
export function notWorkingCopy(stderr) {
  return svnCodes(stderr).includes('W155007');
}

/** A revision ID as the contract presents it. */
export function revisionOf(id) {
  return id === null || id === undefined ? null : { id: String(id), display: `r${id}`, kind: 'number' };
}

/** Whether `value` is a revision number svn accepts. */
export function isRevisionNumber(value) {
  return typeof value === 'string' && /^(0|[1-9]\d{0,15})$/.test(value);
}

/**
 * A path svn printed, as a root-relative contract path. svn prints local
 * style, so Windows separators become `/`; the root itself is `null`.
 */
export function relativePath(path, platform = process.platform) {
  const portable = platform === 'win32' ? path.replaceAll('\\', '/') : path;
  return portable === '.' || portable === '' ? null : portable.replace(/^\.\//, '');
}

/**
 * `svn info --xml` of a root: its working revision, URL, and the
 * repository path history entries are relative to.
 */
export function parseInfo(xml) {
  const entry = parseXml(xml).child('entry');
  if (!entry) throw new Error('svn info printed no entry.');
  const url = entry.textOf('url');
  const repositoryRoot = entry.child('repository')?.textOf('root') ?? null;
  const relativeUrl = entry.textOf('relative-url');
  let repositoryPath = null;
  if (relativeUrl?.startsWith('^/')) repositoryPath = decodeURIComponent(relativeUrl.slice(1));
  else if (url && repositoryRoot && url.startsWith(repositoryRoot)) {
    repositoryPath = decodeURIComponent(url.slice(repositoryRoot.length)) || '/';
  }
  const revision = entry.attributes.revision;
  return {
    revision: isRevisionNumber(revision) ? revision : null,
    url,
    repositoryPath,
  };
}

/**
 * Every entry of `svn status --xml`, by root-relative path, with what the
 * operations need beyond the reply: the svn item and both ends of a move.
 *
 * @returns {Map<string, { item: string, props: string, movedFrom: string | null, movedTo: string | null, copied: boolean, switched: boolean, treeConflicted: boolean, locked: boolean }>}
 */
export function parseStatus(xml, platform = process.platform) {
  const entries = new Map();
  for (const targetElement of parseXml(xml).all('target')) {
    for (const entry of targetElement.all('entry')) {
      const path = relativePath(entry.attributes.path ?? '', platform);
      const status = entry.child('wc-status');
      // The root itself has no contract path; its property changes are not
      // reported in version 1.
      if (path === null || !status) continue;
      const attributes = status.attributes;
      entries.set(path, {
        item: attributes.item ?? 'none',
        props: attributes.props ?? 'none',
        movedFrom: attributes['moved-from'] ? relativePath(attributes['moved-from'], platform) : null,
        movedTo: attributes['moved-to'] ? relativePath(attributes['moved-to'], platform) : null,
        copied: attributes.copied === 'true',
        switched: attributes.switched === 'true',
        treeConflicted: attributes['tree-conflicted'] === 'true',
        locked: status.child('lock') !== null,
      });
    }
  }
  return entries;
}

/** Whether an entry is in a text, property, or tree conflict. */
export function isConflicted(entry) {
  return entry.item === 'conflicted' || entry.props === 'conflicted' || entry.treeConflicted;
}

/**
 * The contract change of one status entry, or `null` for an entry that is
 * not a change: unmodified, an externals definition (its working copy is
 * a root of its own), or incomplete after an interrupted update.
 */
export function changeOf(path, entry) {
  const flags = [];
  if (entry.props === 'modified') flags.push('propertiesModified');
  if (entry.locked) flags.push('locked');
  if (entry.treeConflicted) flags.push('treeConflict');
  const change = (status, oldPath = null) => ({ path, oldPath, status, flags });
  if (isConflicted(entry)) return change('conflicted');
  switch (entry.item) {
    case 'modified':
    case 'merged':
      return change('modified');
    case 'added':
      if (entry.movedFrom) return change('renamed', entry.movedFrom);
      return change(entry.copied ? 'copied' : 'added');
    case 'deleted':
      // The source of a move is reported by its destination, as a rename.
      return entry.movedTo ? null : change('deleted');
    case 'replaced':
      return change('replaced');
    case 'missing':
      return change('missing');
    case 'obstructed':
      return change('typeChanged');
    case 'unversioned':
      return change('unversioned');
    case 'ignored':
      return change('ignored');
    case 'normal':
    case 'none':
      if (entry.switched) return change('switched');
      if (entry.props === 'modified') return change('modified');
      return null;
    default:
      return null;
  }
}

/** The changes of a status snapshot, in svn's order; Core sorts them. */
export function statusChanges(entries) {
  return [...entries].map(([path, entry]) => changeOf(path, entry)).filter(Boolean);
}

/** Paths a status snapshot reports as conflicted, for an update reply. */
export function conflictedPaths(entries) {
  return [...entries].filter(([, entry]) => isConflicted(entry)).map(([path]) => path);
}

/** A repository path (`/trunk/src/a.txt`) relative to the root's repository path. */
function underRoot(repositoryPath, rootPath) {
  if (rootPath === null) return null;
  if (rootPath === '/') return repositoryPath.length > 1 ? repositoryPath.slice(1) : null;
  return repositoryPath.startsWith(`${rootPath}/`) ? repositoryPath.slice(rootPath.length + 1) : null;
}

const LOG_ACTIONS = { A: 'added', D: 'deleted', M: 'modified', R: 'replaced' };

/**
 * The changes of one revision inside the root. A path copied from a path
 * the same revision deleted is a rename; paths outside the root are left
 * out, since the contract only has root-relative paths.
 */
function logChanges(pathElements, rootPath) {
  const items = pathElements.map((element) => ({
    path: element.text,
    action: element.attributes.action,
    from: element.attributes['copyfrom-path'] ?? null,
  }));
  const deleted = new Set(items.filter((item) => item.action === 'D').map((item) => item.path));
  const renamedFrom = new Set(
    items.filter((item) => item.action === 'A' && item.from && deleted.has(item.from)).map((item) => item.from),
  );
  const changes = [];
  for (const item of items) {
    const path = underRoot(item.path, rootPath);
    if (path === null || (item.action === 'D' && renamedFrom.has(item.path))) continue;
    const oldPath = item.from ? underRoot(item.from, rootPath) : null;
    let status = LOG_ACTIONS[item.action] ?? 'modified';
    if (item.action === 'A' && item.from) status = renamedFrom.has(item.from) ? 'renamed' : 'copied';
    changes.push({ path, oldPath: status === 'renamed' || status === 'copied' ? oldPath : null, status, flags: [] });
  }
  return changes;
}

/**
 * `svn log --xml [--verbose]` as history entries, newest first. Without
 * `--verbose` an entry lists no changes.
 *
 * @param {string} xml
 * @param {string | null} rootPath Repository path of the root, from `svn info`.
 */
export function parseLog(xml, rootPath) {
  return parseXml(xml)
    .all('logentry')
    .map((entry) => ({
      revision: revisionOf(entry.attributes.revision),
      author: entry.textOf('author'),
      date: entry.textOf('date'),
      message: entry.textOf('msg') ?? '',
      changes: logChanges(entry.child('paths')?.all('path') ?? [], rootPath),
      changesTruncated: false,
    }));
}

/**
 * `svn blame --xml` of one file: per line the revision it comes from, or
 * `null` for a line changed locally, and the details of each revision.
 */
export function parseBlame(xml) {
  const blameTarget = parseXml(xml).child('target');
  if (!blameTarget) throw new Error('svn blame printed no target.');
  const revisions = new Map();
  const lines = blameTarget.all('entry').map((entry) => {
    const commit = entry.child('commit');
    const id = commit?.attributes.revision;
    if (!isRevisionNumber(id)) return null;
    if (!revisions.has(id)) {
      revisions.set(id, { revision: revisionOf(id), author: commit.textOf('author'), date: commit.textOf('date'), message: null });
    }
    return id;
  });
  return { lines, revisions };
}

/** The revision `svn commit` reports, or `null` when nothing was committed. */
export function committedRevision(stdout) {
  return /^Committed revision (\d+)\.$/m.exec(stdout)?.[1] ?? null;
}
