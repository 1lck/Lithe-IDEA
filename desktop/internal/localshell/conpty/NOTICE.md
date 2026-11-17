# Windows local-terminal ConPTY

These are the unmodified Windows binaries from Microsoft's
[`Microsoft.Windows.Console.ConPTY`](https://www.nuget.org/packages/microsoft.windows.console.conpty)
package, version **1.25.260930003**, built from
[microsoft/terminal](https://github.com/microsoft/terminal) release v1.25.2733.0 and
MIT licensed (see `LICENSE.txt`, the repository's license at that tag).

The Lithe desktop client's local Windows terminal loads this `conpty.dll` instead of the
inbox ConPTY in kernel32. The inbox one re-renders the program's output and consumes its
color queries and mouse modes: a synchronized update (DECSET 2026) is painted again after
its end marker, OSC 10/11 never reach the terminal parser, and a full-screen program's
mouse reporting is lost. The package's ConPTY forwards the program's stream instead. Using
it follows Motty d61d1910 (see `desktop/internal/termview/NOTICE`); the retired Tauri
client of Lithe shipped the same binaries.

## Files

| File | Package path | SHA-256 |
| --- | --- | --- |
| `win-x64/conpty.dll` | `runtimes/win-x64/native/conpty.dll` | `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a` |
| `win-arm64/conpty.dll` | `runtimes/win-arm64/native/conpty.dll` | `151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf` |
| `x64/OpenConsole.exe` | `build/native/runtimes/x64/OpenConsole.exe` | `3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586` |
| `arm64/OpenConsole.exe` | `build/native/runtimes/arm64/OpenConsole.exe` | `4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f` |

The `.nupkg` downloaded from nuget.org is SHA-256
`02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee`.

`conpty.dll` matches the program's architecture. `OpenConsole.exe` matches the Windows
kernel's architecture, and `conpty.dll` looks for `x64\OpenConsole.exe`,
`arm64\OpenConsole.exe` or `x86\OpenConsole.exe` beside itself (the layout of the
package's MSBuild targets). An x64 client therefore also carries the arm64 console host,
for x64 Lithe on Windows on ARM.

## How the client uses them

The files are compiled into the Windows executable (`go:embed` in this package, for
windows/amd64 and windows/arm64), so the installation directory holds no ConPTY files and
stays byte-identical to the release. On the first terminal start of a process, the
client writes its architecture's set, with `LICENSE.txt`, to
`<user cache>\Lithe\conpty\<digest>\` (`%LocalAppData%\Lithe\conpty\...`), named by the
digest of the set, and loads `conpty.dll` from there. A folder that already holds the same
bytes is reused; a missing or different file is replaced atomically. If the folder cannot
be written or the DLL cannot be loaded, the terminal runs on the inbox ConPTY and the log
records `app.background.operation_failed` with operation `terminal_conpty`. See the
package documentation in `conpty.go`.

## Updating

Replace the files and this table together. Download the package from nuget.org into an
empty folder, check its SHA-256, and compare each file with the package path above and
its PE machine type before copying; never run anything from the download.
`TestTheConPTYFolderMatchesItsNotice` checks the table, the files and their machine
types. A new set gets a new digest folder, so a running client of the previous release
keeps its own.
