/**
 * Fields of the kitty keyboard protocol Lithe can actually deliver.
 *
 * Bit 1 is "disambiguate escape codes": modified keys are sent as
 * `CSI <codepoint>;<modifier> u` instead of a bare control byte. Lithe's
 * terminal key handler already emits that form for Enter
 * (`terminal-keyboard.ts`), which is the case this exists for.
 *
 * The other bits describe event types, alternate keys and text reporting, none
 * of which Lithe produces, so they are never claimed even when a program pushes
 * them.
 */
const SUPPORTED_KITTY_FLAGS = 1;

/** CSI ... u sequences a program uses to negotiate the keyboard protocol. */
const CSI = "\u001b[";
const BEL_OR_ST = ["\u0007", "\u009c"];

interface KeyboardProtocolState {
  /** Flags currently in effect for the active screen buffer. */
  flags: number;
  /** Saved flag sets for nested programs. */
  stack: number[];
}

/**
 * Answers kitty keyboard protocol negotiation found in the terminal output.
 *
 * A program asks the terminal what it supports with `CSI ? u` and only enables
 * its enhanced key handling after receiving an answer. xterm.js registers `u`
 * as the final byte of "restore cursor" and never replies, so a TUI such as kimi
 * stayed on its legacy key path and Shift+Enter arrived as a plain Escape press.
 *
 * This stream observes the same output the terminal renders and reports the
 * answer the program is waiting for. It deliberately reports only the flags in
 * `SUPPORTED_KITTY_FLAGS`, so a program never believes Lithe can do more than it
 * does.
 */
export class TerminalKeyboardProtocolStream {
  private state: KeyboardProtocolState = { flags: 0, stack: [] };
  /** Output seen so far that may still turn out to be a query. */
  private pending = "";

  reset(): void {
    this.state = { flags: 0, stack: [] };
    this.pending = "";
  }

  /** Flags currently reported to programs; exposed for tests and diagnostics. */
  get flags(): number {
    return this.state.flags;
  }

  /**
   * Consume terminal output and return a response to send back to the program,
   * or null when the output contains no query that needs one.
   */
  feed(data: string): string | null {
    if (!data) return null;

    const buffer = this.pending + data;
    this.pending = "";
    let response: string | null = null;
    let index = 0;

    while (index < buffer.length) {
      const escapeIndex = buffer.indexOf(CSI, index);
      if (escapeIndex === -1) {
        // Keep a trailing ESC so a sequence split across reads is still seen.
        this.pending = buffer.endsWith("\u001b") ? "\u001b" : "";
        break;
      }

      const parsed = parseKittySequence(buffer, escapeIndex + CSI.length);
      if (parsed === "incomplete") {
        this.pending = buffer.slice(escapeIndex);
        break;
      }
      if (parsed === null) {
        index = escapeIndex + CSI.length;
        continue;
      }

      const answer = this.apply(parsed);
      if (answer) response = (response ?? "") + answer;
      index = parsed.end;
    }

    return response;
  }

  /** Update the tracked flags and return the reply a program expects back. */
  private apply(sequence: KittySequence): string | null {
    switch (sequence.prefix) {
      case "?":
        // Report what is active, limited to what Lithe can deliver.
        return `${CSI}?${this.state.flags & SUPPORTED_KITTY_FLAGS}u`;
      case ">": {
        // Push the current set and switch to the requested one.
        if (this.state.stack.length >= MAX_STACK) this.state.stack.shift();
        this.state.stack.push(this.state.flags);
        this.state.flags = sequence.flags & SUPPORTED_KITTY_FLAGS;
        return null;
      }
      case "<": {
        const count = Math.max(sequence.flags || 1, 1);
        for (let popped = 0; popped < count; popped += 1) {
          const restored = this.state.stack.pop();
          if (restored === undefined) {
            this.state.flags = 0;
            break;
          }
          this.state.flags = restored;
        }
        return null;
      }
      case "=":
        // Modes 1/2/3 set, union and subtract; anything else is invalid.
        switch (sequence.mode) {
          case 1:
            this.state.flags = sequence.flags & SUPPORTED_KITTY_FLAGS;
            break;
          case 2:
            this.state.flags |= sequence.flags & SUPPORTED_KITTY_FLAGS;
            break;
          case 3:
            this.state.flags &= ~(sequence.flags & SUPPORTED_KITTY_FLAGS);
            break;
          default:
            break;
        }
        return null;
      default:
        return null;
    }
  }
}

const MAX_STACK = 32;

interface KittySequence {
  prefix: "?" | ">" | "<" | "=";
  /** First numeric parameter: the flag set for `>`, `=` and `<`. */
  flags: number;
  /** Second numeric parameter of `=`, the set mode. */
  mode: number;
  /** Index just past the final byte. */
  end: number;
}

/**
 * Parse a kitty keyboard sequence starting just after `CSI`.
 *
 * Returns `"incomplete"` when the buffer ends mid-sequence so the caller can
 * wait for the rest, and `null` when the bytes are not a kitty sequence at all.
 */
function parseKittySequence(buffer: string, start: number): KittySequence | "incomplete" | null {
  // The chunk may end right after `CSI`, before the prefix byte arrives. That is
  // a truncation, not a foreign sequence: waiting keeps a query split at this
  // exact boundary from being dropped.
  if (start >= buffer.length) return "incomplete";

  const prefix = buffer[start];
  if (prefix !== "?" && prefix !== ">" && prefix !== "<" && prefix !== "=") return null;

  let index = start + 1;
  const numbers: number[] = [];
  let current: string | null = null;

  for (; index < buffer.length; index += 1) {
    const character = buffer[index];
    if (character >= "0" && character <= "9") {
      current = (current ?? "") + character;
      continue;
    }
    if (character === ";") {
      numbers.push(current === null ? 0 : Number(current));
      current = null;
      continue;
    }
    if (character === "u") {
      numbers.push(current === null ? 0 : Number(current));
      return {
        prefix,
        flags: numbers[0] ?? 0,
        mode: numbers[1] ?? 1,
        // A CSI sequence ends after its final byte; keep scanning the rest.
        end: index + 1,
      };
    }
    if (BEL_OR_ST.includes(character)) return null;
    // Any other byte means this was a different CSI sequence.
    return null;
  }

  return "incomplete";
}
