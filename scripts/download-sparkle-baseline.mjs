#!/usr/bin/env node

import { spawn } from "node:child_process";
import { mkdtemp, rename, rm, stat } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const MAX_ATTEMPTS = 3;
const ATTEMPT_TIMEOUT_MS = 120_000;
const RETRY_DELAY_MS = 2_000;

// gh has no per-download deadline. Own its process group so timeout/cancellation
// finishes the attempt before its partial archive is removed or retried.
export function runDownload(command, args, { signal, timeoutMs }) {
  signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    let timedOut = false;
    const stop = () => {
      if (child.pid) {
        try { process.kill(-child.pid, "SIGKILL"); }
        catch (error) { if (error.code !== "ESRCH") reject(error); }
      }
    };
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", stop);
    };
    signal?.addEventListener("abort", stop, { once: true });
    if (signal?.aborted) stop();
    child.stderr.on("data", (data) => { stderr = (stderr + data.toString()).slice(-16_384); });
    child.once("error", (error) => { cleanup(); reject(error); });
    child.once("close", (code, terminationSignal) => {
      cleanup();
      if (signal?.aborted) reject(signal.reason);
      else resolve({ code, stderr, timedOut, terminationSignal });
    });
  });
}

function isTransient(result) {
  if (result.timedOut) return true;
  if (result.terminationSignal || [130, 143].includes(result.code)) return false;
  const status = /\bHTTP\s+(\d{3})\b/i.exec(result.stderr);
  if (status) return /^(408|429|5\d\d)$/.test(status[1]);
  return /\b(i\/o timeout|connection reset|connection refused|TLS handshake timeout|temporary failure|unexpected EOF|network is unreachable)\b/i.test(result.stderr);
}

export async function downloadSparkleBaseline({ repository, tag, name, archives }, {
  signal,
  run = runDownload,
  sleep = (milliseconds) => delay(milliseconds, undefined, { signal }),
  log = (message) => console.error(message),
} = {}) {
  // Only the selector's exact archive name may be promoted into Sparkle's input.
  if (!/^Lithe-(?:\d+\.\d+\.\d+|preview-\d+\.\d+)-(?:arm64|x86_64)\.zip$/.test(name)) {
    throw new Error("Invalid Sparkle baseline archive name");
  }
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    signal?.throwIfAborted();
    const staging = await mkdtemp(path.join(archives, ".baseline-"));
    const destination = path.join(archives, name);
    let promoted = false;
    let result;
    try {
      result = await run("gh", ["release", "download", tag, "--repo", repository,
        "--pattern", name, "--dir", staging], { signal, timeoutMs: ATTEMPT_TIMEOUT_MS });
      signal?.throwIfAborted();
      if (result.code === 0 && !result.timedOut && !result.terminationSignal) {
        const downloaded = path.join(staging, name);
        const info = await stat(downloaded);
        if (!info.isFile() || info.size === 0) throw new Error(`Empty Sparkle baseline: ${tag}/${name}`);
        signal?.throwIfAborted();
        await rename(downloaded, destination);
        promoted = true;
        signal?.throwIfAborted();
        return;
      }
    } catch (error) {
      if (promoted) await rm(destination, { force: true });
      throw error;
    } finally {
      await rm(staging, { recursive: true, force: true });
    }
    const reason = result.timedOut ? "download timed out" : result.stderr.trim() || `gh exited ${result.code}`;
    if (attempt === MAX_ATTEMPTS || !isTransient(result)) {
      throw new Error(`Sparkle baseline ${tag}/${name} failed after ${attempt} attempt(s): ${reason}`);
    }
    log(`Retrying Sparkle baseline ${tag}/${name} (${attempt}/${MAX_ATTEMPTS}): ${reason}`);
    await sleep(RETRY_DELAY_MS * (2 ** (attempt - 1)));
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const cancellation = new AbortController();
  const cancel = (signal) => cancellation.abort(new Error(`Baseline download cancelled by ${signal}`));
  const interrupt = () => cancel("SIGINT");
  const terminate = () => cancel("SIGTERM");
  process.once("SIGINT", interrupt);
  process.once("SIGTERM", terminate);
  try {
    const [repository, tag, name, archives] = process.argv.slice(2);
    if (!repository || !tag || !name || !archives || process.argv.length !== 6) {
      throw new Error("Usage: download-sparkle-baseline.mjs <repository> <tag> <archive> <archives-directory>");
    }
    await downloadSparkleBaseline({ repository, tag, name, archives }, { signal: cancellation.signal });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", terminate);
  }
}
