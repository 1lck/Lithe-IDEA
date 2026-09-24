import { describe, expect, test } from "bun:test";
import { getTerminalKeyAction } from "./terminal-keyboard";

describe("terminal keyboard actions", () => {
  test.each([
    { key: "V", type: "keydown", shiftKey: false, altKey: false, metaKey: false, action: "paste" },
    { key: "v", type: "keydown", shiftKey: true, altKey: false, metaKey: false, action: "paste" },
    { key: "c", type: "keydown", shiftKey: true, altKey: false, metaKey: false, action: "copy" },
    { key: "c", type: "keydown", shiftKey: false, altKey: false, metaKey: false, action: "passthrough" },
    { key: "v", type: "keyup", shiftKey: false, altKey: false, metaKey: false, action: "passthrough" },
    { key: "v", type: "keydown", shiftKey: false, altKey: true, metaKey: false, action: "passthrough" },
    { key: "v", type: "keydown", shiftKey: false, altKey: false, metaKey: true, action: "block" },
  ])("preserves shortcut modifiers and event phase: %j", ({ action, ...event }) => {
    expect(getTerminalKeyAction({ ...event, ctrlKey: true }, "windows")).toEqual({ type: action });
  });

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
