import { describe, expect, test } from "bun:test";
import { getAllTerminalProfiles, resolveTerminalLaunch } from "./terminal-profiles";
import type { Shell } from "../types/terminal.types";

const shells: Shell[] = [
  { id: "bash", name: "Git Bash" },
  { id: "pwsh", name: "PowerShell Core" },
  { id: "wsl:Ubuntu", name: "WSL: Ubuntu" },
];

describe("terminal profile selection", () => {
  test("each detected shell creates a distinct profile and overrides the default for the new session", () => {
    const settings = { terminalDefaultProfileId: "shell:bash", terminalDefaultShellId: "bash" };
    expect(getAllTerminalProfiles(shells, []).map((profile) => profile.id)).toEqual([
      "system-default",
      "shell:bash",
      "shell:pwsh",
      "shell:wsl:Ubuntu",
    ]);
    const launch = resolveTerminalLaunch({
      currentDirectory: "C:\\workspace",
      customProfiles: [],
      explicitProfileId: "shell:wsl:Ubuntu",
      settings,
      shells,
    });
    expect(launch.shell).toBe("wsl:Ubuntu");
    expect(launch.workingDirectory).toBe("C:\\workspace");
    expect(settings.terminalDefaultProfileId).toBe("shell:bash");
  });

  test("a temporarily missing selected shell keeps its identity for a native launch error", () => {
    const launch = resolveTerminalLaunch({
      currentDirectory: "C:\\workspace",
      customProfiles: [],
      settings: { terminalDefaultProfileId: "shell:pwsh", terminalDefaultShellId: "cmd" },
      shells: [],
    });
    expect(launch.shell).toBe("pwsh");
    expect(launch.profileId).toBe("shell:pwsh");
  });
});
