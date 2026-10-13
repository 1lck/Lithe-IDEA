import { describe, expect, test } from "bun:test";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runProcess } from "../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";

const scripts = path.dirname(fileURLToPath(import.meta.url));
const dependencyPaths = ["node_modules", "windows/tauri/node_modules", "frontend/editor/node_modules"];

// A real child process keeps its current directory locked on Windows. IPC
// confirms that lock before the fake installer exits, without sleeps or polling.
const fakeBun = String.raw`
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const net = require("node:net");
const root = process.env.LITHE_INSTALL_FIXTURE_ROOT;
if (process.argv.includes("--locker")) {
  const server = net.createServer();
  server.listen(0, "127.0.0.1", () => process.send("locked"));
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

function isRunning(pid: number) {
  try { process.kill(pid, 0); return true; } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

async function ownedPids(root: string) {
  try {
    return (await fs.readFile(path.join(root, "owned-pids"), "utf8")).trim().split(/\s+/).map(Number);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}

async function withInstaller(mode: string, check: (root: string, result: Awaited<ReturnType<typeof runProcess>>) => Promise<void>, timeoutSeconds = 300) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "lithe Windows install "));
  try {
    await fs.mkdir(path.join(root, "scripts"));
    await fs.mkdir(path.join(root, "windows/tauri"), { recursive: true });
    await fs.mkdir(path.join(root, "bin"));
    await fs.mkdir(path.join(root, ".artifacts/bun-cache"), { recursive: true });
    for (const name of ["install-windows-frontend-dependencies.ps1", "invoke-windows-bun-install.ps1"]) {
      await fs.copyFile(path.join(scripts, name), path.join(root, "scripts", name));
    }
    await fs.writeFile(path.join(root, "windows/tauri/package.json"), JSON.stringify({ packageManager: "bun@1.3.12" }));
    await fs.writeFile(path.join(root, ".artifacts/bun-cache/.lithe-integrity.json"), "old manifest");
    await fs.writeFile(path.join(root, ".artifacts/bun-cache/old-cache"), "old");
    await fs.writeFile(path.join(root, "bin/fake-bun.cjs"), fakeBun);
    await fs.writeFile(path.join(root, "bin/bun.cmd"), '@echo off\r\nnode "%~dp0fake-bun.cjs" %*\r\n');
    // Cache validation is covered separately; here the sealer records whether
    // the fallback invalidated its verified flag and allowed a new manifest.
    await fs.writeFile(path.join(root, "scripts/verify-download-cache.mjs"), `
      import { writeFileSync } from "node:fs";
      import path from "node:path";
      const root = process.env.LITHE_INSTALL_FIXTURE_ROOT;
      writeFileSync(path.join(root, "sealed-state"), process.env.LITHE_BUN_CACHE_VERIFIED);
      writeFileSync(path.join(root, ".artifacts/bun-cache/.lithe-integrity.json"), "new manifest");
    `);
    const result = await runProcess({
      command: "pwsh",
      args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(root, "scripts/install-windows-frontend-dependencies.ps1"),
             "-InstallTimeoutSeconds", String(timeoutSeconds)],
      cwd: root,
      env: {
        ...process.env,
        PATH: path.join(root, "bin") + path.delimiter + process.env.PATH,
        LITHE_INSTALL_FIXTURE_ROOT: root,
        LITHE_INSTALL_FIXTURE_MODE: mode,
        LITHE_BUN_CACHE_VERIFIED: "true",
        GITHUB_ACTIONS: "false",
        GITHUB_ENV: "",
      },
      timeoutMs: 20000,
    });
    expect(result.timedOut, result.stdout + result.stderr).toBe(false);
    await check(root, result);
    expect((await ownedPids(root)).filter(isRunning)).toEqual([]);
  } finally {
    // Cleanup remains owned even if a worker or assertion fails.
    for (const pid of await ownedPids(root)) {
      if (isRunning(pid)) {
        await runProcess({ command: "taskkill.exe", args: ["/PID", String(pid), "/T", "/F"], timeoutMs: 5000 });
      }
    }
    await fs.rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
}

describe.skipIf(process.platform !== "win32")("Windows dependency install lifecycle", () => {
  test("failed installation releases locked descendants before its clean retry", async () => {
    await withInstaller("recover", async (root, result) => {
      expect(result.code, result.stdout + result.stderr).toBe(0);
      const attempts = (await fs.readFile(path.join(root, "attempts.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
      expect(attempts).toEqual([["install", "--frozen-lockfile"], ["install", "--frozen-lockfile", "--no-cache"]]);
      expect(await fs.readFile(path.join(root, "retry-succeeded"), "utf8")).toBe("yes");
      expect(await fs.readFile(path.join(root, "sealed-state"), "utf8")).toBe("false");
      for (const directory of dependencyPaths) expect(await fs.readdir(path.join(root, directory))).toEqual([]);
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
      expect(await fs.readFile(path.join(root, ".artifacts/bun-cache/old-cache"), "utf8")).toBe("old");
      expect((await ownedPids(root)).length).toBe(1);
      const attempts = (await fs.readFile(path.join(root, "attempts.jsonl"), "utf8")).trim().split("\n");
      expect(attempts.length).toBe(1);
    });
  });

  test("a stalled installer reaches its local deadline and releases its descendants", async () => {
    await withInstaller("timeout", async (root, result) => {
      expect(result.code).not.toBe(0);
      expect(result.stderr).toContain("exceeded its 3 second deadline");
      expect(result.stderr).toContain("failed after a clean retry");
      expect((await ownedPids(root)).length).toBe(2);
    }, 3);
  });
});
