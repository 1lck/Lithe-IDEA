import { spawn, spawnSync } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

function terminateProcessTree(child) {
  if (!child.pid || child.exitCode !== null) return;
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
    return;
  }
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    try {
      child.kill("SIGTERM");
    } catch {
      return;
    }
  }
  setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      // The process group normally exits after SIGTERM.
    }
  }, 1000).unref();
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
  onSpawn = () => {},
  streamStdout = false,
  streamStderr = false,
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
    const stdoutLines = lineCollector(onStdoutLine);
    const stderrLines = lineCollector(onStderrLine);
    let timedOut = false;
    let timeout;

    onSpawn({
      pid: child.pid,
      terminate: () => terminateProcessTree(child),
    });

    if (timeoutMs > 0) {
      timeout = setTimeout(() => {
        timedOut = true;
        terminateProcessTree(child);
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
      if (timeout) clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code, signal) => {
      if (timeout) clearTimeout(timeout);
      stdoutLines.finish();
      stderrLines.finish();
      resolve({
        code,
        signal,
        timedOut,
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
