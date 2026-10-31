import { afterAll, describe, expect, test } from "bun:test";
import { dlopen, FFIType, ptr, type Pointer } from "bun:ffi";
import { randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { runProcess } from "../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";

const scripts = path.dirname(fileURLToPath(import.meta.url));
const dependencyPaths = [
  "node_modules",
  "windows/tauri/node_modules",
  "frontend/editor/node_modules",
];
const kernel =
  process.platform === "win32"
    ? dlopen("kernel32.dll", {
        OpenProcess: { args: [FFIType.u32, FFIType.bool, FFIType.u32], returns: FFIType.ptr },
        GetProcessTimes: {
          args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
          returns: FFIType.bool,
        },
        WaitForSingleObject: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
        TerminateProcess: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.bool },
        CloseHandle: { args: [FFIType.ptr], returns: FFIType.bool },
        GetLastError: { args: [], returns: FFIType.u32 },
      })
    : undefined;
afterAll(() => kernel?.close());
type OwnedProcess = { pid: number; handle: Pointer; creationFileTime: string };

// Wait off the test event loop on retained kernel handles, never a PID looked up
// after worker exit. The test thread alone owns and closes these handles.
const processWaiter = String.raw`
const { parentPort, workerData } = require("node:worker_threads");
const { dlopen, FFIType } = require("bun:ffi");
const kernel = dlopen("kernel32.dll", {
  WaitForSingleObject: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
});
try {
  const deadline = performance.now() + workerData.timeoutMs;
  const states = workerData.handles.map(handle =>
    kernel.symbols.WaitForSingleObject(handle, Math.max(0, Math.ceil(deadline - performance.now()))));
  parentPort.postMessage(states);
} finally {
  kernel.close();
  parentPort.close();
}
`;

// A real child process keeps its current directory locked on Windows. IPC
// confirms that lock before the fake installer exits, without sleeps or polling.
const fakeBun = String.raw`
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const net = require("node:net");
const root = process.env.LITHE_INSTALL_FIXTURE_ROOT;
const record = event => fs.appendFileSync(path.join(root, "events.jsonl"), JSON.stringify({ event, args: process.argv.slice(2) }) + "\n");
record("started");
if (process.argv.includes("--locker")) {
  const server = net.createServer();
  server.listen(0, "127.0.0.1", () => {
    const ownership = net.connect(Number(process.env.LITHE_INSTALL_OWNER_PORT), "127.0.0.1");
    // test-stability: allow(typescript-real-timer) reason: Real child TCP ownership ACK needs a bounded OS watchdog before the parent may exit.
    ownership.setTimeout(5000, () => { throw Error("Locker ownership handshake timed out"); });
    ownership.once("error", error => { throw error; });
    ownership.once("connect", () => ownership.write(JSON.stringify({
      pid: process.pid, token: process.env.LITHE_INSTALL_OWNER_TOKEN
    }) + "\n"));
    let acknowledgement = "";
    ownership.on("data", chunk => {
      acknowledgement += chunk;
      if (acknowledgement.length > 16) throw Error("Invalid ownership acknowledgement");
      if (!acknowledgement.endsWith("\n")) return;
      if (acknowledgement !== "owned\n") throw Error("Locker ownership was not acknowledged");
      ownership.removeAllListeners("data");
      ownership.end();
      record("locked");
      process.send("locked");
    });
  });
} else if (process.argv.includes("--version")) {
  console.log("1.3.12");
} else {
  const retry = process.argv.includes("--no-cache");
  const mode = process.env.LITHE_INSTALL_FIXTURE_MODE;
  fs.appendFileSync(path.join(root, "attempts.jsonl"), JSON.stringify(process.argv.slice(2)) + "\n");
  const directories = ["node_modules", "windows/tauri/node_modules", "frontend/editor/node_modules"];
  if (retry && mode !== "permanent-failure" && mode !== "timeout") {
    for (const directory of directories) {
      if (fs.existsSync(path.join(root, directory, "partial"))) throw Error("Partial dependencies survived cleanup");
      fs.mkdirSync(path.join(root, directory), { recursive: true });
    }
    fs.writeFileSync(path.join(root, "retry-succeeded"), "yes");
  } else {
    for (const directory of directories) {
      fs.mkdirSync(path.join(root, directory, "partial"), { recursive: true });
    }
    const locked = path.join(root, "node_modules", "partial");
    const child = spawn(process.execPath, [__filename, "--locker"], {
      cwd: locked, stdio: ["ignore", "ignore", "ignore", "ipc"]
    });
    child.once("error", error => { throw error; });
    child.once("message", () => {
      fs.appendFileSync(path.join(root, "owned-pids"), child.pid + "\n");
      if (mode !== "timeout") process.exit(mode === "success-with-child" ? 0 : 1);
    });
  }
}
`;

