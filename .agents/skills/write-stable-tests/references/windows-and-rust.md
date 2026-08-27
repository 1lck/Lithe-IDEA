# Windows, TypeScript, and Rust Test Stability

Bun is a Windows Frontend test-runtime dependency only. The report generator,
static verifier, Swift runner, and Rust runner are Node.js-only.

## TypeScript and Bun

- Inject timer functions or a scheduler and advance them manually. The
  `ManualTimer` pattern in the nearby Windows tests is preferred for debounce,
  cooldown, retry, and delayed-work behavior.
- Use deferred promises only when the test controls every resolution path.
  Release or reject pending deferred work in teardown after an assertion fails.
- Flush a known microtask boundary with resolved promises when necessary. Do
  not use real `setTimeout` calls to wait for application state.
- Never leave intervals, listeners, subscriptions, workers, or mocked native
  operations active after a test.

The Windows timing harness passes an explicit timeout to Bun and reads the
JUnit duration for every executed test case.

## Rust

- Prefer channels, barriers, and injected clocks to `thread::sleep`. Channel
  receives used for coordination require `recv_timeout` or an equivalent
  bounded operation.
- A thread may be joined only after a bounded signal proves that it reached a
  terminating path. Keep cleanup capable of releasing all barriers and killing
  child processes.
- Test subprocesses require a watchdog and process-tree termination. Reading to
  EOF or calling `wait` is not a timeout strategy.
- Avoid shared global environment mutation. If unavoidable, serialize access
  with an owned guard and restore the previous value in teardown.

`./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust` and `-Scope SharedRust`
compile the selected Cargo tests once, enumerate the produced test binaries,
then run every test case individually with a process-level timeout and duration
report. This isolation makes the exact hanging test visible.

Every Bun and Rust lane writes JUnit XML plus a self-contained HTML dashboard
below `.artifacts/test-stability/`. The dashboard groups Rust cases by crate
module and Bun cases by their JUnit class or suite.

## Windows verification

Run the PowerShell harness in a real Windows environment. A macOS boundary
check does not verify Bun timers, Windows process termination, or native Rust
test execution. When using the Parallels guest, establish the user toolchain
paths before invoking the script as required by `debug-windows-on-parallels`.
