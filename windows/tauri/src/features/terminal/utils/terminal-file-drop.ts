import { parseDroppedPaths } from "@/features/file-system/utils/file-system-dropped-paths";

/**
 * Shells Lithe can launch on Windows. They disagree on what counts as an escape,
 * so a single quoting style cannot serve all of them.
 */
export type TerminalShellFamily = "cmd" | "powershell" | "posix" | "nushell";

/**
 * Classify the launched shell so paths can be quoted the way it expects.
 *
 * Only ids and executable paths are passed here, so substring matches are the
 * stable signal across cmd, PowerShell, Nushell and Git Bash. PowerShell is
 * checked first because `powershell` and `pwsh` both contain `sh`.
 */
export function terminalShellFamily(shell?: string | null): TerminalShellFamily {
  const value = (shell ?? "").toLowerCase();
  if (value.includes("powershell") || value.includes("pwsh")) return "powershell";
  if (value === "nu" || value.includes("nushell")) return "nushell";
  if (value.includes("cmd")) return "cmd";
  if (
    value.includes("bash") ||
    value.includes("zsh") ||
    value.includes("fish") ||
    value === "sh" ||
    value.endsWith("/sh") ||
    value.endsWith("\\sh.exe")
  ) {
    return "posix";
  }
  // The Windows default is cmd.exe, whose double quotes keep operators literal.
  return "cmd";
}

/**
 * Quote one path for the target shell.
 *
 * Single quotes are used wherever the shell has them, because both PowerShell
 * and POSIX shells still evaluate `$(...)`, `$name` and backticks inside double
 * quotes: `report$(whoami).txt` would run `whoami`. Single quotes make the path
 * literal, which also preserves the backslashes a Windows path contains instead
 * of letting the shell consume them as escapes.
 *
 * cmd.exe has no literal string syntax; double quotes are the strongest form it
 * offers, so `%NAME%` can still expand when a file name happens to match an
 * environment variable. Windows forbids `"` in file names, so no escaping is
 * needed inside the quotes.
 */
function quotePathForShell(path: string, family: TerminalShellFamily): string {
  if (family === "powershell" || family === "nushell") {
    return `'${path.replace(/'/g, "''")}'`;
  }
  if (family === "posix") {
    // Close the quote, escape the apostrophe outside it, then reopen.
    return `'${path.replace(/'/g, "'\\''")}'`;
  }
  return `"${path}"`;
}

/**
 * Quote paths for the target shell so each stays one argument and is never
 * evaluated as command syntax.
 */
export function quoteTerminalPaths(
  paths: readonly string[],
  shell?: string | null,
): string {
  const family = terminalShellFamily(shell);
  return paths.map((path) => quotePathForShell(path, family)).join(" ");
}

/**
 * Render paths as text to insert at the prompt. A trailing space keeps the next
 * token the user types separate from the inserted path.
 */
export function formatPathsForTerminal(
  paths: readonly string[],
  options: { shell?: string | null; trailingSpace?: boolean } = {},
): string {
  const text = quoteTerminalPaths(paths, options.shell);
  if (!text) return "";
  return options.trailingSpace ? `${text} ` : text;
}

export function formatDroppedPathsForTerminal(
  rawPaths: string[],
  shell?: string | null,
): string {
  const paths = parseDroppedPaths(rawPaths);
  if (paths.length === 0) return "";
  return `${quoteTerminalPaths(paths, shell)} `;
}