async function ownedPids(root: string) {
  try {
    return (await fs.readFile(path.join(root, "owned-pids"), "utf8"))
      .trim()
      .split(/\s+/)
      .map(Number);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}

// These native integration cases start PowerShell workers and compile the Job
// Object helper. Bound each fake install independently, then leave startup and
// process-tree cleanup headroom below the lane's 60 second per-case budget.
const fixtureInstallTimeoutSeconds = 5;
const fixtureProcessTimeoutMs = 45000;

async function waitForOwnedProcesses(root: string, owned: OwnedProcess[]) {
  if (owned.length === 0) return;
  const states = await new Promise<number[]>((resolve, reject) => {
    const worker = new Worker(path.join(root, "bin/process-waiter.cjs"), {
      workerData: { handles: owned.map((process) => process.handle), timeoutMs: 5000 },
    });
    let result: number[] | undefined;
    let failure: Error | undefined;
    // test-stability: allow(typescript-real-timer) reason: Bound the real native handle waiter; shared handles remain owned until its worker thread exits.
    const timer = setTimeout(() => {
      failure = new Error("Native process-handle waiter exceeded its 7 second deadline");
      // terminate() completes after the native wait thread exits. Never let the
      // owner close shared handles while this thread could still be using them.
      void worker.terminate().then(() => reject(failure), reject);
    }, 7000);
    worker.once("message", (states) => {
      result = states;
    });
    worker.once("error", (error) => {
      failure = error;
    });
    worker.once("exit", (code) => {
      clearTimeout(timer);
      if (failure) reject(failure);
      else if (code !== 0 || !result)
        reject(new Error(`Native process-handle waiter exited ${code} without results`));
      else resolve(result);
    });
  });
  const receipts = owned.map(({ pid, creationFileTime }, index) => ({
    pid,
    creationFileTime,
    waitStatus: states[index],
  }));
  await fs.appendFile(path.join(root, "process-identity.jsonl"), JSON.stringify(receipts) + "\n");
  if (states.some((state) => state !== 0)) {
    throw new Error(
      `Original installer descendants did not exit within the shared 5 second deadline: ${JSON.stringify(receipts)}\n${await installerDiagnostics(root)}`,
    );
  }
}

async function installerDiagnostics(root: string) {
  const files = [
    "events.jsonl",
    "attempts.jsonl",
    "owned-pids",
    "process-identity.jsonl",
    "retry-succeeded",
    "sealed-state",
  ];
  return (
    await Promise.all(
      files.map(async (name) => {
        try {
          return `${name}:\n${await fs.readFile(path.join(root, name), "utf8")}`;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === "ENOENT") return `${name}: not reached`;
          throw error;
        }
      }),
    )
  ).join("\n");
}

