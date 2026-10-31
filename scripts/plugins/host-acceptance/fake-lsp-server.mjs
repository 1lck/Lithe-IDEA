#!/usr/bin/env node

import { appendFileSync, existsSync, mkdirSync, readFileSync, watch, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import path from "node:path";

const argv = process.argv.slice(2);

function argument(name, fallback = "") {
  const index = argv.indexOf(name);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
}

const stateDirectory = path.resolve(argument("--state-dir", process.cwd()));
const fixtureVersion = argument("--fixture-version", "unknown");
const childMode = argv.includes("--child");
mkdirSync(stateDirectory, { recursive: true });

function writeEvidence(kind, extra = {}) {
  const evidence = {
    kind,
    pid: process.pid,
    parentPid: process.ppid,
    fixtureVersion,
    timestamp: new Date().toISOString(),
    ...extra,
  };
  writeFileSync(
    path.join(stateDirectory, `${kind}-${fixtureVersion}-${process.pid}.json`),
    `${JSON.stringify(evidence, null, 2)}\n`,
    "utf8",
  );
}

function logEvent(event, extra = {}) {
  appendFileSync(
    path.join(stateDirectory, "events.jsonl"),
    `${JSON.stringify({ event, pid: process.pid, fixtureVersion, ...extra })}\n`,
    "utf8",
  );
}

if (childMode) {
  writeEvidence("child-active");
  logEvent("child-started");
  const interval = setInterval(() => {}, 60_000);
  const stop = (signal) => {
    clearInterval(interval);
    writeEvidence("child-stopped", { signal });
    process.exit(0);
  };
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGTERM", () => stop("SIGTERM"));
} else {
  writeEvidence("server-active");
  logEvent("server-started", { argv });

  const child = spawn(
    process.execPath,
    [
      fileURLToPath(import.meta.url),
      "--child",
      "--state-dir",
      stateDirectory,
      "--fixture-version",
      fixtureVersion,
    ],
    { stdio: "ignore", windowsHide: true },
  );
  child.unref();
  writeEvidence("child-owned", { childPid: child.pid });

  let buffer = Buffer.alloc(0);
  let shutdownRequested = false;
  let releaseInitialize = null;

  function send(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
    process.stdout.write(body);
  }

  function handle(message) {
    logEvent("message", {
      method: message.method ?? null,
      id: message.id ?? null,
      uri: message.params?.textDocument?.uri ?? null,
      documentVersion: message.params?.textDocument?.version ?? null,
    });
    if (message.method === "initialize") {
      const respond = () => send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          capabilities: {
            textDocumentSync: 1,
            hoverProvider: false,
          },
          serverInfo: { name: "lithe-plugin-host-acceptance", version: fixtureVersion },
        },
      });
      // This optional gate is disposable control state in app-data, never in
      // the signed/installed package. A real filesystem notification controls
      // the race; the deadline only fails a forgotten release.
      const gatePath = path.join(stateDirectory, "lsp-initialize-gate.json");
      let gate;
      try { gate = JSON.parse(readFileSync(gatePath, "utf8")); } catch { gate = null; }
      if (gate?.schemaVersion === 1 && /^[a-f0-9]{32}$/.test(gate.token)) {
        const token = gate.token;
        const releasePath = path.join(stateDirectory, `lsp-initialize-release-${token}`);
        if (!existsSync(releasePath)) {
          const timer = setTimeout(() => finish(4, "initialize-gate-deadline"), 15_000);
          const watcher = watch(stateDirectory, () => {
            if (releaseInitialize && existsSync(releasePath)) {
              releaseInitialize?.();
              logEvent("initialize-released", { token });
              respond();
            }
          });
          watcher.on("error", () => finish(4, "initialize-gate-watch-error"));
          releaseInitialize = () => {
            clearTimeout(timer);
            watcher.close();
            releaseInitialize = null;
          };
          logEvent("initialize-gated", { token });
          // Close the watch-registration race against an early release.
          if (existsSync(releasePath)) {
            releaseInitialize();
            logEvent("initialize-released", { token });
            respond();
          }
          return;
        }
      }
      respond();
      return;
    }
    if (message.method === "shutdown") {
      shutdownRequested = true;
      send({ jsonrpc: "2.0", id: message.id, result: null });
      return;
    }
    if (message.method === "exit") {
      finish(shutdownRequested ? 0 : 1, "lsp-exit");
      return;
    }
    if (message.id !== undefined) {
      send({ jsonrpc: "2.0", id: message.id, result: null });
    }
  }

  function drain() {
    while (true) {
      const separator = buffer.indexOf("\r\n\r\n");
      if (separator < 0) return;
      const header = buffer.subarray(0, separator).toString("ascii");
      const match = /(?:^|\r\n)Content-Length:\s*(\d+)/i.exec(header);
      if (!match) finish(2, "malformed-header");
      const length = Number.parseInt(match[1], 10);
      const frameEnd = separator + 4 + length;
      if (buffer.length < frameEnd) return;
      const body = buffer.subarray(separator + 4, frameEnd).toString("utf8");
      buffer = buffer.subarray(frameEnd);
      handle(JSON.parse(body));
    }
  }

  let finished = false;
  function finish(code, reason) {
    if (finished) return;
    finished = true;
    releaseInitialize?.();
    writeEvidence("server-stopped", { code, reason, childPid: child.pid });
    logEvent("server-stopped", { code, reason, childPid: child.pid });
    process.exit(code);
  }

  process.stdin.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    drain();
  });
  process.stdin.on("end", () => finish(0, "stdin-end"));
  process.stdin.on("error", (error) => finish(3, `stdin-error:${error.message}`));
  process.on("SIGINT", () => finish(0, "SIGINT"));
  process.on("SIGTERM", () => finish(0, "SIGTERM"));
}
