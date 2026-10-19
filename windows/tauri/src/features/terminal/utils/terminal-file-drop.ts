import { parseDroppedPaths } from "@/features/file-system/utils/file-system-dropped-paths";
import { parseRemotePath } from "@/features/remote/utils/remote-path";
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
    // Nushell has no escape inside a single-quoted string, and its backtick form
    // is a quoted *identifier*, not a string literal — wrapping a path in
    // backticks would change its meaning rather than protect it. So a single-
    // quoted path is the only literal form available, and a name containing `'`
    // has none.
    if (path.includes("'")) {
      // Emitting anything else here would either alter the path or leave it
      // unquoted, where a `;` in a file name would run as a command separator.
      return null;
    }
    return `'${path}'`;
  }
  if (family === "posix") {
    // Close the quote, escape the apostrophe outside it, then reopen.
    return `'${path.replace(/'/g, "'\\''")}'`;
  }
  return `"${path}"`;
}

/**
 * Turn a workspace path into one the target shell can open, or null when it
 * cannot be expressed there.
 *
 * The explorer stores paths in a frontend-only form for WSL and remote
 * workspaces, which a shell inside that host cannot open:
 *
 * - `wsl://<distro>/<path>` and Windows drives become Linux paths in the
 *   distribution (see `pathToWslPath`).
 * - `remote://<connection>/<path>` becomes the remote path, but only when the
 *   terminal is connected to that same connection. Handing the URI to a
 *   different shell would insert something that looks like a path and opens
 *   nothing, so any other case is reported as untranslatable.
 */
function shellPath(
  path: string,
  distro: string | null,
  remoteConnectionId: string | null,
): string | null {
  const remote = parseRemotePath(path);
  if (remote) {
    if (!remoteConnectionId || remote.connectionId !== remoteConnectionId) return null;
    return remote.remotePath;
  }

  if (distro) return pathToWslPath(path, distro);
  return path;
}

/**
 * Quote paths for the target shell so each stays one argument and is never
 * evaluated as command syntax.
 *
 * Paths are first translated into the target shell's namespace — WSL drives and
 * protocol paths into Linux paths, remote protocol paths into the connected
 * host's paths — because a shell cannot open the frontend form at all.
 *
 * A path that cannot be expressed in the target shell is dropped rather than
 * emitted as written; inserting a bare path could run a file name as a command.
 */
export function quoteTerminalPaths(
  paths: readonly string[],
  shell?: string | null,
  options: { remoteConnectionId?: string | null } = {},
): string {
  const family = terminalShellFamily(shell);
  const distro = (shell ?? "").toLowerCase().startsWith("wsl:")
    ? (shell ?? "").slice("wsl:".length)
    : null;
  const remoteConnectionId = options.remoteConnectionId ?? null;
  return paths
    .map((path) => shellPath(path, distro, remoteConnectionId))
    .map((path) => (path === null ? null : quotePathForShell(path, family)))
    .filter((quoted): quoted is string => quoted !== null)
    .join(" ");
}

/**
 * Render paths as text to insert at the prompt. A trailing space keeps the next
 * token the user types separate from the inserted path.
 */
export function formatPathsForTerminal(
  paths: readonly string[],
  options: { shell?: string | null; remoteConnectionId?: string | null; trailingSpace?: boolean } = {},
): string {
  const text = quoteTerminalPaths(paths, options.shell, {
    remoteConnectionId: options.remoteConnectionId,
  });
  if (!text) return "";
  return options.trailingSpace ? `${text} ` : text;
}

export function formatDroppedPathsForTerminal(
  rawPaths: string[],
  shell?: string | null,
  remoteConnectionId?: string | null,
): string {
  const paths = parseDroppedPaths(rawPaths);
  if (paths.length === 0) return "";
  // Quoting can drop every path (a name the shell cannot represent literally),
  // which would otherwise emit a lone trailing space.
  const quoted = quoteTerminalPaths(paths, shell, { remoteConnectionId });
  if (!quoted) return "";
  return `${quoted} `;
}
