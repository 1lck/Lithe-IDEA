# Terminal shell discovery and selection

macOS and Windows own shell discovery, executable paths, environment setup, and
PTY/ConPTY startup. The portable scenarios are recorded in
[`shell-selection-v1.json`](../fixtures/terminal/shell-selection-v1.json). Discovery does not execute a shell, source a user profile,
start a WSL distribution, or create a terminal session.

Both products expose detected shells in the menu beside the terminal's New
button. Selecting a shell creates and activates a new session in the current
workspace. Existing sessions keep their selected shell and continue running.
The New button uses the saved default; changing that default affects subsequent
sessions only. A Detect Installed Shells action refreshes the catalog without
creating or restarting sessions. Windows also refreshes when opening the menu.

Missing installations and failed discovery do not erase saved preferences.
The last successful catalog remains visible after a refresh failure. A saved
shell selection keeps its identity until the user explicitly changes it; the
native launcher reports an unavailable shell rather than selecting a different
shell family. Paths remain native preference data, not portable workspace IDs.

macOS discovers executable files from the login-shell environment, `/etc/shells`,
PATH, and standard system/package-manager locations. Different installations of
the same shell remain selectable by path. The catalog recognizes zsh, bash,
fish, Nushell, PowerShell, sh, dash, ksh, tcsh, csh, and other registered login
shells. Existing `system`, `zsh`, and `bash` preferences remain compatible.

Windows preserves `cmd`, `powershell`, `pwsh`, `nu`, and `bash` IDs. Git Bash uses
the Git for Windows wrapper and remains distinct from `msys2` and `cygwin`.
Registered WSL distributions use `wsl:<distribution name>` IDs, sorted and
deduplicated; Docker/Rancher service distributions are omitted. WSL sessions
launched from local Windows workspaces receive the workspace as a separate
`--cd` argument, and the distribution name is passed as a separate argument.
This does not add WSL virtual filesystem support to other workspace features.

Terminal applications such as Windows Terminal and iTerm are not shell
profiles: sessions are hosted inside Lithe's existing terminal surface.
