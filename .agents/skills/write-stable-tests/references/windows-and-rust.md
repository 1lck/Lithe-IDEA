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
report. One suite deadline covers compilation, enumeration, every test process,
and the clean cache retry; a timeout writes the completed records before the
runner exits. This isolation makes the exact hanging test visible.

SharedRust explicitly runs both `lithe-git-host` and `lithe-core`, keeping the
native Git process/AskPass tests in `git-host-rust.json` and Core tests in
`shared-rust.json`. Testing a Cargo package does not run its dependencies' own
tests. macOS's `verify-rust-core.sh` runs the same native adapter timing lane.

Every Bun and Rust lane writes JUnit XML plus a self-contained HTML dashboard
below `.artifacts/test-stability/`. The dashboard groups Rust cases by crate
module and Bun cases by their JUnit class or suite.

History-rewrite integration tests create and rewrite real repositories with many
Git subprocesses, sometimes rebuilding several repositories in one case. The
SharedRust lane assigns the `tests::git_history_rewrite::` module and the older
`tests::git::git_write_squashes_`, `git_write_deletes_a_local_commit_`, and
`git_write_edits_a_local_commit_message_` scenarios a 30-second process budget.
Core rebase requests use a nested 20-second deadline. Other cases retain the
normal 15-second budget. The Rust runner's repeatable
`--test-budget prefix=milliseconds` option uses the most specific matching
prefix, records each case's effective budget in JSON, uses that budget for
HTML/JUnit classification, and remains capped by the shared suite deadline.
Use scoped budgets only for measured
integration costs, never to bypass an unbounded wait or an assertion failure.

## Windows verification

Run the PowerShell harness in a real Windows environment. A macOS boundary
check does not verify Bun timers, Windows process termination, or native Rust
test execution. When using the Parallels guest, establish the user toolchain
paths before invoking the script as required by `debug-windows-on-parallels`.
