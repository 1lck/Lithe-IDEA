import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { WSL_DEFAULT_AUTOMOUNT_ROOT } from "./wsl-path";

/**
 * Host stub for `wsl_automount_root`.
 *
 * `answer` decides what each call does, so a test can make the read resolve, fail
 * or never settle without a real UNC path.
 */
let answer: (distro: string) => Promise<string> = async () => WSL_DEFAULT_AUTOMOUNT_ROOT;
const invoke = mock(async (command: string, args?: unknown): Promise<unknown> => {
  if (command !== "wsl_automount_root") throw new Error(`Unexpected command: ${command}`);
  const { distro } = args as { distro: string };
  return answer(distro);
});

// Spread the real module so the override stays scoped to `invoke`; a partial mock
// would strip the sibling exports from this shared module registry.
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

const {
  automountRootNeededForPaths,
  resetWslAutomountRootCache,
  resolveAutomountRootForPaths,
  resolveAutomountRootForShell,
  resolveWslAutomountRoot,
} = await import("./wsl-automount-root");

beforeEach(() => {
  invoke.mockClear();
  resetWslAutomountRootCache();
  answer = async () => WSL_DEFAULT_AUTOMOUNT_ROOT;
});

afterEach(() => {
  resetWslAutomountRootCache();
});

// Regression: the resolver sliced a fixed four characters off every shell id, so
// `powershell` became the distribution name `rshell` and a plain PowerShell paste
// waited on an unrelated UNC read.
describe("resolveAutomountRootForShell", () => {
  test("returns the default without lookup for non-WSL shells", async () => {
    for (const shell of ["powershell", "pwsh", "cmd", "bash", "msys2", "cygwin", "nu"]) {
      expect(await resolveAutomountRootForShell(shell)).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    }
    expect(invoke.mock.calls).toEqual([]);
  });

  test("returns the default when no shell is known", async () => {
    expect(await resolveAutomountRootForShell(undefined)).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(await resolveAutomountRootForShell(null)).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(await resolveAutomountRootForShell("")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(invoke.mock.calls).toEqual([]);
  });

  test("treats a bare wsl prefix without a distribution as the default", async () => {
    expect(await resolveAutomountRootForShell("wsl:")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(invoke.mock.calls).toEqual([]);
  });

  test("asks the host for the distribution of a wsl shell", async () => {
    answer = async () => "/windrives";
    expect(await resolveAutomountRootForShell("wsl:Ubuntu")).toBe("/windrives");
    expect(invoke.mock.calls).toEqual([["wsl_automount_root", { distro: "Ubuntu" }]]);
  });

  // A WSL shell does reach the host; a failing invoke must not reject the caller.
  test("falls back to the default when the host cannot answer", async () => {
    answer = async () => {
      throw new Error("no such distribution");
    };
    expect(await resolveAutomountRootForShell("wsl:Ubuntu")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
  });

  test("matches the wsl prefix case-insensitively", async () => {
    answer = async () => "/windrives";
    expect(await resolveAutomountRootForShell("WSL:Ubuntu")).toBe("/windrives");
  });
});

// The lookup reads a UNC path, so it must only run when a Windows drive path
// actually has to be mapped, and it must never hold a paste for long.
describe("bounded automount root lookup", () => {
  test("detects the paths that need the root", () => {
    expect(automountRootNeededForPaths(["C:\\work\\a.txt"])).toBe(true);
    expect(automountRootNeededForPaths(["d:/work/a.txt"])).toBe(true);
    expect(automountRootNeededForPaths(["/home/me/a.txt"])).toBe(false);
    expect(automountRootNeededForPaths(["wsl://Ubuntu/home/me/a.txt"])).toBe(false);
    expect(automountRootNeededForPaths(["remote://box/home/me/a.txt"])).toBe(false);
    expect(automountRootNeededForPaths(["src/main.ts"])).toBe(false);
    expect(automountRootNeededForPaths([])).toBe(false);
    // Mixed paths still need it: one drive path is enough.
    expect(automountRootNeededForPaths(["/home/me", "C:\\work"])).toBe(true);
  });

  test("skips the host read for paths that do not need the root", async () => {
    expect(await resolveAutomountRootForPaths("wsl:Ubuntu", ["/home/me/a.txt"])).toBe(
      WSL_DEFAULT_AUTOMOUNT_ROOT,
    );
    expect(invoke.mock.calls).toEqual([]);
  });

  test("reads the host for a drive path in a wsl shell", async () => {
    answer = async () => "/windrives";
    expect(await resolveAutomountRootForPaths("wsl:Ubuntu", ["C:\\work\\a.txt"])).toBe(
      "/windrives",
    );
    expect(invoke.mock.calls).toEqual([["wsl_automount_root", { distro: "Ubuntu" }]]);
  });

  test("skips the host read for a drive path outside wsl", async () => {
    expect(await resolveAutomountRootForPaths("powershell", ["C:\\work\\a.txt"])).toBe(
      WSL_DEFAULT_AUTOMOUNT_ROOT,
    );
    expect(invoke.mock.calls).toEqual([]);
  });

  // A distribution that is not running can hold the UNC read for seconds. The
  // default must be used instead of blocking the paste indefinitely.
  test("falls back to the default when the host does not answer in time", async () => {
    answer = () => new Promise<string>(() => {});
    expect(await resolveWslAutomountRoot("Ubuntu", { timeoutMs: 20 })).toBe(
      WSL_DEFAULT_AUTOMOUNT_ROOT,
    );
  });

  test("does not cache the fallback from a timeout", async () => {
    answer = () => new Promise<string>(() => {});
    expect(await resolveWslAutomountRoot("Ubuntu", { timeoutMs: 20 })).toBe(
      WSL_DEFAULT_AUTOMOUNT_ROOT,
    );

    // The distribution started; the next paste must pick up the real root.
    answer = async () => "/windrives";
    expect(await resolveWslAutomountRoot("Ubuntu")).toBe("/windrives");
  });

  test("caches a successful answer", async () => {
    answer = async () => "/windrives";
    expect(await resolveWslAutomountRoot("Ubuntu")).toBe("/windrives");
    expect(await resolveWslAutomountRoot("Ubuntu")).toBe("/windrives");
    expect(invoke.mock.calls).toHaveLength(1);
  });

  test("shares one host read between concurrent callers", async () => {
    let resolveRead: ((root: string) => void) | undefined;
    answer = () =>
      new Promise<string>((resolve) => {
        resolveRead = resolve;
      });

    const first = resolveWslAutomountRoot("Ubuntu");
    const second = resolveWslAutomountRoot("Ubuntu");
    resolveRead?.("/windrives");

    expect(await first).toBe("/windrives");
    expect(await second).toBe("/windrives");
    expect(invoke.mock.calls).toHaveLength(1);
  });
});
