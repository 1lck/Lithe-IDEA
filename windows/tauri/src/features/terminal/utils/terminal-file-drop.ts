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
 * Characters PowerShell accepts as a single-quote delimiter. Verified against
 * PowerShell 5.1 by executing an injection inside the quoted path and checking
 * for the side effect: ASCII `'` and the four typographic quotes below all end
 * the string, so every one of them must be doubled. `'` alone is not enough —
 * a file named `report’;whoami;#.txt` escaped the literal and ran `whoami`.
 */
const POWERSHELL_SINGLE_QUOTES = /['\u2018\u2019\u201A\u201B]/g;

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
function quotePathForShell(path: string, family: TerminalShellFamily): string | null {
  if (family === "powershell") {
    // Doubling is PowerShell's escape inside a single-quoted string and keeps the
    // literal value intact for every delimiter character above.
    return `'${path.replace(POWERSHELL_SINGLE_QUOTES, (quote) => quote + quote)}'`;
  }
  if (family === "nushell") {
    // A Nushell single-quoted string has no escape for `'`, so doubling would not
    // round-trip. Its raw string keeps quotes, `$` and backslashes literal, which
    // covers the shapes a Windows path can contain.
    if (!path.includes("`")) return `\`${path}\``;
    if (!path.includes("'")) return `'${path}'`;
    // A backtick cannot appear in a raw string and a quote cannot appear in a
    // single-quoted string, so this path has no literal form in Nushell. Report
    // it instead of emitting the bare path: an unquoted `;` or `|` in a file name
    // would then run as a command separator.
    return null;
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
 *
 * A path with no literal form in the target shell is dropped rather than emitted
 * unquoted; inserting a bare path could run a file name as a command.
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
    .filter((quoted): quoted is string => quoted !== null)
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
  // Quoting can drop every path (a name the shell cannot represent literally),
  // which would otherwise emit a lone trailing space.
  const quoted = quoteTerminalPaths(paths, shell);
  if (!quoted) return "";
  return `${quoted} `;
}
