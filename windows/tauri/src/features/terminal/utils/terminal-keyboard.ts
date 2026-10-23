type TerminalKeyboardEvent = Pick<
  KeyboardEvent,
  "altKey" | "ctrlKey" | "key" | "metaKey" | "shiftKey" | "type"
> & {
  getModifierState?: (keyArg: string) => boolean;
};

export type TerminalKeyAction =
  | { type: "passthrough" }
  | { type: "block" }
  | { type: "copy" }
  | { type: "paste" }
  | { type: "switchTab"; direction: "next" | "prev" }
  | { type: "write"; data: string };

export interface TerminalKeyContext {
  /**
   * True when the terminal currently has selected text.
   *
   * Ctrl+C means two things in a terminal: with a selection it copies, without
   * one it must reach the program as SIGINT so a running command can be
   * interrupted. Defaulting to `false` keeps the previous behaviour exactly.
   */
  hasSelection?: boolean;
}

export function isTerminalAltGraphInput(event: TerminalKeyboardEvent): boolean {
  return (
    event.getModifierState?.("AltGraph") === true ||
    (event.ctrlKey && event.altKey && !event.metaKey)
  );
}

export function isTerminalAltTextInput(event: TerminalKeyboardEvent): boolean {
  if (!event.altKey || event.metaKey) return false;
  if (event.key.length !== 1) return false;
  return !event.ctrlKey || isTerminalAltGraphInput(event);
}

export function isTerminalFindShortcut(
  event: TerminalKeyboardEvent & { defaultPrevented?: boolean },
): boolean {
  return (
    !event.defaultPrevented &&
    (event.ctrlKey || event.metaKey) &&
    !event.shiftKey &&
    !event.altKey &&
    event.key.toLowerCase() === "f"
  );
}

/**
 * Encode a key whose legacy form collides with another key, in the form the kitty
 * protocol's first bit promises.
 *
 * A legacy terminal sends the same byte for Tab and Ctrl+I (0x09), for Enter and
 * Ctrl+M (0x0D), and for Escape and Ctrl+[ (0x1B), so a TUI cannot distinguish
 * them. Once the program enables that bit it expects the distinct codepoint form
 * for the combination that would otherwise alias. Alt+Backspace is in the same
 * position: the legacy mapping sends 0x17, which is also what Ctrl+W sends.
 *
 * Escape is encoded too, and for the reason the bit is named after: its bare byte
 * is identical to the prefix of every CSI and OSC sequence, so a program that has
 * asked for disambiguated escape codes must not receive one. The plain Tab and
 * Enter keys keep the terminal's usual bytes, which shells still rely on.
 *
 * Returns null for keys with no ambiguous legacy form.
 */
function encodeDisambiguatedKey(event: TerminalKeyboardEvent): string | null {
  if (event.key === "Escape") {
    return encodeCodepoint(27, event);
  }
  // Only the modified form aliases a control byte; plain Backspace keeps 0x7f,
  // which shells and readline rely on for single-character deletion.
  if (event.key === "Backspace" && (event.altKey || event.ctrlKey)) {
    return encodeCodepoint(127, event);
  }
  if (event.ctrlKey && !event.shiftKey && !event.altKey && event.key.length === 1) {
    const letter = event.key.toLowerCase();
    if (letter === "i" || letter === "m" || letter === "[") {
      // Ctrl+I, Ctrl+M and Ctrl+[ share their control byte with Tab, Enter and
      // Escape; the codepoint form is what lets the program tell them apart.
      const codepoint = letter === "[" ? 91 : letter.charCodeAt(0);
      return `\x1b[${codepoint};5u`;
    }
  }
  return null;
}

/**
 * Encode a key press as `CSI <codepoint>[;<modifier>] u`.
 *
 * The protocol omits the modifier when it is the default, so an unmodified key
 * still parses on the program side.
 */
function encodeCodepoint(codepoint: number, event: TerminalKeyboardEvent): string {
  const modifier =
    1 + (event.shiftKey ? 1 : 0) + (event.altKey ? 2 : 0) + (event.ctrlKey ? 4 : 0);
  return modifier === 1 ? `\x1b[${codepoint}u` : `\x1b[${codepoint};${modifier}u`;
}

