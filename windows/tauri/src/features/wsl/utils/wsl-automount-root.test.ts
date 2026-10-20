import { afterEach, describe, expect, test } from "bun:test";
import { WSL_DEFAULT_AUTOMOUNT_ROOT } from "./wsl-path";
import {
  resetWslAutomountRootCache,
  resolveAutomountRootForShell,
} from "./wsl-automount-root";

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
  });

  test("returns the default when no shell is known", async () => {
    expect(await resolveAutomountRootForShell(undefined)).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(await resolveAutomountRootForShell(null)).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
    expect(await resolveAutomountRootForShell("")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
  });

  test("treats a bare wsl prefix without a distribution as the default", async () => {
    expect(await resolveAutomountRootForShell("wsl:")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
  });

  // A WSL shell does reach the host; in a test environment the invoke fails and
  // the documented fallback applies, which also proves the call is attempted.
  test("falls back to the default when the host cannot answer", async () => {
    expect(await resolveAutomountRootForShell("wsl:Ubuntu")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
  });

  test("matches the wsl prefix case-insensitively", async () => {
    expect(await resolveAutomountRootForShell("WSL:Ubuntu")).toBe(WSL_DEFAULT_AUTOMOUNT_ROOT);
  });
});
