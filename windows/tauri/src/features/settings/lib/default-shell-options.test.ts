import { describe, expect, test } from "bun:test";
import type { Shell } from "@/features/terminal/types/terminal.types";
import { SYSTEM_DEFAULT_SHELL_VALUE, getDefaultShellOptions } from "./default-shell-options";

const shells: Shell[] = [
  { id: "cmd", name: "Command Prompt" },
  { id: "pwsh", name: "PowerShell Core" },
  { id: "bash", name: "Git Bash" },
  { id: "wsl:Ubuntu", name: "WSL: Ubuntu", kind: "wsl", wsl_distribution: "Ubuntu" },
];

describe("default shell options", () => {
  test("offers the system default followed by every discovered shell in discovery order", () => {
    expect(getDefaultShellOptions({ shells, selectedShellId: "bash", hasLoaded: true })).toEqual([
      { value: SYSTEM_DEFAULT_SHELL_VALUE, isAvailable: true },
      { value: "cmd", shellName: "Command Prompt", isAvailable: true },
      { value: "pwsh", shellName: "PowerShell Core", isAvailable: true },
      { value: "bash", shellName: "Git Bash", isAvailable: true },
      { value: "wsl:Ubuntu", shellName: "WSL: Ubuntu", isAvailable: true },
    ]);
  });

  test("keeps a saved shell that discovery no longer reports and marks it unavailable", () => {
    // The previous hardcoded panel stored a bare "wsl" id that never matches a distribution.
    const options = getDefaultShellOptions({ shells, selectedShellId: "wsl", hasLoaded: true });

    expect(options[options.length - 1]).toEqual({ value: "wsl", isAvailable: false });
  });

  test("does not flag a saved shell as unavailable before discovery has finished", () => {
    const options = getDefaultShellOptions({
      shells: [],
      selectedShellId: "bash",
      hasLoaded: false,
    });

    expect(options).toEqual([
      { value: SYSTEM_DEFAULT_SHELL_VALUE, isAvailable: true },
      { value: "bash", isAvailable: true },
    ]);
  });
});
