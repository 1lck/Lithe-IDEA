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

  // IDEA and Windows Terminal both bind plain Ctrl+C to copy when text is
  // selected. Lithe only had Ctrl+Shift+C, so a copied selection required the
  // extra modifier that the reference IDEs do not ask for.
  test("copies with plain Ctrl+C when text is selected", () => {
    expect(
      getTerminalKeyAction(
        {
          type: "keydown",
          key: "c",
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
        },
        "windows",
        { hasSelection: true },
      ),
    ).toEqual({ type: "copy" });
  });

  // The interrupt must survive: without a selection Ctrl+C has to reach the
  // program as SIGINT so a running command can still be stopped.
  test("leaves Ctrl+C to the program when nothing is selected", () => {
    const ctrlC = {
      type: "keydown" as const,
      key: "c",
      ctrlKey: true,
      shiftKey: false,
      altKey: false,
      metaKey: false,
    };

    expect(getTerminalKeyAction(ctrlC, "windows", { hasSelection: false })).toEqual({
      type: "passthrough",
    });
    expect(getTerminalKeyAction(ctrlC, "windows")).toEqual({ type: "passthrough" });
  });

  test("keeps Ctrl+Shift+C working with no selection", () => {
    expect(
      getTerminalKeyAction(
        {
          type: "keydown",
          key: "c",
          ctrlKey: true,
          shiftKey: true,
          altKey: false,
          metaKey: false,
        },
        "windows",
        { hasSelection: false },
      ),
    ).toEqual({ type: "copy" });
  });

  // macOS keeps Cmd+C for the system; the plain Ctrl+C binding is Windows-only.
  test("does not intercept plain Ctrl+C on macOS", () => {
    expect(
      getTerminalKeyAction(
        {
          type: "keydown",
          key: "c",
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
        },
        "macos",
        { hasSelection: true },
      ),
    ).toEqual({ type: "passthrough" });
  });
});
