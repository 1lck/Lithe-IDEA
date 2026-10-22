// A sample VCS provider written with the Lithe plugin SDK. It is not a real
// version control system: a working copy is a directory with a
// `.samplevcs/revisions.json` file that stores every revision as a full
// snapshot of the files' text, so the sample shows the protocol without a
// VCS client. A real provider, such as the official Subversion plugin, runs
// its client through `context.run` and parses the output instead.
//
// Rust Core's end-to-end test (rust/lithe-core/tests/plugin_sdk/vcs.rs)
// drives every operation below through a real session. A packaged plugin
// vendors the SDK inside its package, for example as
// `provider/vendor/lithe-plugin-sdk/`, and imports it from there.

import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createBackend, PluginError, VCS_ERRORS } from '../../../src/index.mjs';

const METADATA = '.samplevcs';

/** The working copy's metadata: its revisions, oldest first, and pending operations. */
function load(root) {
  const read = (name, fallback) => {
    const path = join(root, METADATA, name);
    return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : fallback;
  };
  return {
    revisions: read('revisions.json', []),
    pending: read('pending.json', { added: [], deleted: [], moved: {} }),
  };
}

function save(root, { revisions, pending }) {
  writeFileSync(join(root, METADATA, 'revisions.json'), `${JSON.stringify(revisions, null, 2)}\n`);
  writeFileSync(join(root, METADATA, 'pending.json'), `${JSON.stringify(pending, null, 2)}\n`);
}

/** Text of every file below `root`, by `/`-separated relative path. */
function workingFiles(root, directory = '', files = {}) {
  for (const entry of readdirSync(join(root, directory), { withFileTypes: true })) {
    if (entry.name === METADATA) continue;
    const path = directory ? `${directory}/${entry.name}` : entry.name;
    if (entry.isDirectory()) workingFiles(root, path, files);
    else if (entry.isFile()) files[path] = readFileSync(join(root, path), 'utf8');
  }
  return files;
}

const head = (revisions) => revisions.at(-1) ?? null;
const base = (revisions) => head(revisions)?.files ?? {};
const revisionOf = (entry) => ({ id: entry.id, display: `r${entry.id}`, kind: 'number' });

function rootOf(params) {
  const root = params.root.path;
  if (existsSync(join(root, METADATA, 'lock'))) {
    throw new PluginError(VCS_ERRORS.workingCopyLocked, 'The working copy is locked; run Cleanup.');
  }
  return root;
}

function status(params) {
  const root = rootOf(params);
  const { revisions, pending } = load(root);
  const committed = base(revisions);
  const disk = workingFiles(root);
  const moveSources = new Set(Object.values(pending.moved));
  const changes = [];
  for (const [path, text] of Object.entries(committed)) {
    if (moveSources.has(path)) continue;
    if (!(path in disk)) {
      changes.push({ path, status: pending.deleted.includes(path) ? 'deleted' : 'missing' });
    } else if (disk[path] !== text) {
      changes.push({ path, status: 'modified' });
    }
  }
  for (const path of Object.keys(disk)) {
    if (path in committed) continue;
    if (pending.moved[path]) changes.push({ path, oldPath: pending.moved[path], status: 'renamed' });
    else changes.push({ path, status: pending.added.includes(path) ? 'added' : 'unversioned' });
  }
  const latest = head(revisions);
  // Core sorts the changes and checks every path; the provider only reports.
  return { head: { revision: latest && revisionOf(latest), branch: null, location: null }, changes };
}

function baseContent(params) {
  const content = base(load(rootOf(params)).revisions)[params.path];
  return { content: content ?? null, binary: false };
}

function checkin(params) {
  const root = rootOf(params);
  const state = load(root);
  const files = { ...base(state.revisions) };
  const disk = workingFiles(root);
  const changes = [];
  for (const path of params.paths) {
    const source = state.pending.moved[path];
    if (source) {
      delete files[source];
      delete state.pending.moved[path];
      changes.push({ path, oldPath: source, status: 'renamed' });
    } else if (!(path in disk)) {
      changes.push({ path, status: 'deleted' });
    } else {
      changes.push({ path, status: path in files ? 'modified' : 'added' });
    }
    if (path in disk) files[path] = disk[path];
    else delete files[path];
    state.pending.added = state.pending.added.filter((added) => added !== path);
    state.pending.deleted = state.pending.deleted.filter((deleted) => deleted !== path);
  }
  const entry = {
    id: String(state.revisions.length + 1),
    author: 'sample',
    date: new Date(Date.UTC(2026, 0, 1, 0, 0, state.revisions.length)).toISOString(),
    message: params.message,
    files,
    changes,
  };
  state.revisions.push(entry);
  save(root, state);
  return { revision: revisionOf(entry) };
}

