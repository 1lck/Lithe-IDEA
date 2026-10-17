import { parseDroppedPaths } from "@/features/file-system/utils/file-system-dropped-paths";

function quoteTerminalPath(path: string): string {
  const escaped = path.replace(/(["\\$`])/g, "\\$1");
  return /[\s"'\\$`]/.test(path) ? `"${escaped}"` : escaped;
}

/**
 * Quote each path so a shell keeps a path containing spaces as one argument.
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
