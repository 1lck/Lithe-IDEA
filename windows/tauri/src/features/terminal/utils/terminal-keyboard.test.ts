import { describe, expect, test } from "bun:test";
import { getTerminalKeyAction } from "./terminal-keyboard";

describe("terminal keyboard actions", () => {
  test("routes Windows Ctrl+V to clipboard paste instead of the PTY", () => {
    expect(
      getTerminalKeyAction(
        {
          type: "keydown",
          key: "v",
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
        },
        "windows",
      ),
    ).toEqual({ type: "paste" });
  });

  test("keeps macOS Ctrl+V available to the terminal", () => {
    expect(
      getTerminalKeyAction(
        {
          type: "keydown",
          key: "v",
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
        },
        "macos",
      ),
    ).toEqual({ type: "passthrough" });
  });
});
