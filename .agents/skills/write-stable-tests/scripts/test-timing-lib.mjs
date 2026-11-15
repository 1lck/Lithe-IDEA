import { spawn, spawnSync } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function processGroupIsRunning(processID) {
  try {
    process.kill(-processID, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function processIsRunning(processID) {
  try {
    process.kill(processID, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function addDescendantProcessIDs(rootProcessID, processIDs) {
  let rows;
  try {
    const listing = spawnSync("ps", ["-axo", "pid=,ppid="], {
      encoding: "utf8",
      timeout: 5000,
    });
    if (listing.status !== 0) return;
    rows = listing.stdout
      .split("\n")
      .map((line) => line.trim().split(/\s+/).map(Number))
      .filter(([pid, ppid]) => Number.isInteger(pid) && Number.isInteger(ppid));
  } catch {
    // The direct process group remains the portable fallback when ps is unavailable.
    return;
  }

  processIDs.add(rootProcessID);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, ppid] of rows) {
      if (!processIDs.has(ppid) || processIDs.has(pid)) continue;
      processIDs.add(pid);
      changed = true;
    }
  }
}

function signalProcessGroup(child, signal) {
  try {
    process.kill(-child.pid, signal);
    return true;
  } catch {
    try {
      return child.kill(signal);
    } catch {
      return false;
    }
  }
}

function signalDescendantProcesses(rootProcessID, processIDs, signal) {
  // The process-group signal handles ordinary descendants. Signal every known
  // non-root PID as well because swift-testing may create a new process group.
  for (const processID of processIDs) {
    if (processID === rootProcessID) continue;
    try {
      process.kill(processID, signal);
    } catch {
      // It either exited between the snapshot and signal or is already gone.
    }
  }
}

function processTreeIsRunning(processID, processIDs) {
  return processGroupIsRunning(processID)
    || [...processIDs].some((candidate) => processIsRunning(candidate));
}

async function waitForProcessTreeExit(processID, processIDs, timeoutMs, pollIntervalMs) {
  const deadline = performance.now() + timeoutMs;
  while (processTreeIsRunning(processID, processIDs) && performance.now() < deadline) {
    await delay(pollIntervalMs);
  }
  return !processTreeIsRunning(processID, processIDs);
}

export async function terminateProcessTree(
  child,
  {
    gracePeriodMs = 1000,
    forcedTerminationTimeoutMs = 1000,
    pollIntervalMs = 20,
    spawnSyncImpl = spawnSync,
  } = {},
) {
  if (!child.pid) return true;
  if (process.platform === "win32") {
    const result = spawnSyncImpl("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
      timeout: 5000,
    });
    if (result.error || result.status !== 0) {
      // We cannot prove the entire tree stopped, but still try to stop the
      // direct child before reporting the failed cleanup to the caller.
      try { child.kill(); } catch { /* The process may already have exited. */ }
      return false;
    }
    const deadline = performance.now() + forcedTerminationTimeoutMs;
    while (processIsRunning(child.pid) && performance.now() < deadline) await delay(pollIntervalMs);
    return !processIsRunning(child.pid);
  }

  const processIDs = new Set();
  addDescendantProcessIDs(child.pid, processIDs);
  signalProcessGroup(child, "SIGTERM");
  signalDescendantProcesses(child.pid, processIDs, "SIGTERM");
  if (await waitForProcessTreeExit(child.pid, processIDs, gracePeriodMs, pollIntervalMs)) return true;

  // Refresh before forcing termination so descendants created during graceful
  // shutdown cannot escape the cleanup pass.
  addDescendantProcessIDs(child.pid, processIDs);
  signalProcessGroup(child, "SIGKILL");
  signalDescendantProcesses(child.pid, processIDs, "SIGKILL");
  return waitForProcessTreeExit(
    child.pid,
    processIDs,
    forcedTerminationTimeoutMs,
    pollIntervalMs,
  );
}

function lineCollector(callback) {
  const decoder = new StringDecoder("utf8");
  let pending = "";
  return {
    push(chunk) {
      pending += decoder.write(chunk);
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";
      for (const line of lines) callback(line);
    },
    finish() {
      pending += decoder.end();
      if (pending) callback(pending);
      pending = "";
    },
  };
}

export function runProcess({
  command,
  args = [],
  cwd,
  env = process.env,
  timeoutMs,
  onStdoutLine = () => {},
  onStderrLine = () => {},
  onOutputChunk = () => {},
  onSpawn = () => {},
  streamStdout = false,
  streamStderr = false,
  terminationGraceMs = 1000,
  forcedTerminationTimeoutMs = 1000,
  terminationPollIntervalMs = 20,
  terminateProcessTreeImpl = terminateProcessTree,
  maxCapturedBytes = Infinity,
}) {
  return new Promise((resolve, reject) => {
    const startedAt = performance.now();
    const child = spawn(command, args, {
      cwd,
      env,
      detached: process.platform !== "win32",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    let capturedBytes = 0;
    const stdoutLines = lineCollector(onStdoutLine);
    const stderrLines = lineCollector(onStderrLine);
    let timedOut = false;
    let timeout;
    let terminationPromise = null;
    let cleanupFallback;
    let settled = false;

    const terminate = () => {
      terminationPromise ??= Promise.resolve().then(() => terminateProcessTreeImpl(child, {
        gracePeriodMs: terminationGraceMs,
        forcedTerminationTimeoutMs,
        pollIntervalMs: terminationPollIntervalMs,
      })).catch(() => false).then((confirmed) => {
        if (!confirmed) {
          try { child.kill(); } catch { /* Best effort; the report remains a failure. */ }
          // An inherited pipe or an unkillable process must not keep the test
          // runner alive forever. Close only this runner's handles and report
          // that process-tree termination could not be confirmed.
          cleanupFallback = setTimeout(() => {
            child.stdout.destroy();
            child.stderr.destroy();
            child.unref();
            void finish(null, null);
          }, forcedTerminationTimeoutMs);
        }
        return confirmed;
      });
      return terminationPromise;
    };

    const finish = async (code, signal) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      const terminationConfirmed = terminationPromise ? await terminationPromise : true;
      if (cleanupFallback) clearTimeout(cleanupFallback);
      stdoutLines.finish();
      stderrLines.finish();
      resolve({
        code,
        signal,
        timedOut,
        terminationConfirmed,
        durationMs: performance.now() - startedAt,
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        stderr: Buffer.concat(stderrChunks).toString("utf8"),
      });
    };

    onSpawn({
      pid: child.pid,
      terminate,
    });

    if (timeoutMs > 0) {
      timeout = setTimeout(() => {
        timedOut = true;
        void terminate();
      }, timeoutMs);
    }

    child.stdout.on("data", (chunk) => {
      if (chunk.length > 0) onOutputChunk(chunk, "stdout");
      const captured = chunk.subarray(0, Math.max(0, Math.min(chunk.length, maxCapturedBytes - capturedBytes)));
      capturedBytes += captured.length;
      if (captured.length) { stdoutChunks.push(captured); stdoutLines.push(captured); }
      if (streamStdout) process.stdout.write(chunk);
    });
    child.stderr.on("data", (chunk) => {
      if (chunk.length > 0) onOutputChunk(chunk, "stderr");
      const captured = chunk.subarray(0, Math.max(0, Math.min(chunk.length, maxCapturedBytes - capturedBytes)));
      capturedBytes += captured.length;
      if (captured.length) { stderrChunks.push(captured); stderrLines.push(captured); }
      if (streamStderr) process.stderr.write(chunk);
    });
    child.once("error", (error) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code, signal) => { void finish(code, signal); });
  });
}

export function positiveInteger(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${label} must be a positive integer.`);
  return parsed;
}
