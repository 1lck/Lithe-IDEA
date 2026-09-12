import { describe, expect, mock, test } from "bun:test";
import {
  copyTerminalSelection,
  hasTerminalSelection,
  pasteTerminalText,
} from "./terminal-clipboard";

describe("terminal clipboard actions", () => {
  test("disables copying and does not touch the clipboard without a selection", async () => {
    const writeText = mock(async (_text: string) => {});
    const terminal = { getSelection: () => "" };

    expect(hasTerminalSelection(terminal)).toBe(false);
    expect(await copyTerminalSelection(terminal, writeText)).toBe(false);
    expect(writeText).not.toHaveBeenCalled();
  });

  test("copies the current terminal selection", async () => {
    const writeText = mock(async (_text: string) => {});
    const terminal = { getSelection: () => "selected output" };

    expect(hasTerminalSelection(terminal)).toBe(true);
    expect(await copyTerminalSelection(terminal, writeText)).toBe(true);
    expect(writeText).toHaveBeenCalledWith("selected output");
  });

  test("pastes connected single-line text without prompting", async () => {
    const paste = mock((_text: string) => {});
    const confirmPaste = mock(async (_lineCount: number) => true);

    expect(
      await pasteTerminalText({
        terminal: { paste },
        text: "echo ready",
        isConnected: () => true,
        confirmPaste,
      }),
    ).toBe(true);
    expect(confirmPaste).not.toHaveBeenCalled();
    expect(paste).toHaveBeenCalledWith("echo ready");
  });

  test("requires confirmation before pasting five lines", async () => {
    const paste = mock((_text: string) => {});
    const confirmPaste = mock(async (_lineCount: number) => false);

    expect(
      await pasteTerminalText({
        terminal: { paste },
        text: "one\ntwo\nthree\nfour\nfive",
        isConnected: () => true,
        confirmPaste,
      }),
    ).toBe(false);
    expect(confirmPaste).toHaveBeenCalledWith(5);
    expect(paste).not.toHaveBeenCalled();
  });

  test("does not paste after the terminal disconnects during confirmation", async () => {
    const paste = mock((_text: string) => {});
    let connected = true;

    expect(
      await pasteTerminalText({
        terminal: { paste },
        text: "one\ntwo\nthree\nfour\nfive",
        isConnected: () => connected,
        confirmPaste: async () => {
          connected = false;
          return true;
        },
      }),
    ).toBe(false);
    expect(paste).not.toHaveBeenCalled();
  });
});
