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
