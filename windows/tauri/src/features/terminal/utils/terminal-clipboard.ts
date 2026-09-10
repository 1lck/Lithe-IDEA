const MULTILINE_PASTE_LINE_THRESHOLD = 5;
const LARGE_PASTE_CHAR_THRESHOLD = 1000;

export interface TerminalClipboardTarget {
  getSelection: () => string;
  paste: (text: string) => void;
}

interface PasteTerminalTextOptions {
  terminal: Pick<TerminalClipboardTarget, "paste">;
  text: string;
  isConnected: () => boolean;
  confirmPaste: (lineCount: number) => Promise<boolean>;
}

export function hasTerminalSelection(
  terminal: Pick<TerminalClipboardTarget, "getSelection"> | null,
): boolean {
  return Boolean(terminal?.getSelection());
}

export async function copyTerminalSelection(
  terminal: Pick<TerminalClipboardTarget, "getSelection">,
  writeText: (text: string) => Promise<void>,
): Promise<boolean> {
  const selection = terminal.getSelection();
  if (!selection) return false;

  await writeText(selection);
  return true;
}

export async function pasteTerminalText({
  terminal,
  text,
  isConnected,
  confirmPaste,
}: PasteTerminalTextOptions): Promise<boolean> {
  if (!text || !isConnected()) return false;

  const lineCount = text.replace(/\r\n/g, "\n").split("\n").length;
  const requiresConfirmation =
    lineCount >= MULTILINE_PASTE_LINE_THRESHOLD || text.length >= LARGE_PASTE_CHAR_THRESHOLD;

  if (requiresConfirmation && !(await confirmPaste(lineCount))) return false;

  // The terminal can disconnect while the clipboard read or confirmation dialog is pending.
  if (!isConnected()) return false;

  terminal.paste(text);
  return true;
}