function rollback(params) {
  const root = rootOf(params);
  const state = load(root);
  const committed = base(state.revisions);
  for (const path of params.paths) {
    // Rolling back a move target puts the file back where it came from.
    const source = state.pending.moved[path];
    if (source) {
      mkdirSync(dirname(join(root, source)), { recursive: true });
      if (existsSync(join(root, path))) renameSync(join(root, path), join(root, source));
      if (source in committed) writeFileSync(join(root, source), committed[source]);
      delete state.pending.moved[path];
      continue;
    }
    if (path in committed) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), committed[path]);
    }
    // Like `svn revert`, an added file stays on disk, unversioned again.
    state.pending.added = state.pending.added.filter((added) => added !== path);
    state.pending.deleted = state.pending.deleted.filter((deleted) => deleted !== path);
  }
  save(root, state);
}

/** One page of `entries`, newest first, resumed from an opaque cursor. */
function page(entries, { cursor, limit = 100 }) {
  const start = cursor ? Number(cursor) : 0;
  const slice = entries.slice(start, start + limit);
  return {
    entries: slice.map((entry) => ({
      revision: revisionOf(entry),
      author: entry.author,
      date: entry.date,
      message: entry.message,
      changes: entry.changes,
      changesTruncated: false,
    })),
    nextCursor: start + limit < entries.length ? String(start + limit) : null,
  };
}

function history(params) {
  return page(load(rootOf(params)).revisions.toReversed(), params);
}

function fileHistory(params) {
  const touched = (entry) => entry.changes.some((change) => change.path === params.path || change.oldPath === params.path);
  return page(load(rootOf(params)).revisions.filter(touched).toReversed(), params);
}

/** Each line comes from the oldest revision since which the file kept it. */
function annotate(params) {
  const root = rootOf(params);
  const { revisions } = load(root);
  const lines = readFileSync(join(root, params.path), 'utf8').split('\n');
  if (lines.at(-1) === '') lines.pop();
  const origins = lines.map((line) => {
    let origin = null;
    for (const entry of revisions.toReversed()) {
      const text = entry.files[params.path];
      if (text === undefined || !text.split('\n').includes(line)) break;
      origin = entry;
    }
    return origin;
  });
  const used = new Map(origins.filter(Boolean).map((entry) => [entry.id, entry]));
  return {
    revisions: [...used.values()].map((entry) => ({
      revision: revisionOf(entry),
      author: entry.author,
      date: entry.date,
      message: entry.message,
    })),
    lines: origins.map((entry) => entry?.id ?? null),
  };
}

/** The sample has no server, so an update only reports where the copy is. */
function update(params) {
  const latest = head(load(rootOf(params)).revisions);
  return { revision: latest && revisionOf(latest), conflicts: [] };
}

function fileOperation(params) {
  const root = rootOf(params);
  const state = load(root);
  if (params.kind === 'add') {
    state.pending.added = [...new Set([...state.pending.added, ...params.paths])];
  } else if (params.kind === 'delete') {
    for (const path of params.paths) rmSync(join(root, path), { force: true });
    state.pending.deleted = [...new Set([...state.pending.deleted, ...params.paths])];
  } else {
    mkdirSync(dirname(join(root, params.to)), { recursive: true });
    renameSync(join(root, params.from), join(root, params.to));
    state.pending.moved[params.to] = params.from;
  }
  save(root, state);
}

/**
 * Clears an interrupted operation's lock. A real provider runs its client
 * here (`svn cleanup`); the sample runs the tool's version check so the host
 * sees an execution report in its console.
 */
async function cleanup(params, context) {
  if (!params.tool) throw new PluginError(VCS_ERRORS.toolUnavailable, 'The sample tool was not found.');
  const result = await context.run(params.tool.executable, ['--version']);
  if (result.exitCode !== 0) throw new PluginError(VCS_ERRORS.toolUnavailable, 'The sample tool did not run.');
  rmSync(join(params.root.path, METADATA, 'lock'), { force: true });
}

createBackend({ name: 'sample-vcs', version: '0.1.0' })
  .vcs('sample', {
    status,
    baseContent,
    checkin,
    rollback,
    history,
    fileHistory,
    annotate,
    update,
    fileOperation,
    resolve: () => {},
    cleanup,
  })
  .listen();
