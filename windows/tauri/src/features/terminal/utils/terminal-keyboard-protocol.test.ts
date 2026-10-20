import { describe, expect, test } from "bun:test";
import { TerminalKeyboardProtocolStream } from "./terminal-keyboard-protocol";

const CSI = "\u001b[";

describe("TerminalKeyboardProtocolStream", () => {
  // Regression: kimi pushes flags then asks `CSI ? u`, and only enables its
  // enhanced key path after an answer arrives. xterm.js consumes the query
  // without replying, so Shift+Enter fell back to a plain Escape press and the
  // TUI never inserted a newline.
  test("answers the query kimi sends after pushing flags", () => {
    const stream = new TerminalKeyboardProtocolStream();
    // The order matches kimi's startup: push, then query.
    expect(stream.feed(`${CSI}>7u${CSI}?u`)).toBe(`${CSI}?1u`);
  });

  // Before any program pushes, the active set is empty, so the honest answer is 0.
  test("reports no active flags before a program asks for them", () => {
    const stream = new TerminalKeyboardProtocolStream();
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?0u`);
  });

  test("answers with the flags currently in effect", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    expect(stream.flags).toBe(1);
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?1u`);
  });

  // A program may push flags Lithe cannot deliver. Reporting them would make the
  // program expect keys that never arrive, so only the supported bits are echoed.
  test("never claims flags beyond what Lithe can deliver", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>7u`);
    expect(stream.flags).toBe(1);
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?1u`);
  });

  test("restores the previous flags when the program pops", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.feed(`${CSI}>0u`);
    expect(stream.flags).toBe(0);
    stream.feed(`${CSI}<u`);
    expect(stream.flags).toBe(1);
  });

  test("clears all flags when popping past the bottom of the stack", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.feed(`${CSI}<5u`);
    expect(stream.flags).toBe(0);
  });

  test("applies the set, union and subtract modes", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}=1;1u`);
    expect(stream.flags).toBe(1);
    stream.feed(`${CSI}=1;3u`);
    expect(stream.flags).toBe(0);
    stream.feed(`${CSI}=0;2u`);
    expect(stream.flags).toBe(0);
  });

  // Output arrives in chunks, so a query split across reads must still be answered.
  test("answers a query split across reads", () => {
    const stream = new TerminalKeyboardProtocolStream();
    expect(stream.feed(`${CSI}?`)).toBeNull();
    expect(stream.feed("u")).toBe(`${CSI}?0u`);
  });

  test("answers a query followed by more output", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    expect(stream.feed(`hello${CSI}?u world`)).toBe(`${CSI}?1u`);
  });

  test("answers every query in one chunk", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    expect(stream.feed(`${CSI}?u${CSI}?u`)).toBe(`${CSI}?1u${CSI}?1u`);
  });

  // The stream shares the output with the renderer, so unrelated sequences and
  // text must pass through untouched and produce no reply.
  test("ignores output that is not a keyboard protocol query", () => {
    const stream = new TerminalKeyboardProtocolStream();
    expect(stream.feed("plain text")).toBeNull();
    expect(stream.feed(`${CSI}2J`)).toBeNull();
    expect(stream.feed(`${CSI}?25l`)).toBeNull();
    expect(stream.feed(`${CSI}0m`)).toBeNull();
    expect(stream.feed(`${CSI}?2026h`)).toBeNull();
  });

  test("resets the tracked flags", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.reset();
    expect(stream.flags).toBe(0);
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?0u`);
  });
});

// A TUI enables the protocol on the alternate screen and the shell it returns to
// never asked for it. Sharing one set of flags would leave the shell answering
// `CSI ? u` with a mode it cannot use, so the protocol state follows the screen
// buffer that owns it.
describe("per-screen keyboard protocol state", () => {
  test("reports the main screen flags after leaving the alternate screen", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}?1049h`);
    stream.feed(`${CSI}>1u`);
    expect(stream.flags).toBe(1);
    stream.feed(`${CSI}?1049l`);
    expect(stream.flags).toBe(0);
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?0u`);
  });

  test("keeps the main screen flags across an alternate screen visit", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.feed(`${CSI}?1049h`);
    // The alternate screen starts empty even though the main screen is set.
    expect(stream.flags).toBe(0);
    stream.feed(`${CSI}?1049l`);
    expect(stream.flags).toBe(1);
  });

  test("handles the other alternate screen modes", () => {
    for (const mode of [47, 1047]) {
      const stream = new TerminalKeyboardProtocolStream();
      stream.feed(`${CSI}?${mode}h`);
      expect(stream.flags).toBe(0);
      stream.feed(`${CSI}>1u`);
      expect(stream.flags).toBe(1);
      stream.feed(`${CSI}?${mode}l`);
      expect(stream.flags).toBe(0);
    }
  });

  // A program killed inside a TUI never sends the pop or the screen restore, so
  // the next program to take the alternate screen must not inherit its flags.
  test("clears leftover alternate screen flags when a new one is entered", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}?1049h`);
    stream.feed(`${CSI}>1u`);
    // The program dies; the shell returns to the main screen and a second TUI
    // takes the alternate screen.
    stream.feed(`${CSI}?1049l`);
    stream.feed(`${CSI}?1049h`);
    expect(stream.flags).toBe(0);
    expect(stream.feed(`${CSI}?u`)).toBe(`${CSI}?0u`);
  });

  test("ignores private modes that do not switch screens", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.feed(`${CSI}?25l${CSI}?2004h${CSI}?25h${CSI}?2004l`);
    expect(stream.flags).toBe(1);
  });

  test("resets both screens", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}>1u`);
    stream.feed(`${CSI}?1049h`);
    stream.feed(`${CSI}>1u`);
    stream.reset();
    expect(stream.flags).toBe(0);
    stream.feed(`${CSI}?1049l`);
    expect(stream.flags).toBe(0);
  });
});

// A PTY can split output at any byte, including right after `CSI`. Waiting for
// the rest is what keeps a query at that boundary from being dropped.
describe("chunk boundary after the CSI prefix", () => {
  test("waits when a chunk ends between CSI and the prefix byte", () => {
    const stream = new TerminalKeyboardProtocolStream();
    // The chunk stops right after `ESC [`, so the prefix byte has not arrived yet.
    expect(stream.feed(`${CSI}`)).toBeNull();
    expect(stream.feed("?u")).toBe(`${CSI}?0u`);
  });

  test("applies a push split after CSI", () => {
    const stream = new TerminalKeyboardProtocolStream();
    stream.feed(`${CSI}`);
    stream.feed(">1u");
    expect(stream.flags).toBe(1);
  });
});
