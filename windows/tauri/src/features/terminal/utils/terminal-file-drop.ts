import { parseDroppedPaths } from "@/features/file-system/utils/file-system-dropped-paths";
import { pathToWslPath } from "@/features/wsl/utils/wsl-path";

/**
 * Shells Lithe can launch on Windows. They disagree on what counts as an escape,
 * so a single quoting style cannot serve all of them.
 */
export type TerminalShellFamily = "cmd" | "powershell" | "posix" | "nushell";

/**
 * Classify the launched shell so paths can be quoted the way it expects.
 *
 * The ids come from the native shell directory (`windows_shells.rs`) plus
 * `wsl:<distribution>`, so the mapping has to stay aligned with what the product
 * can actually launch. A shell that falls through to cmd would be quoted with
 * double quotes, which still evaluate `$(...)` in every bash-derived shell.
 *
 * PowerShell is checked first because `powershell` and `pwsh` both contain `sh`.
 * WSL, MSYS2 and Cygwin run bash, so they are POSIX despite launching on Windows.
 */
export function terminalShellFamily(shell?: string | null): TerminalShellFamily {
  const value = (shell ?? "").toLowerCase();
  if (value.includes("powershell") || value.includes("pwsh")) return "powershell";
  if (value === "nu" || value.includes("nushell")) return "nushell";
  // `wsl:<distro>` is bash inside a Linux distribution, not a Windows shell.
  if (value.startsWith("wsl:") || value === "msys2" || value === "cygwin") return "posix";
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
 *
 * A WSL session runs inside Linux, so paths are translated into that
 * distribution's namespace first — Windows drives become `/mnt/<drive>` and a
 * `wsl://<distro>` workspace path keeps only its Linux part. Without that the
 * shell treats the path as a relative filename and opens nothing.
 */
export function quoteTerminalPaths(
  paths: readonly string[],
  shell?: string | null,
): string {
  const family = terminalShellFamily(shell);
  const distro = (shell ?? "").toLowerCase().startsWith("wsl:")
    ? (shell ?? "").slice("wsl:".length)
    : null;
  return paths
    .map((path) => (distro ? (pathToWslPath(path, distro) ?? path) : path))
    .map((path) => quotePathForShell(path, family))
    .join(" ");
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
