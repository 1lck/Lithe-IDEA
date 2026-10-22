// The official Subversion provider: answers Lithe's VCS provider contract
// (shared/contracts/vcs-provider-v1.md) by running the user's `svn` client
// in the working copy root and reading its `--xml` output. Parsing lives in
// svn-output.mjs; this file decides which commands an operation runs.
//
// Every command runs with `--non-interactive`, so svn answers from its own
// credential cache or fails; the provider never sees a password. Commands
// that change the working copy or the repository are reported to the host's
// console; reads are not.

import { mkdtemp, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createBackend, PluginError, VCS_ERRORS } from './vendor/lithe-plugin-sdk/index.mjs';
import {
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
  revisionOf,
  statusChanges,
  svnEnvironment,
  target,
} from './svn-output.mjs';

/** Largest base content the contract carries. */
const BASE_CONTENT_LIMIT = 32 * 1024 * 1024;
/** Captured `--xml` output; status of a large tree and long blames fit. */
const XML_OUTPUT_LIMIT = 256 * 1024 * 1024;
/** Changes one history entry may list. */
const MAX_ENTRY_CHANGES = 10_000;

const TOOL_MISSING = 'Subversion (svn) was not found or could not run. Install Subversion 1.8 or newer.';

/**
 * Runs `svn` in the root. A missing or unrunnable client is the contract's
 * `toolUnavailable`; any exit status resolves for the caller to judge.
 */
async function svn(params, context, args, { report = false, maxOutputBytes = 16 * 1024 * 1024 } = {}) {
  if (!params.tool) throw new PluginError(VCS_ERRORS.toolUnavailable, TOOL_MISSING);
  try {
    return await context.run(params.tool.executable, ['--non-interactive', ...args], {
      cwd: params.root.path,
      env: svnEnvironment(),
      maxOutputBytes,
      report,
    });
  } catch (error) {
    if (['ENOENT', 'EACCES', 'ENOEXEC'].includes(error?.code)) {
      throw new PluginError(VCS_ERRORS.toolUnavailable, TOOL_MISSING);
    }
    throw error;
  }
}

/**
 * The error of a failed command. svn names local paths absolutely; inside
 * the root they are shown relative to it, as the host shows them.
 */
function failure(params, stderr) {
  let text = stderr;
  for (const root of rootSpellings(params.root.path)) text = text.replaceAll(`${root}/`, '');
  const { kind, message } = classifyFailure(text);
  return new PluginError(kind ? VCS_ERRORS[kind] : 'svn.command.failed', message);
}

/** The root as given and as svn resolves it (`/tmp` is `/private/tmp` on macOS). */
function rootSpellings(root) {
  try {
    const real = realpathSync(root);
    return real === root ? [root] : [root, real];
  } catch {
    return [root];
  }
}

/** The result of a command that must succeed. */
function succeeded(params, result) {
  if (result.exitCode !== 0 || notWorkingCopy(result.stderr)) throw failure(params, result.stderr);
  return result;
}

/** The output of a command that must succeed and whose output is parsed whole. */
function complete(params, result) {
  succeeded(params, result);
  if (result.truncated) throw new PluginError('svn.output.tooLarge', 'svn printed more output than Lithe reads.');
  return result.stdout;
}

async function rootInfo(params, context) {
  return parseInfo(complete(params, await svn(params, context, ['info', '--xml'], { maxOutputBytes: 1 << 20 })));
}

/** Every status entry of the root, externals left to their own roots. */
async function statusEntries(params, context, { includeIgnored = false } = {}) {
  const args = ['status', '--xml', '--ignore-externals'];
  if (includeIgnored) args.push('--no-ignore');
  return parseStatus(complete(params, await svn(params, context, args, { maxOutputBytes: XML_OUTPUT_LIMIT })));
}

/**
 * Runs a command that takes many paths through a `--targets` file, which has
 * no command-line length limit; each path is a peg-escaped target.
 */
