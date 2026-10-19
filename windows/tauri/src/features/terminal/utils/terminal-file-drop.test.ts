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

  // WSL runs Linux, so a Windows drive path has to reach the distribution in its
  // `/mnt/<drive>` form. Quoting alone left `C:\work\a.txt` unreadable there.
  test("translates a Windows path for a WSL distribution", () => {
    expect(formatPathsForTerminal(["C:\\work\\proj\\a.txt"], { shell: "wsl:Ubuntu" })).toBe(
      "'/mnt/c/work/proj/a.txt'",
    );
  });

  test("keeps the distribution namespace for a WSL path that is already Linux", () => {
    expect(formatPathsForTerminal(["/home/me/a.txt"], { shell: "wsl:Ubuntu" })).toBe(
      "'/home/me/a.txt'",
    );
  });
});

// Nushell single-quoted strings have no escape for `'`, and its backtick form is
// a quoted identifier rather than a string literal, so a name containing `'` has
// no literal representation and is dropped instead of being emitted bare.
describe("Nushell quoting", () => {
  test("single-quotes a path so backslashes and $() stay literal", () => {
    expect(formatPathsForTerminal(["C:\\work\\a.txt"], { shell: "nu" })).toBe("'C:\\work\\a.txt'");
    expect(formatPathsForTerminal(["C:\\work\\report$(whoami).txt"], { shell: "nu" })).toBe(
      "'C:\\work\\report$(whoami).txt'",
    );
  });

  // A backtick is an identifier delimiter in Nushell, not a raw-string quote, so
  // it must not be used to wrap a path.
  test("does not wrap a path in backticks", () => {
    const text = formatPathsForTerminal(["C:\\work\\a`b.txt"], { shell: "nu" });
    expect(text).toBe("'C:\\work\\a`b.txt'");
    expect(text.startsWith("`")).toBe(false);
  });

  test("drops a name containing a single quote because Nushell cannot escape it", () => {
    expect(formatPathsForTerminal(["C:\\work\\it's.txt"], { shell: "nu" })).toBe("");
    expect(formatPathsForTerminal(["C:\\work\\a`it's.txt"], { shell: "nu" })).toBe("");
  });
});

// Remote workspaces store frontend `remote://` URIs. Handing that URI to a shell
// inserts something that looks like a path and opens nothing, so it is converted
// only for the connection that owns the terminal and dropped otherwise.
describe("remote workspace paths", () => {
  test("strips the protocol for the connected host", () => {
    expect(
      quoteTerminalPaths(["remote://conn/home/me/a.txt"], "bash", {
        remoteConnectionId: "conn",
      }),
    ).toBe("'/home/me/a.txt'");
  });

  // Inserting the URI would be silently wrong, and inserting nothing is safer
  // than pointing the user at a path that cannot exist there.
  test("drops a path from a different connection", () => {
    expect(
      quoteTerminalPaths(["remote://other/home/me/a.txt"], "bash", {
        remoteConnectionId: "conn",
      }),
    ).toBe("");
    expect(
      quoteTerminalPaths(["remote://conn/home/me/a.txt"], "bash", {
        remoteConnectionId: null,
      }),
    ).toBe("");
  });

  test("keeps a local path untouched on a local terminal", () => {
    expect(quoteTerminalPaths(["C:\\work\\a.txt"], "cmd")).toBe('"C:\\work\\a.txt"');
  });
});

// PowerShell treats the typographic single quotes U+2018, U+2019, U+201A and
// U+201B as string delimiters too. Verified by executing an injection inside the
// quoted path and observing its side effect — a file named
// `report’;whoami;#.txt` ended the literal and ran the injected statement.
// Escaping only ASCII `'` therefore left a command-injection hole open.
describe("typographic single quotes that PowerShell treats as delimiters", () => {
  for (const [name, codePoint] of [
    ["left single quote U+2018", 0x2018],
    ["right single quote U+2019", 0x2019],
    ["single low quote U+201A", 0x201a],
    ["reversed single quote U+201B", 0x201b],
  ] as const) {
    test(`doubles the ${name} so it cannot end the literal`, () => {
      const quote = String.fromCodePoint(codePoint);
      const text = formatPathsForTerminal([`C:\\work\\report${quote}X.txt`], {
        shell: "powershell",
      });

      expect(text).toBe(`'C:\\work\\report${quote}${quote}X.txt'`);
    });
  }

  test("doubles the ASCII apostrophe as well", () => {
    expect(formatPathsForTerminal(["C:\\work\\it's.txt"], { shell: "powershell" })).toBe(
      "'C:\\work\\it''s.txt'",
    );
  });

  // These two are not PowerShell delimiters, so doubling them would corrupt the
  // file name instead of protecting it — pin that they stay as written.
  for (const [name, codePoint] of [
    ["fullwidth apostrophe U+FF07", 0xff07],
    ["prime U+2032", 0x2032],
  ] as const) {
    test(`leaves the ${name} as written for PowerShell`, () => {
      const quote = String.fromCodePoint(codePoint);
      const text = formatPathsForTerminal([`C:\\work\\report${quote}X.txt`], {
        shell: "powershell",
      });

      expect(text).toBe(`'C:\\work\\report${quote}X.txt'`);
    });
  }

  // POSIX shells only treat ASCII `'` as a delimiter, so the typographic quotes
  // must not be doubled there or the path would no longer match the file.
  test("does not double typographic quotes for POSIX shells", () => {
    const quote = String.fromCodePoint(0x2019);
    expect(formatPathsForTerminal([`/home/me/report${quote}X.txt`], { shell: "bash" })).toBe(
      `/home/me/report${quote}X.txt`.replace(/^/, "'").replace(/$/, "'"),
    );
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

  // Regression: quoting can drop every path, and the trailing space was appended
  // regardless, so an OS drop of a name the shell cannot represent inserted a
  // lone space into the prompt.
  test("emits nothing when quoting drops every dropped path", () => {
    expect(formatDroppedPathsForTerminal(["C:\\work\\a`it's.txt"], "nu")).toBe("");
  });
});
