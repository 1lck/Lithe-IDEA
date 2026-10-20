// Child processes a backend starts for one call. Lithe's host offers no
// process capability in protocol version 1, so a backend runs its tools
// itself; this helper makes sure that cancelling the call, or the backend
// shutting down, also ends the whole process tree it started.

import { spawn } from 'node:child_process';

const isWindows = process.platform === 'win32';

/** Every process tree started through `runProcess` that has not exited. */
const running = new Set();

/**
 * Runs `command` without a shell and resolves with its exit status and
 * captured output. Aborting `signal` ends the process tree and rejects with
 * the signal's reason. A non-zero exit resolves; the caller decides what it
 * means for its tool.
 *
 * @param {string} command Executable path or name.
 * @param {string[]} [args]
 * @param {object} [options]
 * @param {string} [options.cwd]
 * @param {Record<string, string>} [options.env] Replaces the environment when given.
 * @param {AbortSignal} [options.signal]
 * @param {number} [options.maxOutputBytes] Captured bytes per stream; default 1 MiB.
 * @param {(chunk: string) => void} [options.onStdout]
 * @param {(chunk: string) => void} [options.onStderr]
 * @param {number} [options.killGraceMilliseconds] Delay between the polite and forced stop; default 2000.
 */
export function runProcess(command, args = [], options = {}) {
  const { cwd, env, signal, onStdout, onStderr } = options;
  const maxOutputBytes = options.maxOutputBytes ?? 1 << 20;
  const killGraceMilliseconds = options.killGraceMilliseconds ?? 2000;
  if (signal?.aborted) return Promise.reject(signal.reason);

  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env,
      shell: false,
      windowsHide: true,
      // Its own process group on POSIX, so a stop reaches grandchildren too.
      detached: !isWindows,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const entry = { child, stopping: false, forceTimer: null };
    running.add(entry);
    const stdout = capture(maxOutputBytes, onStdout);
    const stderr = capture(maxOutputBytes, onStderr);
    child.stdout.on('data', stdout.push);
    child.stderr.on('data', stderr.push);

    const onAbort = () => stopTree(entry, killGraceMilliseconds);
    signal?.addEventListener('abort', onAbort, { once: true });

    let settled = false;
    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      // A stopped tree stays registered until its forced stop: the leader
      // can exit on SIGTERM while a grandchild in its group ignores it.
      if (!entry.stopping) running.delete(entry);
      signal?.removeEventListener('abort', onAbort);
      outcome();
    };
    child.once('error', (error) => finish(() => reject(error)));
    child.once('close', (exitCode, exitSignal) =>
      finish(() => {
        if (signal?.aborted) {
          reject(signal.reason);
          return;
        }
        resolve({
          exitCode,
          signal: exitSignal,
          stdout: stdout.text(),
          stderr: stderr.text(),
          truncated: stdout.truncated() || stderr.truncated(),
        });
      }),
    );
  });
}

/**
 * Forcibly ends every process tree still running. The backend calls it on
 * shutdown, on `exit`, and when the host closes stdin, so no tool outlives
 * the session that started it.
 */
export function killAllProcesses() {
  for (const entry of running) {
    clearTimeout(entry.forceTimer);
    signalTree(entry.child, 'SIGKILL', { evenAfterExit: true });
  }
  running.clear();
}

/** Number of process trees still running or being stopped, for tests and diagnostics. */
export function runningProcessCount() {
  return running.size;
}

function stopTree(entry, graceMilliseconds) {
  if (entry.stopping) return;
  entry.stopping = true;
  signalTree(entry.child, 'SIGTERM');
  entry.forceTimer = setTimeout(() => {
    running.delete(entry);
    signalTree(entry.child, 'SIGKILL', { evenAfterExit: true });
  }, graceMilliseconds);
  entry.forceTimer.unref?.();
}

/**
 * Signals the child's whole tree. `evenAfterExit` still signals the POSIX
 * process group after its leader exited, which reaches members that survived
 * the polite stop. While any member lives the group ID cannot be reused;
 * once all exited the signal fails with ESRCH, which is ignored.
 */
function signalTree(child, signalName, { evenAfterExit = false } = {}) {
  if (child.pid === undefined) return;
  const exited = child.exitCode !== null || child.signalCode !== null;
  if (exited && (isWindows || !evenAfterExit)) return;
  try {
    if (isWindows) {
      // taskkill /T is the only stock way to end a Windows process tree.
      spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    } else {
      process.kill(-child.pid, signalName);
    }
  } catch {
    // The group already exited between the check and the signal.
  }
}

function capture(limit, listener) {
  const chunks = [];
  let size = 0;
  let truncated = false;
  return {
    push(chunk) {
      listener?.(chunk.toString('utf8'));
      if (size >= limit) {
        truncated = true;
        return;
      }
      const kept = chunk.subarray(0, limit - size);
      truncated ||= kept.length < chunk.length;
      chunks.push(kept);
      size += kept.length;
    },
    text: () => Buffer.concat(chunks).toString('utf8'),
    truncated: () => truncated,
  };
}
