# Windows desktop Go and Core Rust test stability

## Run local Windows verification in the VM

Use the local Windows VM under [debug-windows-on-parallels](../../debug-windows-on-parallels/SKILL.md).
The former standalone cloud server is retired. Existing GitHub Actions Windows
checks remain in CI; historical cloud measurements are not a current execution
route or evidence for this revision.

Record guest and output architectures, emulation, source revision and toolchain.
Run as the interactive user with the correct Go, GNU Rust target, MinGW-w64 GCC,
Node.js and Git for Windows Bash. The current desktop wrapper supports Windows
amd64; an ARM64 guest does not establish native Windows ARM64 client support.

## Time current desktop Go tests

From the guest checkout:

```powershell
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo -GoPackages ./internal/core -GoTestPattern '<focused-test>'
```

The harness resolves Git for Windows Bash and invokes
`scripts/desktop/desktop-go.sh` with serialized Go execution, explicit test and
suite deadlines and per-test reporting. Inspect HTML/JUnit results under
`.artifacts/test-stability/`; zero matches or an unfinished test are failures.
The wrapper selects the pinned Core and its fixtures. Do not bypass it with an
unconfigured `go test` or compare against a different Core revision.

For concurrency tests, use channels and controllable events; bound channel
receives, cancellation and completion. Give each goroutine and subprocess an
owner and teardown path. Do not coordinate with real sleeps or wait on the UI
thread. Run the affected packages with the race detector where the target
Windows toolchain supports it; report an unavailable race lane explicitly.

UI changes also require actual headless screenshots attached to the PR under
`develop-lithe` section 五. Native windows, ConPTY, installation and updates need
their Windows workflow checks in addition to headless output.

## Run Rust tests where the implementation lives

Shared rules and their tests belong to the external Core checkout linked by the
desktop wrapper. Follow that checkout's current `AGENTS.md`, crate layout and
bounded timing entries. Do not re-create `rust/` in this host repository or copy
Core/plugin tests back into the desktop host.

- Prefer channels, barriers and injected clocks over `thread::sleep`; coordination
  receives need `recv_timeout` or an equivalent bounded operation.
- Join a worker only after a bounded signal proves it is terminating. Teardown
  must release gates and reclaim tasks and child process trees on failure too.
- A child requires a watchdog and process-tree termination; reading to EOF or
  calling `wait` alone is not a timeout strategy.
- Avoid shared environment mutation. If unavoidable, serialize it and restore
  the previous value during teardown.
- Choose narrow budgets from measurements of the current test and environment,
  retaining the enclosing suite deadline and in-test deadlines. Never increase
  a budget to conceal a hang or retry a failed assertion as cache recovery.

## Keep retired test scopes out of current instructions

The retained PowerShell harness still has legacy `Frontend`, `WindowsRust`,
`SharedRust*` and `All` branches referencing deleted `windows/tauri/` or host
`rust/` directories. Their old Bun/Rust budgets and cloud reports do not verify
the current Viva client. Executor cleanup is tracked in
[#1940](https://github.com/1lck/Lithe-IDEA/issues/1940). Do not select these branches, infer a passing lane from
missing files, or change an old timeout solely to make a new run pass. Use
`DesktopGo` and the actual external Core test entry points.

At the end of the session, clean up task-owned processes and restore the VM's
initial lifecycle as required by the VM Skill. An x64 run emulated on ARM64 must
be identified as such; it is not a native AMD64 performance baseline.
