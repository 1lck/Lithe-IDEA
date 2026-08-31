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

async function waitForProcessGroupExit(processID, timeoutMs, pollIntervalMs) {
  const deadline = performance.now() + timeoutMs;
  while (processGroupIsRunning(processID) && performance.now() < deadline) {
    await delay(pollIntervalMs);
  }
  return !processGroupIsRunning(processID);
}

export async function terminateProcessTree(
  child,
  {
    gracePeriodMs = 1000,
    forcedTerminationTimeoutMs = 1000,
    pollIntervalMs = 20,
  } = {},
) {
  if (!child.pid) return true;
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
    return true;
  }

  signalProcessGroup(child, "SIGTERM");
  if (await waitForProcessGroupExit(child.pid, gracePeriodMs, pollIntervalMs)) return true;
  signalProcessGroup(child, "SIGKILL");
  return waitForProcessGroupExit(child.pid, forcedTerminationTimeoutMs, pollIntervalMs);
}

function lineCollector(callback, partialCallback = () => {}) {
  const decoder = new StringDecoder("utf8");
  let pending = "";
  return {
    push(chunk) {
      pending += decoder.write(chunk);
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";
      for (const line of lines) callback(line);
      if (pending) partialCallback(pending);
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
  onStdoutPartialLine = () => {},
  onStderrPartialLine = () => {},
  onSpawn = () => {},
  streamStdout = false,
  streamStderr = false,
  terminationGraceMs = 1000,
  forcedTerminationTimeoutMs = 1000,
  terminationPollIntervalMs = 20,
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
    const stdoutLines = lineCollector(onStdoutLine, onStdoutPartialLine);
    const stderrLines = lineCollector(onStderrLine, onStderrPartialLine);
    let timedOut = false;
    let timeout;
    let terminationPromise = null;
    let settled = false;

    const terminate = () => {
      terminationPromise ??= terminateProcessTree(child, {
        gracePeriodMs: terminationGraceMs,
        forcedTerminationTimeoutMs,
        pollIntervalMs: terminationPollIntervalMs,
      });
      return terminationPromise;
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
      stdoutChunks.push(chunk);
      stdoutLines.push(chunk);
      if (streamStdout) process.stdout.write(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderrChunks.push(chunk);
      stderrLines.push(chunk);
      if (streamStderr) process.stderr.write(chunk);
    });
    child.once("error", (error) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      reject(error);
    });
    child.once("close", async (code, signal) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      const terminationConfirmed = terminationPromise ? await terminationPromise : true;
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
    });
  });
}

export function positiveInteger(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${label} must be a positive integer.`);
  return parsed;
}
