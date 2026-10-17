import { parseDroppedPaths } from "@/features/file-system/utils/file-system-dropped-paths";

/**
 * Characters that never need shell quoting: letters, digits, and the separators
 * of a plain path. Everything else is quoted, because cmd treats `&`, `|`, `<`,
 * `>`, `^` and `(` `)` as operators and PowerShell adds `;`, `$`, `` ` ``, `{`
 * and `}`. Explorer entries may be workspace-relative, so they can no longer
 * rely on the backslash that used to make an absolute Windows path match.
 */
const UNQUOTED_TERMINAL_PATH = /^[A-Za-z0-9._/\\:-]+$/;

function quoteTerminalPath(path: string): string {
  // A bare path must be returned untouched: doubling backslashes is only valid
  // inside quotes and would otherwise corrupt the path the shell receives.
  if (UNQUOTED_TERMINAL_PATH.test(path)) return path;
  // Quotes make cmd and PowerShell read operators literally. Backslashes stay
  // as written because neither shell treats them as escapes inside quotes;
  // only the closing quote needs doubling.
  return `"${path.replace(/"/g, '""')}"`;
}

/**
 * Quote each path so a shell keeps it as one argument and never reads a file
 * name as a command operator.
 * Exported for the explorer file clipboard, whose entries may be relative and
 * therefore cannot go through `parseDroppedPaths`.
 */
export function quoteTerminalPaths(paths: readonly string[]): string {
  return paths.map(quoteTerminalPath).join(" ");
}

/**
 * Render paths as text to insert at the prompt. A trailing space keeps the next
 * token the user types separate from the inserted path.
 */
export function formatPathsForTerminal(
  paths: readonly string[],
  options: { trailingSpace?: boolean } = {},
): string {
  const text = quoteTerminalPaths(paths);
  if (!text) return "";
  return options.trailingSpace ? `${text} ` : text;
}

export function formatDroppedPathsForTerminal(rawPaths: string[]): string {
  const paths = parseDroppedPaths(rawPaths);
  if (paths.length === 0) return "";
  return `${quoteTerminalPaths(paths)} `;
}
