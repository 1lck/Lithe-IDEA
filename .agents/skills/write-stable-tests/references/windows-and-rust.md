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

SharedRust explicitly runs `lithe-agent-host`, `lithe-git-host`, and `lithe-core`, keeping the
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
The specific
`tests::git_history_rewrite::native_rebase_skip_omits_conflicted_message_from_later_squash`
case gets 45 seconds in both SharedRust and real-JDT: it creates six commits,
reorders them into a conflict, skips the conflict and checks the final squash.
Windows run 38698271030 hit its 30-second process deadline without an assertion
failure; a clean rerun completed the same case in 9.2 seconds. The enclosing
suite deadline and Core's nested 20-second request deadline remain in force.
The `tests::git_patch_exchange::patch_metadata_can_list_an_oversized_export_before_selecting_a_small_subset`
case also gets 30 seconds because it writes and inspects a real file larger
than the 32 MiB patch limit; Windows CI terminated it at 16.1 seconds under
the default 15-second limit. The `tests::git_patch_exchange::` cases for hidden
destination edits, stale previews, rename/delete/file-mode roundtrips, and
index/binary snapshot roundtrips each get 30 seconds: their real-Git setup and
multiple preview/apply operations measured 19 to 24 seconds on Windows and
reached the default 15-second watchdog again without a concurrent build.
`patch_exchange_reverse_roundtrip_preserves_both_versions_and_untracked_bytes`
gets 60 seconds after measuring 52.7 seconds across four preview/apply cycles.
The retained-path Shelf roundtrips (`shelf_roundtrip_preserves_staged_deletions_with_retained_paths`
and `shelf_roundtrip_preserves_staged_rename_with_recreated_source`) use the same
60-second allowance for four preview/apply cycles; the deletion and rename
cases measured 51.8 and 54.9 seconds on Windows. `patch_exchange_distinguishes_sources_and_commit_direction`
gets 30 seconds after its real-Git source exports passed assertions but took
15.1 seconds under the default 15-second process budget.
Each patch request still has its own 15-second deadline, and the enclosing
suite deadline remains unchanged. Both SharedRust and the real-JDT lane use
these narrowly scoped budgets. Core rebase requests use a nested 20-second
deadline. The workspace commit submodule publication test also gets 30 seconds
because it creates two local remotes and runs multiple real Git pushes. Other
multi-repository coverage includes
`tests::git::git_write_updates_a_noncurrent_branch_without_switching_head`,
which also gets 30 seconds in both SharedRust and real-JDT lanes: it builds a
bare remote and two working repositories, pushes and fetches commits, then
checks branch updates with an attached and detached HEAD. A Windows real-JDT
run reached the 15-second process deadline during this case, while the same
revision passed it in 2.4 seconds in SharedRust. The `tests::git_remote_checkout::`
module also gets 30 seconds in both lanes: each case clones a real remote,
fetches through Core, and runs about 30 Git subprocesses for setup and
snapshots. Its cases usually finish in 5 to 7 seconds on Windows, but one
real-JDT run reached the 15-second process deadline in
`remote_checkout_force_updates_the_current_branch` without an assertion
failure. This scoped allowance covers
native process and filesystem variability without changing assertions; other
cases retain the normal 15-second budget. The Rust runner's repeatable
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
