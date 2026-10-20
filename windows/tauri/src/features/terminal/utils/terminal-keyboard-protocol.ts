/**
 * Fields of the kitty keyboard protocol Lithe can actually deliver.
 *
 * Bit 1 is "disambiguate escape codes": keys that a legacy terminal cannot tell
 * apart are sent in `CSI <codepoint>;<modifier> u` form instead of their bare
 * control byte. Lithe's terminal key handler emits that form for modified Enter,
 * for the aliasing control combinations and for Escape
 * (`terminal-keyboard.ts`), which is the set this bit promises.
 *
 * The other bits describe event types, alternate keys and text reporting, none
 * of which Lithe produces, so they are never claimed even when a program pushes
 * them.
 */
const SUPPORTED_KITTY_FLAGS = 1;

/** CSI ... u sequences a program uses to negotiate the keyboard protocol. */
const CSI = "\u001b[";
const BEL_OR_ST = ["\u0007", "\u009c"];

/**
 * Private modes that switch to the alternate screen buffer.
 *
 * 47 and 1047 are the two historical alternates; 1049 additionally saves the
 * cursor and clears the screen. All three move the program to a fresh screen, and
 * the protocol state that screen owns is therefore separate.
 */
const ALTERNATE_SCREEN_MODES = [47, 1047, 1049];

interface KeyboardProtocolFlags {
  /** Flags currently in effect for the screen that owns this state. */
  flags: number;
  /** Saved flag sets for nested programs on the same screen. */
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
 *
 * The state is kept per screen buffer, as the protocol requires: a TUI enables
 * the protocol on the alternate screen and must not leave the shell on the main
 * screen believing it is still enabled. Entering the alternate screen starts from
 * an empty state so a program that crashes without popping cannot leak its flags
 * into the next one.
 */
export class TerminalKeyboardProtocolStream {
  private readonly mainScreen: KeyboardProtocolFlags = { flags: 0, stack: [] };
  private alternateScreen: KeyboardProtocolFlags = { flags: 0, stack: [] };
  private onAlternateScreen = false;
  /** Output seen so far that may still turn out to be a query. */
  private pending = "";

  reset(): void {
    this.mainScreen.flags = 0;
    this.mainScreen.stack.length = 0;
    this.alternateScreen = { flags: 0, stack: [] };
    this.onAlternateScreen = false;
    this.pending = "";
  }

  /** Flags currently reported to programs; exposed for tests and diagnostics. */
  get flags(): number {
    return this.currentScreen().flags;
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

      const parsed = parseCsiSequence(buffer, escapeIndex + CSI.length);
      if (parsed === "incomplete") {
        this.pending = buffer.slice(escapeIndex);
        break;
      }
      if (parsed === null) {
        index = escapeIndex + CSI.length;
        continue;
      }

      if (parsed.kind === "screen") {
        this.applyScreenSwitch(parsed.alternate);
      } else {
        const answer = this.apply(parsed.sequence);
        if (answer) response = (response ?? "") + answer;
      }
      index = parsed.end;
    }

    return response;
  }

  private currentScreen(): KeyboardProtocolFlags {
    return this.onAlternateScreen ? this.alternateScreen : this.mainScreen;
  }

  private applyScreenSwitch(alternate: boolean): void {
    if (alternate === this.onAlternateScreen) return;
    if (alternate) {
      // A program that leaves without popping would otherwise hand its flags to
      // whichever program enters the alternate screen next.
      this.alternateScreen = { flags: 0, stack: [] };
    }
    this.onAlternateScreen = alternate;
  }

  /** Update the tracked flags and return the reply a program expects back. */
  private apply(sequence: KittySequence): string | null {
    const screen = this.currentScreen();

    switch (sequence.prefix) {
      case "?":
        // Report what is active, limited to what Lithe can deliver.
        return `${CSI}?${screen.flags & SUPPORTED_KITTY_FLAGS}u`;
      case ">": {
        // Push the current set and switch to the requested one.
        if (screen.stack.length >= MAX_STACK) screen.stack.shift();
        screen.stack.push(screen.flags);
        screen.flags = sequence.flags & SUPPORTED_KITTY_FLAGS;
        return null;
      }
      case "<": {
        const count = Math.max(sequence.flags || 1, 1);
        for (let popped = 0; popped < count; popped += 1) {
          const restored = screen.stack.pop();
          if (restored === undefined) {
            screen.flags = 0;
            break;
          }
          screen.flags = restored;
        }
        return null;
      }
      case "=":
        // Modes 1/2/3 set, union and subtract; anything else is invalid.
        switch (sequence.mode) {
          case 1:
            screen.flags = sequence.flags & SUPPORTED_KITTY_FLAGS;
            break;
          case 2:
            screen.flags |= sequence.flags & SUPPORTED_KITTY_FLAGS;
            break;
          case 3:
            screen.flags &= ~(sequence.flags & SUPPORTED_KITTY_FLAGS);
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
}

type CsiEvent =
  | { kind: "kitty"; sequence: KittySequence; end: number }
  | { kind: "screen"; alternate: boolean; end: number };

/**
 * Parse a CSI sequence starting just after `CSI`.
 *
 * Only two final bytes matter here: `u` carries the keyboard protocol exchange,
 * and `h`/`l` on the private `?` prefix carry the screen switch that decides
 * which state the exchange belongs to.
 *
 * Returns `"incomplete"` when the buffer ends mid-sequence so the caller can
 * wait for the rest, and `null` when the bytes are not a sequence this stream
 * tracks.
 */
function parseCsiSequence(buffer: string, start: number): CsiEvent | "incomplete" | null {
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
        kind: "kitty",
        sequence: {
          prefix,
          flags: numbers[0] ?? 0,
          mode: numbers[1] ?? 1,
        },
        // A CSI sequence ends after its final byte; keep scanning the rest.
        end: index + 1,
      };
    }
    if ((character === "h" || character === "l") && prefix === "?") {
      if (current !== null) numbers.push(Number(current));
      const switchesScreen = numbers.some((mode) => ALTERNATE_SCREEN_MODES.includes(mode));
      if (!switchesScreen) return null;
      return { kind: "screen", alternate: character === "h", end: index + 1 };
    }
    if (BEL_OR_ST.includes(character)) return null;
    // Any other byte means this was a different CSI sequence.
    return null;
  }

  return "incomplete";
}