export interface TerminalKeyContext {
  /**
   * True when the running program negotiated the kitty keyboard protocol.
   *
   * Modified Enter is only expressible through that protocol. Sending the
   * sequence to a program that did not ask for it makes the terminal print the
   * leftover bytes as text on the command line.
   */
  extendedKeyboardActive?: boolean;
}

export function getTerminalKeyAction(
  event: TerminalKeyboardEvent,
  platform = "macos",
  context: TerminalKeyContext = {},
): TerminalKeyAction {
  if (event.type !== "keydown") return { type: "passthrough" };

  // IDEA and Windows Terminal both let plain Ctrl+C copy a selection and keep it
  // as SIGINT otherwise. Only intercepting when text is selected is what keeps
  // an interrupt available while a command is running.
  if (
    platform !== "macos" &&
    event.ctrlKey &&
    !event.shiftKey &&
    !event.altKey &&
    !event.metaKey &&
    event.key.toLowerCase() === "c" &&
    context.hasSelection
  ) {
    return { type: "copy" };
  }

  if (platform !== "macos" && event.ctrlKey && event.shiftKey && !event.altKey && !event.metaKey) {
    const key = event.key.toLowerCase();
    if (key === "c") return { type: "copy" };
    if (key === "v") return { type: "paste" };
  }

  // Windows terminals conventionally use Ctrl+V for clipboard paste. Handle
  // it before the PTY sees the control character, which would otherwise be
  // rendered as the literal `^V` by cmd and similar shells.
  if (
    platform !== "macos" &&
    event.ctrlKey &&
    !event.shiftKey &&
    !event.altKey &&
    !event.metaKey &&
    event.key.toLowerCase() === "v"
  ) {
    return { type: "paste" };
  }

  if (
    event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    !event.shiftKey &&
    (event.key === "PageUp" || event.key === "PageDown")
  ) {
    return {
      type: "switchTab",
      direction: event.key === "PageDown" ? "next" : "prev",
    };
  }

  // The kitty "disambiguate escape codes" bit promises a distinct encoding for
  // every key that a legacy terminal could not tell apart. Advertising the bit
  // while leaving those keys on the legacy path would make a TUI trust a
  // guarantee that does not hold, so every aliasing key is encoded with it —
  // including the control-letter aliases further down, which is why this runs
  // before them.
  if (context.extendedKeyboardActive && !event.metaKey) {
    const encoded = encodeDisambiguatedKey(event);
    if (encoded) return { type: "write", data: encoded };
  }

  if (event.key === "Enter" && !event.metaKey) {
    const modifier =
      1 + (event.shiftKey ? 1 : 0) + (event.altKey ? 2 : 0) + (event.ctrlKey ? 4 : 0);
    // Only a program that negotiated the kitty protocol can decode this form; for
    // everyone else the bytes are literal text and show up on the command line.
    // Leaving the key alone lets the terminal send its usual carriage return.
    if (modifier > 1 && context.extendedKeyboardActive) {
      return { type: "write", data: `\x1b[13;${modifier}u` };
    }
  }

  if (isTerminalAltTextInput(event)) return { type: "passthrough" };

  if (event.metaKey && !event.ctrlKey && !event.altKey) {
    const metaSequences: Record<string, string> = {
      Backspace: "\u0015",
      k: "\u000c",
      a: "\u0001",
      e: "\u0005",
      ArrowLeft: "\u0001",
      ArrowRight: "\u0005",
    };
    const data = metaSequences[event.key];
    return data ? { type: "write", data } : { type: "block" };
  }

  if (event.altKey && !event.ctrlKey && !event.metaKey) {
    const altSequences: Record<string, string> = {
      Backspace: "\u0017",
      ArrowLeft: "\u001bb",
      ArrowRight: "\u001bf",
    };
    const data = altSequences[event.key];
    if (data) return { type: "write", data };
  }

  return event.metaKey ? { type: "block" } : { type: "passthrough" };
}
