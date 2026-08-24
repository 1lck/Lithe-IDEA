---
name: debug-windows-on-parallels
description: Build, run, and diagnose the Windows Tauri product from a macOS host through a Parallels Windows VM. Use when a task requires building windows/, reproducing Windows-only behavior, reading Windows application or JDTLS logs, or transferring files into the Windows VM.
---

# Debug Windows on Parallels

The Windows product cannot be built or exercised on macOS directly. This Skill
covers the host-to-guest workflow: what channel to use, which failures are
environmental rather than code defects, and where Windows-side diagnostics live.

Only load this Skill when the task actually reaches into the VM. Editing
`windows/` source and running `verify-windows-boundaries.sh` on macOS needs
nothing from here.

## Reach the VM through prlctl, not SSH

`prlctl` is the only reliable channel. SSH into the guest requires an
interactive password and cannot be scripted.

```bash
prlctl list                                        # names and run state
prlctl exec "<vm-name>" cmd /c "..."
prlctl exec "<vm-name>" powershell -Command "..."
```

`prlctl exec` runs as `NT AUTHORITY\SYSTEM`, not the logged-in user. Three
consequences follow, and all three look like "the tool is not installed":

- The user `PATH` is invisible. `bun`, `cargo`, `rustup`, and `node` all appear
  missing. Invoke them by absolute path, or set `PATH` inside a `.cmd` wrapper.
- `git` reports `detected dubious ownership` because the checkout belongs to the
  interactive user. Pass `-c safe.directory=<path>` or configure it globally in
  the guest once.
- `winget` is unavailable. Install guest tooling interactively instead.

PowerShell in the guest emits localized text that arrives as mojibake on the
macOS side. Match on timestamps, severities, and English identifiers; do not try
to read localized error prose.

## Transfer files over the Parallels shared folder

The macOS home directory is mounted in the guest at `\\psf\Home`. Copy through
it in a single call:

```bash
prlctl exec "<vm-name>" powershell -Command "
Copy-Item '\\\\psf\\Home\\<path-under-home>' 'C:\<guest-path>' -Force
"
```

Use `\\psf\Home`, not `\\Mac\Home`; the latter is not resolvable from the
`SYSTEM` context.

Never chunk file contents through repeated `prlctl exec` calls (for example
base64 in a shell loop). Every call spawns a guest PowerShell process; a handful
of files is enough to exhaust guest resources, stall the host, and generate
large amounts of disk writes. If a shared folder is genuinely unavailable, stop
and ask rather than looping.

## Build through a guest .cmd wrapper

Write a `.cmd` file in the guest that establishes the environment, then run it
detached with output redirected to a log:

```cmd
@echo off
set "PATH=C:\Program Files\LLVM\bin;C:\Users\<user>\.cargo\bin;C:\Users\<user>\.bun\bin;%PATH%"
set "CARGO_HOME=C:\Users\<user>\.cargo"
set "RUSTUP_HOME=C:\Users\<user>\.rustup"
cd /d C:\<repo>
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build-windows.ps1" -Configuration Debug -RustTarget aarch64-pc-windows-msvc
echo === exit: %ERRORLEVEL% ===
```

```bash
prlctl exec "<vm-name>" cmd /c "start /min cmd /c \"C:\\<build>.cmd > C:\\<build>.log 2>&1\""
```

Driving the build from `cmd` with `cmd`-level redirection is deliberate.
`build-windows.ps1` sets `$ErrorActionPreference = "Stop"`, and `rustup` and
`bun` write progress to stderr; under PowerShell redirection those become
terminating `NativeCommandError`s and the build fails while the underlying
command succeeded. A build that dies immediately after a tool prints a normal
informational line is this, not a real failure — check the tool standalone
before treating it as a code defect.

Other environmental failures worth recognizing:

- **Wrong target.** On Apple Silicon the guest is ARM64, so pass
  `-RustTarget aarch64-pc-windows-msvc`. The script's default is x86_64.
- **Script execution blocked.** First run needs
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force` in the guest.
- **`Access is denied` removing the exe.** The app is still running. Stop it
  first: `Get-Process -Name '<product>' -ErrorAction SilentlyContinue | Stop-Process -Force`.
- **Missing native toolchain.** Some crates require `clang`; the guest may have
  LLVM installed without it being on the `SYSTEM` `PATH`. Add
  `C:\Program Files\LLVM\bin` to the wrapper's `PATH`.
- **Shared crate edits not picked up.** Cargo compares mtimes, and a file
  written through the shared folder can keep an older timestamp. Touch it:
  `(Get-Item <path>).LastWriteTime = Get-Date`. Confirm the intended crate
  actually recompiled by grepping the build log for its `Compiling` line.
- **Debug builds omit bundled language servers.** `build-windows.ps1` stages
  them only for Release. Mirror them into the Debug profile when a Debug build
  must exercise language features:
  `robocopy <target>\release\LanguageServers <target>\debug\LanguageServers /E /NFL /NDL /NJH /NP`.

## Read Windows-side diagnostics

Application logs live under the product's `LOCALAPPDATA` directory; the most
recently written file is the current session.

```bash
prlctl exec "<vm-name>" powershell -Command "
\$f = Get-ChildItem 'C:\Users\<user>\AppData\Local\<bundle-id>\logs\' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
Select-String -Path \$f -Pattern 'error' | Select-Object -Last 20 | ForEach-Object { \$_.Line }
"
```

Know what the log will and will not show before concluding a feature is broken.
Per `windows/tauri/src-tauri/src/logging.rs`:

- `Debug`-level records are dropped unless diagnostic logging is enabled for the
  session (Settings → Logs). Enable it *before* reproducing, or the most useful
  records will not exist.
- The sanitizer rewrites absolute paths to `<redacted_path>` and redacts field
  values whose key looks credential-like. Keys containing `token` are caught by
  this, so some benign fields read as `<redacted>`.
- Lines are truncated at 4 KB, which cuts the tail off long React component
  stacks.
- Only `Warn` and above are flushed synchronously, so a hard crash can lose the
  last few `Info` records.

Frontend stack traces from a production build are minified. Inline source maps
do **not** fix this: V8 does not apply source maps when building
`Error.stack` — that is devtools-only behavior. Readable frames require devtools,
which needs the `devtools` feature on the `tauri` crate; a `--debug` build alone
does not enable it.

Language-server internals are not in the application log. JDTLS keeps its own
log at
`<LOCALAPPDATA>\<bundle-id>\language-servers\jdtls\<hash>\.metadata\.log`.
Maven import results, classpath resolution, and index read/write failures appear
only there. A `ProjectRegistryRefreshJob finished` time in single-digit
milliseconds means no build system was actually imported.

## Match the diagnosis to the layer

Before changing product code, place the symptom:

- **Guest environment** — missing `PATH`, ownership, execution policy, target
  triple, locked exe. Fix the harness, not the product.
- **Build staging** — a resource the Debug profile never received. Check what
  `build-windows.ps1` stages per configuration.
- **Durable language-server state** — JDTLS keeps per-workspace state that it
  never invalidates itself. A workspace whose structure changed can keep
  resolving against a stale project model, which presents as navigation and
  highlighting working for some files and not others.
- **Product defect** — only after the three above are excluded.

State which layer the evidence supports. When a check could not run on the
current machine, say so rather than implying it passed.

## Search tools in this environment

`grep` is proxied and does not behave like GNU grep for absolute paths or `\|`
alternation. Prefer `rg -n "a|b"` with an unescaped pipe, or run separate
patterns.