async function withTargets(paths, run) {
  const directory = await mkdtemp(join(tmpdir(), 'lithe-svn-'));
  try {
    const file = join(directory, 'targets');
    await writeFile(file, `${paths.map(target).join('\n')}\n`);
    return await run(file, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function status(params, context) {
  const info = await rootInfo(params, context);
  const entries = await statusEntries(params, context, { includeIgnored: params.includeIgnored === true });
  return {
    head: { revision: revisionOf(info.revision), branch: null, location: info.url },
    changes: statusChanges(entries),
    truncated: false,
  };
}

async function baseContent(params, context) {
  const result = await svn(params, context, ['cat', '-r', 'BASE', '--', target(params.path)], {
    maxOutputBytes: BASE_CONTENT_LIMIT + 1,
  });
  if (result.exitCode !== 0) {
    if (lacksBase(result.stderr)) return { content: null, binary: false };
    throw failure(params, result.stderr);
  }
  if (result.stdout.includes('\u0000')) return { content: null, binary: true };
  if (result.truncated) {
    throw new PluginError('svn.baseContent.tooLarge', 'The base version is larger than 32 MiB and is not shown.');
  }
  return { content: result.stdout, binary: false };
}

/**
 * One page of `svn log`, newest first. The root's history starts at HEAD so
 * a revision just committed is listed even though the root directory itself
 * stays at its older revision until an update; a file's history starts at
 * its own base, where its name is known to exist.
 */
async function logPage(params, context, path) {
  const limit = params.limit ?? 100;
  const cursor = params.cursor ?? null;
  if (cursor !== null && !isRevisionNumber(cursor)) {
    throw new PluginError('svn.history.invalidCursor', 'The history position is not a revision number.');
  }
  const info = await rootInfo(params, context);
  const start = cursor ?? (path === null ? 'HEAD' : 'BASE');
  const command = (verbose) => [
    'log',
    '--xml',
    ...(verbose ? ['--verbose'] : []),
    '--limit',
    String(limit + 1),
    '-r',
    `${start}:1`,
    ...(path === null ? [] : ['--', target(path)]),
  ];
  let result = await svn(params, context, command(true), { maxOutputBytes: XML_OUTPUT_LIMIT });
  if (result.exitCode !== 0 && path !== null && lacksHistory(result.stderr)) return { entries: [], nextCursor: null };
  // A page of revisions that touched huge trees is listed without changes.
  let verbose = true;
  if (result.exitCode === 0 && result.truncated) {
    verbose = false;
    result = await svn(params, context, command(false), { maxOutputBytes: XML_OUTPUT_LIMIT });
  }
  const entries = parseLog(complete(params, result), info.repositoryPath).map((entry) =>
    !verbose
      ? { ...entry, changesTruncated: true }
      : entry.changes.length > MAX_ENTRY_CHANGES
        ? { ...entry, changes: entry.changes.slice(0, MAX_ENTRY_CHANGES), changesTruncated: true }
        : entry,
  );
  const next = entries.length > limit ? entries[limit].revision.id : null;
  return { entries: entries.slice(0, limit), nextCursor: next };
}

/** Number of lines in `text`, as an editor counts them. */
function lineCount(text) {
  if (text === '') return 0;
  return text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
}

async function annotate(params, context) {
  const result = await svn(params, context, ['blame', '--xml', '--', target(params.path)], {
    maxOutputBytes: XML_OUTPUT_LIMIT,
  });
  if (result.exitCode !== 0 && lacksHistory(result.stderr)) {
    // Added and not committed yet: every line is local.
    const text = await readFile(join(params.root.path, params.path), 'utf8');
    return { revisions: [], lines: new Array(lineCount(text)).fill(null) };
  }
  const { lines, revisions } = parseBlame(complete(params, result));
  await addMessages(params, context, revisions);
  return { revisions: [...revisions.values()], lines };
}

/**
 * Fills in the messages of blamed revisions from one `svn log` over their
 * range. Messages are a convenience: when the log fails, for example
 * offline, the annotation is shown without them.
 */
async function addMessages(params, context, revisions) {
  if (revisions.size === 0) return;
  const ids = [...revisions.keys()].map(Number);
  const range = `${Math.max(...ids)}:${Math.min(...ids)}`;
  const result = await svn(params, context, ['log', '--xml', '-r', range, '--', target(params.path)], {
    maxOutputBytes: XML_OUTPUT_LIMIT,
  });
  if (result.exitCode !== 0 || result.truncated) return;
  try {
    for (const entry of parseLog(result.stdout, null)) {
      const blamed = revisions.get(entry.revision.id);
      if (blamed) blamed.message = entry.message;
    }
  } catch {
    // Unreadable log output leaves the messages out.
  }
}

/** Whether `path` lies inside one of `directories`. */
function insideAny(path, directories) {
  return directories.some((directory) => path.startsWith(`${directory}/`));
}

/** Every ancestor directory of `path`, nearest first. */
function ancestors(path) {
  const result = [];
  for (let index = path.lastIndexOf('/'); index > 0; index = path.lastIndexOf('/', index - 1)) {
    result.push(path.slice(0, index));
  }
  return result;
}

/**
 * Check-in commits exactly the selected changes (`--depth empty`), with what
 * svn needs alongside them: both halves of a move, added parent
 * directories, and a new directory's contents when the selection added it.
 * Selected unversioned paths are added and missing ones deleted first, as
 * IDEA does.
 */
async function checkin(params, context) {
  let entries = await statusEntries(params, context);
  const selected = new Set(params.paths);
  const unversioned = params.paths.filter((path) => entries.get(path)?.item === 'unversioned');
  const missing = params.paths.filter((path) => entries.get(path)?.item === 'missing');
  if (unversioned.length > 0) await addPaths(params, context, unversioned);
  if (missing.length > 0) await deletePaths(params, context, missing);
  if (unversioned.length > 0 || missing.length > 0) {
    entries = await statusEntries(params, context);
    for (const [path, entry] of entries) {
      if (entry.item === 'added' && insideAny(path, unversioned)) selected.add(path);
    }
  }
  for (const path of [...selected]) {
    const entry = entries.get(path);
    if (entry?.movedFrom) selected.add(entry.movedFrom);
    if (entry?.movedTo) selected.add(entry.movedTo);
  }
  for (const path of [...selected]) {
    for (const parent of ancestors(path)) {
      const item = entries.get(parent)?.item;
      if (item === 'added' || item === 'replaced') selected.add(parent);
    }
  }
  return withTargets([...selected].sort(), async (targets, directory) => {
    const messageFile = join(directory, 'message');
    await writeFile(messageFile, params.message);
    const args = ['commit', '--depth', 'empty', '--encoding', 'UTF-8', '--file', messageFile, '--targets', targets];
    // Not `--quiet`: it also hides the committed revision, printed last.
    const result = await svn(params, context, args, { report: true, maxOutputBytes: 64 * 1024 * 1024 });
    return { revision: revisionOf(committedRevision(succeeded(params, result).stdout)) };
  });
}

/**
 * Rollback discards local changes of the selected paths. A scheduled add,
 * delete, or replace is reverted with everything below it, which svn
 * requires; a modified directory reverts only its own properties. Undoing
 * a moved file deletes the copy and restores the source; a moved directory
 * is left on disk unversioned, since svn would delete unversioned files the
 * user put into it.
 */
async function rollback(params, context) {
  const entries = await statusEntries(params, context);
  const groups = { movedFiles: new Set(), deep: new Set(), shallow: new Set() };
  for (const path of params.paths) {
    const entry = entries.get(path);
    if (!entry || entry.item === 'unversioned' || entry.item === 'ignored') continue;
    const partner = entry.movedFrom ?? entry.movedTo;
    if (partner) {
      const copy = entry.movedFrom ? path : entry.movedTo;
      const directory = await isDirectory(join(params.root.path, copy));
      const group = directory ? groups.deep : groups.movedFiles;
      group.add(path).add(partner);
    } else if (['added', 'deleted', 'replaced', 'missing'].includes(entry.item)) {
      groups.deep.add(path);
    } else {
      groups.shallow.add(path);
    }
  }
  const revert = async (paths, extra) => {
    if (paths.size === 0) return;
    await withTargets([...paths].sort(), async (targets) => {
      succeeded(params, await svn(params, context, ['revert', ...extra, '--targets', targets], { report: true }));
    });
  };
  await revert(groups.movedFiles, ['--depth', 'infinity', '--remove-added']);
  await revert(groups.deep, ['--depth', 'infinity']);
  await revert(groups.shallow, ['--depth', 'empty']);
  return {};
}

async function isDirectory(path) {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

async function update(params, context) {
  // Quiet: a large update prints a line per file; status reports the outcome.
  const args = ['update', '--quiet', '--accept', 'postpone'];
  if (params.revision !== undefined && params.revision !== null) {
    if (!isRevisionNumber(params.revision)) {
      throw new PluginError('svn.update.invalidRevision', 'The revision to update to is not a revision number.');
    }
    args.push('-r', params.revision);
  }
  succeeded(params, await svn(params, context, args, { report: true }));
  const info = await rootInfo(params, context);
  const entries = await statusEntries(params, context);
  return { revision: revisionOf(info.revision), conflicts: conflictedPaths(entries) };
}

async function addPaths(params, context, paths) {
  await withTargets(paths, async (targets) => {
    const result = await svn(params, context, ['add', '--parents', '--targets', targets], { report: true });
    // svn adds the other targets and then fails over one already versioned.
    if (result.exitCode !== 0 && onlyAlreadyVersioned(result.stderr)) return;
    succeeded(params, result);
  });
}

async function deletePaths(params, context, paths) {
  await withTargets(paths, async (targets) => {
    succeeded(params, await svn(params, context, ['delete', '--force', '--targets', targets], { report: true }));
  });
}

/**
 * Adds, deletes, or moves paths through svn so it keeps tracking them. An
 * unversioned source is moved on disk, since svn has nothing to record.
 */
async function fileOperation(params, context) {
  if (params.kind === 'add') {
    await addPaths(params, context, params.paths);
  } else if (params.kind === 'delete') {
    await deletePaths(params, context, params.paths);
  } else {
    // The destination is a plain path: svn reads a trailing `@` on it literally.
    const args = ['move', '--parents', '--', target(params.from), params.to];
    const result = await svn(params, context, args, { report: true });
    const source = join(params.root.path, params.from);
    if (result.exitCode !== 0 && lacksBase(result.stderr) && (await exists(source))) {
      const destination = join(params.root.path, params.to);
      await mkdir(dirname(destination), { recursive: true });
      await rename(source, destination);
    } else {
      succeeded(params, result);
    }
  }
  return {};
}

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function resolve(params, context) {
  await withTargets(params.paths, async (targets) => {
    const args = ['resolve', '--accept', 'working', '--depth', 'empty', '--targets', targets];
    succeeded(params, await svn(params, context, args, { report: true }));
  });
  return {};
}

async function cleanup(params, context) {
  succeeded(params, await svn(params, context, ['cleanup'], { report: true }));
  return {};
}

createBackend({ name: 'svn-support', version: '0.1.0' })
  .vcs('svn', {
    status,
    baseContent,
    history: (params, context) => logPage(params, context, null),
    fileHistory: (params, context) => logPage(params, context, params.path),
    annotate,
    checkin,
    rollback,
    update,
    fileOperation,
    resolve,
    cleanup,
  })
  .listen();
