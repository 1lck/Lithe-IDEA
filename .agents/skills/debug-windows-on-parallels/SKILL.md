---
name: debug-windows-on-parallels
description: Build, test, run, and diagnose the Viva Windows desktop client from macOS through a local Parallels Windows VM. Use for Windows native verification, guest toolchain and log diagnosis, or transferring validation inputs to the VM; not for host-only source inspection.
---

# Validate Windows in the local Parallels VM

Apply `develop-lithe` first. Windows local builds, debugging, tests and native
interaction checks use the local VM. The former standalone Windows cloud server
has expired and is retired: do not reuse its connection details or credentials,
renew it, or provision another cloud host as a fallback. Existing GitHub Actions
Windows checks remain part of CI.

The current product is Viva desktop Go/cgo linked to Rust Core. The old
`windows/tauri/` client, Bun frontend, WebView2/CDP debugging and its build/log
paths are not current validation entry points. Host-only edits and static checks
do not require starting the VM.

## Discover the guest and build architecture

Before starting or resuming a guest, record its name and initial state:

```bash
prlctl list -a
```

Use `prlctl exec` for guest commands. Run builds, tests, Git operations and log
queries as the interactive user with `--current-user`; the default SYSTEM
context has different PATH, ownership and user data directories.

```bash
prlctl exec "<vm-name>" --current-user powershell.exe -NoProfile -Command 'whoami; Get-Command go,rustc,node,git; go env GOHOSTOS GOHOSTARCH GOOS GOARCH; rustc -vV'
```

- Record the guest OS/architecture, Go executable architecture, output target,
  toolchain and source revision. Discover paths; do not assume a username or VM
  name from a previous session.
- `scripts/desktop/desktop-go.sh` currently maps Windows `amd64` to
  `x86_64-pc-windows-gnu` and rejects Windows `arm64`. An ARM64 Windows guest on
  Apple Silicon must build and run the supported x64 client through Windows
  emulation; do not select ARM64/MSVC merely because the guest is ARM64.
- Verify x64 MinGW-w64 GCC with `gcc -dumpmachine`, the GNU Rust target, Go,
  Node.js and Git for Windows. Installer checks also need NSIS. Current build
  setup is documented by `.github/actions/setup-desktop-windows-build-tools/action.yml`
  and `.github/workflows/desktop-ci.yml`; inspect them before changing tools.
- An emulated x64 run verifies that configuration, not native AMD64 performance
  or native Windows ARM64 support. State the limit in the validation report.
- Use SYSTEM only for inspection that actually requires machine context. Do not
  globally relax Git ownership checks or change execution policy to conceal a
  wrong user context. SSH/WinRM and old cloud-server scripts are not the default
  transport for this workflow.

The desktop target mapping above does not constrain plugin backends. For a
plugin task, reuse the guest transport and lifecycle rules, and use the plugin
repository's own toolchain, targets and tests.

## Transfer a source snapshot and use guest-local build storage

Use an existing Parallels shared folder, commonly `\\psf\Home`, to transfer a
bounded source snapshot or archive into a guest-owned local checkout. Confirm
that the share exists; do not assume a different alias works in SYSTEM context.

- Keep the source revision and any uncommitted task changes identifiable.
  Preserve guest work; do not overwrite an unrelated checkout or running app.
- Run builds and tests on the guest's local filesystem. Keep Windows caches and
  mutable Core build state separate from macOS and other worktrees; follow the
  repository resource-reuse rules where applicable.
- Never transfer files as repeated base64 chunks through guest shell calls.
  If shared transfer is unavailable, report the missing route and use another
  existing supported transfer method rather than spawning an unbounded loop.

## Use the current desktop build and timing entries

In the guest checkout, establish the interactive user's toolchain PATH and use
Git for Windows Bash, not a WSL `bash.exe`. Set `GOARCH=amd64` and select the
verified x64 MinGW compiler for cgo. From the repository root:

```powershell
$env:GOARCH = 'amd64'
$env:CC = 'gcc'
& '<Git for Windows>\bin\bash.exe' ./scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe.exe ./cmd/lithe
& ./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo -GoPackages ./internal/core -GoTestPattern '<focused-test>'
```

Use `scripts/desktop/package-desktop.sh --arch amd64` through the same Git Bash
when the task needs a packaged client. Read its current options and inputs
before running it. Do not use removed Tauri build scripts or enable legacy test
scopes that still point to deleted directories. Run affected Rust tests inside
the actual linked Core checkout under that repository's current instructions.

For long commands, capture output and exit status in a task-owned log with a
suite deadline and process-tree cleanup. A detached `.cmd` wrapper must have an
owner, a completion/exit-code record and a bounded wait. Stop task-owned instances
before replacing their executable; do not terminate every matching app process.

## Collect evidence from the running client

- Current default Windows application logs come from
  `desktop/internal/logstore/dir_windows.go`: `%LOCALAPPDATA%\Lithe Desktop\Logs`.
  Respect a user-configured log location and collect the task session's records
  as the same user that ran Lithe. Follow the linked Core logging contract;
  do not import Tauri's former truncation, severity or flush assumptions.
- Plugin process logs and state come from that session's launch-provided
  writable directories and the plugin's own documentation. Do not guess a
  retired host-managed language-server cache path.
- UI changes require the headless screenshots attached to the PR under
  `develop-lithe` section 五. Native Windows window, ConPTY, installer and update
  checks still run in the guest when relevant; headless output is not a
  substitute for them.
- Report source revision, commands, exit codes, per-test HTML/JUnit reports,
  screenshots, architectures/emulation and any unverified behavior. Separate a
  guest environment or staging failure from a product defect using evidence.

## Restore the initial VM lifecycle

Keep the VM stopped during host-only coding. If this task started or resumed it,
stop task-owned Lithe, tests, language servers and helpers, collect their logs,
then request normal guest shutdown at the end of the Windows validation session,
on failure/cancellation, or when returning to host-only coding:

```bash
prlctl stop "<vm-name>"
prlctl list -a
```

Confirm `stopped` with bounded observation. If shutdown stalls, report the
remaining state and attempt bounded cleanup; do not force power-off and risk
user data. Preserve a VM that was already running for the user, or an explicit
request to keep it running, while cleaning up only this task's processes.
