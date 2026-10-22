// Durable plugin state. The host gives every backend writable directories
// through the `${stateDir}` and `${workspaceStateDir}` launch variables; the
// installed package and the host's installation are read-only, because
// signatures and delta updates are computed over their exact bytes.

import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { randomBytes } from 'node:crypto';
import { PluginSdkError } from './errors.mjs';

/** Version of the envelope each value is stored in. */
const STORE_FORMAT = 1;
const KEY = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

/**
 * Opens a key-value store in `directory`, creating the directory. Values are
 * JSON; each key is one file replaced atomically, so a crash leaves either the
 * old or the new value, never half of one.
 *
 * @param {string} directory Absolute path, normally the value of `${workspaceStateDir}`.
 * @param {object} [options]
 * @param {string | null} [options.packageDirectory] The installed plugin package,
 *   which the store refuses to write into. Defaults to the nearest directory
 *   containing `plugin.json` above the running entry script.
 */
export function openStateStore(directory, options = {}) {
  if (typeof directory !== 'string' || !isAbsolute(directory)) {
    throw new PluginSdkError('sdk.state.invalidDirectory', 'The state directory must be an absolute path passed by the host.');
  }
  const packageDirectory = options.packageDirectory === undefined ? findPackageDirectory() : options.packageDirectory;
  // Checked before creating anything, so a refused path leaves the package untouched.
  const root = canonical(directory);
  if (packageDirectory && isInside(root, canonical(packageDirectory))) {
    throw new PluginSdkError(
      'sdk.state.readOnlyPackage',
      'The state directory is inside the plugin package, which is read-only. Use ${stateDir} or ${workspaceStateDir}.',
    );
  }
  mkdirSync(root, { recursive: true });
  return new StateStore(root);
}

class StateStore {
  #root;

  constructor(root) {
    this.#root = root;
  }

  /** The resolved directory, for a backend that keeps its own files next to the store. */
  get directory() {
    return this.#root;
  }

  /** The stored value, or `fallback` when the key is missing or unreadable. */
  read(key, fallback = undefined) {
    const path = this.#path(key);
    if (!existsSync(path)) return fallback;
    try {
      const envelope = JSON.parse(readFileSync(path, 'utf8'));
      if (envelope?.litheStateStore !== STORE_FORMAT || !('value' in envelope)) return fallback;
      return envelope.value;
    } catch {
      return fallback;
    }
  }

  /** Stores `value`, which must be JSON-serializable, replacing the previous one. */
  write(key, value) {
    const path = this.#path(key);
    // `undefined`, a function, or a symbol would vanish from the envelope and
    // silently replace the stored value with nothing; refuse it and keep the file.
    if (JSON.stringify(value) === undefined) {
      throw new PluginSdkError('sdk.state.invalidValue', `The value for ${key} is not JSON-serializable.`);
    }
    const body = JSON.stringify({ litheStateStore: STORE_FORMAT, value });
    const temporary = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
    try {
      writeFileSync(temporary, body, { encoding: 'utf8', mode: 0o600 });
      const handle = openSync(temporary, 'r');
      try {
        fsyncSync(handle);
      } finally {
        closeSync(handle);
      }
      renameSync(temporary, path);
    } catch (error) {
      rmSync(temporary, { force: true });
      throw error;
    }
  }

  /** Removes the key; a missing key is not an error. */
  delete(key) {
    rmSync(this.#path(key), { force: true });
  }

  #path(key) {
    if (typeof key !== 'string' || !KEY.test(key) || key.endsWith('.tmp')) {
      throw new PluginSdkError(
        'sdk.state.invalidKey',
        `State key ${JSON.stringify(key)} must be 1-128 letters, digits, ".", "_" or "-", start with a letter or digit, and not end with ".tmp".`,
      );
    }
    return join(this.#root, `${key}.json`);
  }
}

function isInside(path, parent) {
  const difference = relative(parent, path);
  return difference === '' || (!difference.startsWith(`..${sep}`) && difference !== '..' && !isAbsolute(difference));
}

/** Resolves symbolic links of the longest existing prefix of `path`. */
function canonical(path) {
  const missing = [];
  let current = resolve(path);
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) break;
    missing.unshift(basename(current));
    current = parent;
  }
  return join(realpathSync(current), ...missing);
}

function findPackageDirectory() {
  const entry = process.argv[1];
  if (!entry) return null;
  let current = dirname(resolve(entry));
  for (;;) {
    if (existsSync(join(current, 'plugin.json'))) return current;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}