async function withInstaller(
  mode: string,
  check: (root: string, result: Awaited<ReturnType<typeof runProcess>>) => Promise<void>,
  timeoutSeconds = fixtureInstallTimeoutSeconds,
) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "lithe Windows install "));
  const owned: OwnedProcess[] = [];
  const sockets = new Set<net.Socket>();
  const ownershipErrors: string[] = [];
  const ownerToken = randomUUID();
  let primaryError: unknown;
  const owner = net.createServer((socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    socket.on("error", (error) => ownershipErrors.push(String(error)));
    // test-stability: allow(typescript-real-timer) reason: Bound the real child process ownership socket; timeout destroys that socket and teardown reclaims captured handles.
    socket.setTimeout(5000, () => socket.destroy(new Error("Process ownership request timed out")));
    let message = "";
    socket.on("data", (chunk) => {
      message += chunk;
      if (message.length > 1024) {
        socket.destroy(new Error("Process ownership request too large"));
        return;
      }
      if (!message.endsWith("\n")) return;
      try {
        const { pid, token } = JSON.parse(message);
        if (
          token !== ownerToken ||
          !Number.isInteger(pid) ||
          pid <= 0 ||
          owned.some((process) => process.pid === pid)
        )
          throw new Error("Invalid process ownership request");
        // SYNCHRONIZE, QUERY_LIMITED_INFORMATION and TERMINATE only. Acquire
        // while the locker waits for ACK, before its parent can exit the Job.
        const handle = kernel!.symbols.OpenProcess(0x100000 | 0x1000 | 0x1, false, pid);
        if (!handle) throw new Error(`OpenProcess failed: ${kernel!.symbols.GetLastError()}`);
        try {
          const times = Array.from({ length: 4 }, () => new BigUint64Array(1));
          if (
            !kernel!.symbols.GetProcessTimes(
              handle,
              ptr(times[0]),
              ptr(times[1]),
              ptr(times[2]),
              ptr(times[3]),
            )
          )
            throw new Error(`GetProcessTimes failed: ${kernel!.symbols.GetLastError()}`);
          if (kernel!.symbols.WaitForSingleObject(handle, 0) !== 258)
            throw new Error("Locker exited before ownership acknowledgement");
          owned.push({ pid, handle, creationFileTime: String(times[0][0]) });
        } catch (error) {
          kernel!.symbols.CloseHandle(handle);
          throw error;
        }
        socket.end("owned\n");
      } catch (error) {
        ownershipErrors.push(String(error));
        socket.destroy();
      }
    });
  });
  try {
    await new Promise<void>((resolve, reject) => {
      // test-stability: allow(typescript-real-timer) reason: Real loopback listen completion needs a local deadline; failure still closes this invocation-owned server.
      const timer = setTimeout(
        () => reject(new Error("Ownership server startup exceeded 5 seconds")),
        5000,
      );
      owner.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
      owner.listen(0, "127.0.0.1", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    await fs.mkdir(path.join(root, "scripts/windows/build"), { recursive: true });
    await fs.mkdir(path.join(root, "scripts/resources"), { recursive: true });
    await fs.mkdir(path.join(root, "windows/tauri"), { recursive: true });
    await fs.mkdir(path.join(root, "bin"));
    await fs.mkdir(path.join(root, ".artifacts/bun-cache"), { recursive: true });
    for (const name of [
      "install-windows-frontend-dependencies.ps1",
      "invoke-windows-bun-install.ps1",
      "windows-tree-sitter-proxy.cjs",
    ]) {
      await fs.copyFile(path.join(scripts, name), path.join(root, "scripts/windows/build", name));
    }
    await fs.writeFile(
      path.join(root, "windows/tauri/package.json"),
      JSON.stringify({ packageManager: "bun@1.3.12" }),
    );
    await fs.writeFile(
      path.join(root, ".artifacts/bun-cache/.lithe-integrity.json"),
      "old manifest",
    );
    await fs.writeFile(path.join(root, ".artifacts/bun-cache/old-cache"), "old");
    await fs.writeFile(path.join(root, "bin/fake-bun.cjs"), fakeBun);
    await fs.writeFile(path.join(root, "bin/process-waiter.cjs"), processWaiter);
    await fs.writeFile(
      path.join(root, "bin/bun.cmd"),
      '@echo off\r\nnode "%~dp0fake-bun.cjs" %*\r\n',
    );
    // Cache validation is covered separately; here the sealer records whether
    // the fallback invalidated its verified flag and allowed a new manifest.
    await fs.writeFile(
      path.join(root, "scripts/resources/verify-download-cache.mjs"),
      `
      import { writeFileSync } from "node:fs";
      import path from "node:path";
      const root = process.env.LITHE_INSTALL_FIXTURE_ROOT;
      writeFileSync(path.join(root, "sealed-state"), process.env.LITHE_BUN_CACHE_VERIFIED);
      writeFileSync(path.join(root, ".artifacts/bun-cache/.lithe-integrity.json"), "new manifest");
    `,
    );
    const result = await runProcess({
      command: "pwsh",
      args: [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        path.join(root, "scripts/windows/build/install-windows-frontend-dependencies.ps1"),
        "-InstallTimeoutSeconds",
        String(timeoutSeconds),
      ],
      cwd: root,
      env: {
        ...process.env,
        PATH: path.join(root, "bin") + path.delimiter + process.env.PATH,
        LITHE_INSTALL_FIXTURE_ROOT: root,
        LITHE_INSTALL_FIXTURE_MODE: mode,
        LITHE_INSTALL_OWNER_PORT: String((owner.address() as net.AddressInfo).port),
        LITHE_INSTALL_OWNER_TOKEN: ownerToken,
        LITHE_BUN_CACHE_VERIFIED: "true",
        GITHUB_ACTIONS: "false",
        GITHUB_ENV: "",
      },
      timeoutMs: fixtureProcessTimeoutMs,
    });
    if (result.timedOut || !result.terminationConfirmed) {
      throw new Error(
        `Windows install fixture (${mode}): duration=${Math.round(result.durationMs)}ms, outerDeadline=${fixtureProcessTimeoutMs}ms, installDeadline=${timeoutSeconds}s, timedOut=${result.timedOut}, terminationConfirmed=${result.terminationConfirmed}\n${await installerDiagnostics(root)}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
      );
    }
    expect(ownershipErrors).toEqual([]);
    await check(root, result);
    expect(owned.map((process) => process.pid)).toEqual(await ownedPids(root));
    await waitForOwnedProcesses(root, owned);
  } catch (error) {
    primaryError = error;
  }
  // Even failed assertions clean only the exact originally retained objects.
  // Preserve the original failure and keep cleaning the remaining resources if
  // an individual native operation fails.
  const cleanupErrors: unknown[] = [];
  const forced: number[] = [];
  for (const process of owned) {
    const state = kernel!.symbols.WaitForSingleObject(process.handle, 0);
    if (state === 258) {
      forced.push(process.pid);
      if (
        !kernel!.symbols.TerminateProcess(process.handle, 1) &&
        kernel!.symbols.WaitForSingleObject(process.handle, 0) !== 0
      ) {
        cleanupErrors.push(
          new Error(
            `TerminateProcess failed for captured identity: ${kernel!.symbols.GetLastError()}`,
          ),
        );
      }
    } else if (state !== 0) {
      cleanupErrors.push(new Error(`WaitForSingleObject failed for captured identity: ${state}`));
    }
  }
  try {
    await waitForOwnedProcesses(root, owned);
  } catch (error) {
    cleanupErrors.push(error);
  }
  const receipts = owned.map(({ pid, handle, creationFileTime }) => ({
    pid,
    creationFileTime,
    waitStatus: kernel!.symbols.WaitForSingleObject(handle, 0),
  }));
  for (const process of owned) {
    if (!kernel!.symbols.CloseHandle(process.handle))
      cleanupErrors.push(new Error(`CloseHandle failed: ${kernel!.symbols.GetLastError()}`));
  }
  for (const socket of sockets) socket.destroy();
  try {
    await new Promise<void>((resolve, reject) => {
      // test-stability: allow(typescript-real-timer) reason: Bound real socket/server shutdown after all owned sockets were destroyed; no simulated clock can prove OS release.
      const timer = setTimeout(
        () => reject(new Error("Ownership server cleanup exceeded 5 seconds")),
        5000,
      );
      owner.close(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    await fs.rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  } catch (error) {
    cleanupErrors.push(error);
  }
  console.log(
    `Installer identity cleanup: ${JSON.stringify({ mode, forced, processes: receipts, serverListening: owner.listening, sockets: sockets.size, cleanupErrors: cleanupErrors.map(String) })}`,
  );
  if (cleanupErrors.length)
    throw new AggregateError(
      [...(primaryError ? [primaryError] : []), ...cleanupErrors],
      "Installer fixture or cleanup failed",
    );
  if (primaryError) throw primaryError;
}

describe.skipIf(process.platform !== "win32")("Windows dependency install lifecycle", () => {
  test("failed installation releases locked descendants before its clean retry", async () => {
    await withInstaller("recover", async (root, result) => {
      expect(result.code, result.stdout + result.stderr).toBe(0);
      const attempts = (await fs.readFile(path.join(root, "attempts.jsonl"), "utf8"))
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      expect(attempts).toEqual([
        ["install", "--frozen-lockfile"],
        ["install", "--frozen-lockfile", "--no-cache"],
      ]);
      expect(await fs.readFile(path.join(root, "retry-succeeded"), "utf8")).toBe("yes");
      expect(await fs.readFile(path.join(root, "sealed-state"), "utf8")).toBe("false");
      for (const directory of dependencyPaths)
        expect(await fs.readdir(path.join(root, directory))).toEqual([]);
      expect((await ownedPids(root)).length).toBe(1);
    });
  });

  test("permanent failure reports the retry error and releases both process trees", async () => {
    await withInstaller("permanent-failure", async (root, result) => {
      expect(result.code).not.toBe(0);
      expect(result.stderr).toContain("failed after a clean retry");
      expect((await ownedPids(root)).length).toBe(2);
    });
  });

  test("successful installation releases leftover children without clearing a valid cache", async () => {
    await withInstaller("success-with-child", async (root, result) => {
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(await fs.readFile(path.join(root, ".artifacts/bun-cache/old-cache"), "utf8")).toBe(
        "old",
      );
      expect((await ownedPids(root)).length).toBe(1);
      const attempts = (await fs.readFile(path.join(root, "attempts.jsonl"), "utf8"))
        .trim()
        .split("\n");
      expect(attempts.length).toBe(1);
    });
  });

  test("a stalled installer reaches its local deadline and releases its descendants", async () => {
    await withInstaller(
      "timeout",
      async (root, result) => {
        expect(result.code).not.toBe(0);
        expect(result.stderr).toContain("exceeded its 3 second deadline");
        expect(result.stderr).toContain("failed after a clean retry");
        expect((await ownedPids(root)).length).toBe(2);
      },
      3,
    );
  });
});
