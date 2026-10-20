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

  // The kitty encoding is only meaningful to a program that asked for it. Sending
  // it unconditionally made a plain shell print the leftover `[13;2u` on the
  // command line instead of treating the key as Enter.
  test("sends the kitty encoding only while the program asked for it", () => {
    const shiftEnter = {
      type: "keydown" as const,
      key: "Enter",
      ctrlKey: false,
      shiftKey: true,
      altKey: false,
      metaKey: false,
    };

    expect(getTerminalKeyAction(shiftEnter, "windows", { extendedKeyboardActive: true })).toEqual({
      type: "write",
      data: "\u001b[13;2u",
    });
    expect(
      getTerminalKeyAction(shiftEnter, "windows", { extendedKeyboardActive: false }),
    ).toEqual({ type: "passthrough" });
    expect(getTerminalKeyAction(shiftEnter, "windows")).toEqual({ type: "passthrough" });
  });

  test("encodes the modifier set for modified enter", () => {
    const base = {
      type: "keydown" as const,
      key: "Enter",
      ctrlKey: false,
      shiftKey: false,
      altKey: false,
      metaKey: false,
    };

    expect(
      getTerminalKeyAction({ ...base, ctrlKey: true }, "windows", {
        extendedKeyboardActive: true,
      }),
    ).toEqual({ type: "write", data: "\u001b[13;5u" });
    expect(
      getTerminalKeyAction({ ...base, altKey: true }, "windows", {
        extendedKeyboardActive: true,
      }),
    ).toEqual({ type: "write", data: "\u001b[13;3u" });
  });
});

// Advertising the disambiguation bit promises that the keys whose legacy bytes
// collide stay distinguishable. Ctrl+I shares 0x09 with Tab and Ctrl+M shares
// 0x0D with Enter, so those combinations must use the codepoint form.
describe("disambiguated keys", () => {
  const key = (init: { key: string } & Record<string, unknown>) => ({
    type: "keydown" as const,
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    ...init,
  });

  test("encodes Ctrl+I, Ctrl+M and Ctrl+[ distinctly", () => {
    const active = { extendedKeyboardActive: true };
    expect(getTerminalKeyAction(key({ key: "i", ctrlKey: true }), "windows", active)).toEqual({
      type: "write",
      data: "\u001b[105;5u",
    });
    expect(getTerminalKeyAction(key({ key: "m", ctrlKey: true }), "windows", active)).toEqual({
      type: "write",
      data: "\u001b[109;5u",
    });
    expect(getTerminalKeyAction(key({ key: "[", ctrlKey: true }), "windows", active)).toEqual({
      type: "write",
      data: "\u001b[91;5u",
    });
  });

  // The plain keys keep their usual bytes so shells and other programs that
  // never negotiated the protocol are untouched.
  test("leaves plain Tab, Enter and Escape on the legacy path", () => {
    const active = { extendedKeyboardActive: true };
    expect(getTerminalKeyAction(key({ key: "Tab" }), "windows", active)).toEqual({
      type: "passthrough",
    });
    expect(getTerminalKeyAction(key({ key: "Enter" }), "windows", active)).toEqual({
      type: "passthrough",
    });
    expect(getTerminalKeyAction(key({ key: "Escape" }), "windows", active)).toEqual({
      type: "passthrough",
    });
  });

  test("does not encode the aliasing combinations before negotiation", () => {
    expect(getTerminalKeyAction(key({ key: "i", ctrlKey: true }), "windows")).toEqual({
      type: "passthrough",
    });
  });
});
