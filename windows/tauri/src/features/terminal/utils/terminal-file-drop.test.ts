import { describe, expect, test } from "bun:test";
import {
  formatDroppedPathsForTerminal,
  formatPathsForTerminal,
  quoteTerminalPaths,
  terminalShellFamily,
} from "./terminal-file-drop";

const WINDOWS_PATH = "C:\\work\\proj\\a.txt";
/** A file name that a shell would execute if the path were not quoted literally. */
const INJECTION_PATH = "C:\\work\\proj\\report$(whoami).txt";

describe("terminalShellFamily", () => {
  test("classifies the shells Lithe can launch", () => {
    expect(terminalShellFamily("cmd")).toBe("cmd");
    expect(terminalShellFamily("powershell")).toBe("powershell");
    expect(terminalShellFamily("pwsh")).toBe("powershell");
    expect(terminalShellFamily("bash")).toBe("posix");
    expect(terminalShellFamily("nu")).toBe("nushell");
  });

  // Regression: the native shell directory also offers MSYS2, Cygwin and
  // `wsl:<distro>`, which all run bash. Falling back to cmd quoted them with
  // double quotes, so `$(...)` in a file name still executed.
  test("classifies WSL, MSYS2 and Cygwin as POSIX because they run bash", () => {
    expect(terminalShellFamily("wsl:Ubuntu")).toBe("posix");
    expect(terminalShellFamily("wsl:Debian")).toBe("posix");
    expect(terminalShellFamily("msys2")).toBe("posix");
    expect(terminalShellFamily("cygwin")).toBe("posix");
  });

  // `powershell` and `pwsh` both contain `sh`, so PowerShell must be matched
  // before the POSIX check or it would be quoted as a POSIX shell.
  test("does not mistake PowerShell for a POSIX shell", () => {
    expect(terminalShellFamily("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")).toBe(
      "powershell",
    );
  });

  test("falls back to cmd, the Windows default", () => {
    expect(terminalShellFamily(undefined)).toBe("cmd");
    expect(terminalShellFamily("some-unknown-shell")).toBe("cmd");
  });
});

describe("quoteTerminalPaths", () => {
  // Regression: double quotes are not literal in PowerShell or Git Bash, so
  // `report$(whoami).txt` executed `whoami`. Single quotes keep it literal.
  test("single-quotes paths for PowerShell so $(...) is not evaluated", () => {
    expect(quoteTerminalPaths(["report$(whoami).txt"], "powershell")).toBe(
      "'report$(whoami).txt'",
    );
  });

  test("single-quotes paths for Git Bash so $(...) is not evaluated", () => {
    expect(quoteTerminalPaths(["report$(whoami).txt"], "bash")).toBe("'report$(whoami).txt'");
  });

  // Regression: an unquoted Windows path lost its backslashes in Git Bash, so
  // `C:\work\proj\a.txt` became `C:workproja.txt`.
  test("keeps backslashes for Git Bash", () => {
    expect(quoteTerminalPaths([WINDOWS_PATH], "bash")).toBe("'C:\\work\\proj\\a.txt'");
  });

  test("escapes an apostrophe for PowerShell by doubling it", () => {
    expect(quoteTerminalPaths(["it's.txt"], "powershell")).toBe("'it''s.txt'");
  });

  test("escapes an apostrophe for POSIX shells outside the quotes", () => {
    expect(quoteTerminalPaths(["it's.txt"], "bash")).toBe("'it'\\''s.txt'");
  });

  // cmd has no literal string syntax; double quotes keep its operators from
  // being read as separators.
  test("double-quotes paths for cmd", () => {
    expect(quoteTerminalPaths(["README&whoami"], "cmd")).toBe('"README&whoami"');
    expect(quoteTerminalPaths([WINDOWS_PATH], "cmd")).toBe('"C:\\work\\proj\\a.txt"');
  });

  test("joins multiple paths with a single space", () => {
    expect(quoteTerminalPaths(["a.ts", "pkg"], "cmd")).toBe('"a.ts" "pkg"');
  });

  test("returns empty text for no paths", () => {
    expect(quoteTerminalPaths([], "cmd")).toBe("");
  });
});

describe("formatPathsForTerminal", () => {
  test("omits the trailing space by default so paste output stays exact", () => {
    expect(formatPathsForTerminal(["a.ts"], { shell: "cmd" })).toBe('"a.ts"');
  });

  // Drag-and-drop appends a space so what the user types next stays separate.
  test("appends a trailing space when dropping", () => {
    expect(formatPathsForTerminal(["a.ts"], { shell: "cmd", trailingSpace: true })).toBe(
      '"a.ts" ',
    );
  });

  test("does not produce a lone space when there are no paths", () => {
    expect(formatPathsForTerminal([], { shell: "cmd", trailingSpace: true })).toBe("");
  });

  // End-to-end guard from a real shell id to the inserted text: every shell the
  // product can launch must produce a literal path, and the two shells that
  // cannot express one (cmd percent expansion) are called out separately below.
  test.each([
    ["wsl:Ubuntu"],
    ["msys2"],
    ["cygwin"],
    ["bash"],
    ["powershell"],
    ["pwsh"],
  ])("keeps $(...) literal for the real shell id %s", (shellId) => {
    const text = formatPathsForTerminal([INJECTION_PATH], { shell: shellId });

    expect(text).toBe(`'${INJECTION_PATH}'`);
    expect(text).not.toMatch(/^"/);
  });
});

describe("formatDroppedPathsForTerminal", () => {
  // OS drags only carry absolute paths; quoting must still follow the shell so a
  // Git Bash drop is not read with the backslashes consumed.
  test("quotes an OS-dropped absolute path for Git Bash", () => {
    expect(formatDroppedPathsForTerminal([WINDOWS_PATH], "bash")).toBe("'C:\\work\\proj\\a.txt' ");
  });

  test("quotes an OS-dropped absolute path for cmd", () => {
    expect(formatDroppedPathsForTerminal([WINDOWS_PATH], "cmd")).toBe('"C:\\work\\proj\\a.txt" ');
  });

  test("ignores relative input because OS drags are absolute", () => {
    expect(formatDroppedPathsForTerminal(["src/Main.java"], "cmd")).toBe("");
  });
});
