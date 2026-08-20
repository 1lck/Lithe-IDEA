import { describe, expect, test } from "bun:test";
import {
  openNewTerminalFromGlobalEntry,
  shouldAutoHideTerminalPane,
} from "./terminal-pane-visibility";

describe("terminal pane auto-hide", () => {
  test("hides the visible terminal pane after its last terminal closes", () => {
    expect(
      shouldAutoHideTerminalPane({
        bottomPaneActiveTab: "terminal",
        isBottomPaneVisible: true,
        previousTerminalCount: 1,
        terminalCount: 0,
      }),
    ).toBe(true);
  });

  test("keeps an already-empty terminal pane open so a new terminal can be created", () => {
    expect(
      shouldAutoHideTerminalPane({
        bottomPaneActiveTab: "terminal",
        isBottomPaneVisible: true,
        previousTerminalCount: 0,
        terminalCount: 0,
      }),
    ).toBe(false);
  });

  test("does not hide a terminal pane that is already hidden", () => {
    expect(
      shouldAutoHideTerminalPane({
        bottomPaneActiveTab: "terminal",
        isBottomPaneVisible: false,
        previousTerminalCount: 1,
        terminalCount: 0,
      }),
    ).toBe(false);
  });

  test("does not hide another active bottom tool window when terminals close", () => {
    for (const bottomPaneActiveTab of ["run", "gitLog", "debugger", "buffers"]) {
      expect(
        shouldAutoHideTerminalPane({
          bottomPaneActiveTab,
          isBottomPaneVisible: true,
          previousTerminalCount: 1,
          terminalCount: 0,
        }),
      ).toBe(false);
    }
  });

  test("keeps the terminal pane visible while another terminal remains", () => {
    expect(
      shouldAutoHideTerminalPane({
        bottomPaneActiveTab: "terminal",
        isBottomPaneVisible: true,
        previousTerminalCount: 2,
        terminalCount: 1,
      }),
    ).toBe(false);
  });

  test("global new-terminal entry shows the terminal pane and creates exactly one terminal", () => {
    const calls: string[] = [];

    openNewTerminalFromGlobalEntry({
      createTerminal: () => calls.push("create"),
      setBottomPaneActiveTab: (tab) => calls.push(`tab:${tab}`),
      setIsBottomPaneVisible: (visible) => calls.push(`visible:${visible}`),
    });

    expect(calls).toEqual(["tab:terminal", "visible:true", "create"]);
  });
});
