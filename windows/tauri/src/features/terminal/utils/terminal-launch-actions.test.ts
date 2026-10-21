import { afterAll, expect, mock, test } from "bun:test";
import {
  createDefaultTerminalHandler,
  createNewTerminalEventHandler,
  requestNewTerminal,
} from "./terminal-launch-actions";
import { openNewTerminalFromGlobalEntry } from "./terminal-pane-visibility";
import { resolveTerminalLaunch, type ResolvedTerminalLaunch } from "./terminal-profiles";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);

test("default terminal action does not forward a UI event as a profile ID", () => {
  const createTerminalWithProfile = mock((_profileId?: string) => {});
  const handleDefaultTerminal = createDefaultTerminalHandler(createTerminalWithProfile);

  (handleDefaultTerminal as (event: unknown) => void)({ type: "click" });

  expect(createTerminalWithProfile).toHaveBeenCalledTimes(1);
  expect(createTerminalWithProfile).toHaveBeenCalledWith();
});

// The real event boundary used by folder actions and the container must preserve
// the chosen directory while opening exactly one bottom-panel session per action.
test("folder and legacy global requests share one bottom-panel launch route", () => {
  const calls: string[] = [];
  const launches: ResolvedTerminalLaunch[] = [];
  const handler = createNewTerminalEventHandler((workingDirectoryOverride) => {
    openNewTerminalFromGlobalEntry({
      setBottomPaneActiveTab: (tab) => calls.push(`tab:${tab}`),
      setIsBottomPaneVisible: (visible) => calls.push(`visible:${visible}`),
      createTerminal: () => {
        calls.push("create");
        launches.push(
          resolveTerminalLaunch({
            currentDirectory: "C:/fixture/project",
            workingDirectoryOverride,
            customProfiles: [
              {
                id: "custom",
                name: "My shell",
                shell: "pwsh",
                startupDirectory: "C:/fixture/profile",
                startupCommands: ["echo ready"],
              },
            ],
            settings: { terminalDefaultProfileId: "custom", terminalDefaultShellId: "cmd" },
            shells: [],
          }),
        );
      },
    });
  });
  window.addEventListener("terminal-new", handler);
  try {
    requestNewTerminal("C:/fixture/project/selected folder");
    window.dispatchEvent(new window.CustomEvent("terminal-new"));
    expect(calls).toEqual([
      "tab:terminal",
      "visible:true",
      "create",
      "tab:terminal",
      "visible:true",
      "create",
    ]);
    expect(launches.map(({ workingDirectory }) => workingDirectory)).toEqual([
      "C:/fixture/project/selected folder",
      "C:/fixture/profile",
    ]);
    for (const launch of launches) {
      expect(launch.shell).toBe("pwsh");
      expect(launch.profileId).toBe("custom");
      expect(launch.initialCommand).toBe("echo ready");
    }
  } finally {
    window.removeEventListener("terminal-new", handler);
  }
});

test("a global request without a valid directory keeps default launch selection", () => {
  for (const detail of [
    undefined,
    null,
    {},
    { workingDirectory: 1 },
    { workingDirectory: "   " },
  ]) {
    const create = mock((_directory?: string) => {});
    createNewTerminalEventHandler(create)(new window.CustomEvent("terminal-new", { detail }));
    expect(create).toHaveBeenCalledTimes(1);
    expect(create).toHaveBeenCalledWith(undefined);
  }
});
