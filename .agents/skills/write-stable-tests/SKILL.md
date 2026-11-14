---
name: write-stable-tests
description: Write and review deterministic, bounded Lithe tests and test infrastructure, including Viva desktop Go and shared Rust, and keep host tests free of any dependency on a concrete plugin. Use especially for concurrency, timers, polling, subprocess, watcher, lifecycle, or cancellation tests that could hang CI, and for any test that touches plugins.
---

# Write Stable Tests

Apply this Skill after `develop-lithe`. Its purpose is to make a broken test
fail locally with a useful diagnostic instead of waiting for a CI job timeout.

## Toolchain boundaries

- Viva desktop timing uses Go, Node.js and the existing Core build wrapper;
  macOS also uses `zsh`, while Windows uses PowerShell and Git Bash. Reuse an
  existing matching Core build instead of repeatedly performing cold builds.
- The old Swift and Tauri clients are absent on this branch. Their legacy timing
  scripts and historical reports do not prove Viva behavior or current CI coverage.
- Windows Rust scopes use Node.js plus Cargo. Windows `Frontend` additionally
  uses the repository's Bun toolchain because the product tests run under Bun;
  this dependency is isolated to that scope.

## Swift CI compatibility

- Compile tests with the same Swift toolchain as CI before handing them off. A
  local compiler that is newer or older can accept or reject syntax differently.
- A `weak` reference is mutable storage because the runtime may clear it;
  declare it as `weak var`.
- When a CI compile fails before tests start, inspect the CI compiler diagnostic
  first and reproduce the compile lane before diagnosing test timing or
  concurrency behavior.

## Read the platform guidance

- For Swift or macOS tests, read [references/macos-swift.md](references/macos-swift.md).
- For TypeScript, Tauri Rust, or shared Rust tests exercised by Windows, read
  [references/windows-and-rust.md](references/windows-and-rust.md).
- Read both references when a shared contract or cross-platform behavior changes.
- For HTML/JUnit output, performance budgets, or CI artifacts, read
  [references/test-reporting.md](references/test-reporting.md).

## Preserve these invariants

- Every wait has an explicit local deadline. The CI step timeout is never the
  first mechanism capable of terminating a stuck test.
- Do not use real-time sleeps to synchronize state. Inject a clock, scheduler,
  event, continuation, channel, or controllable test double.
- Do not move a blocking wait into a detached task merely to make an async test
  compile. Blocking a cooperative executor or main/UI thread is forbidden.
- Every spawned task, timer, process, thread, continuation, stream, and gate has
  one owner and a cleanup path that runs after assertion failures as well as
  success. Prefer `defer` or the framework's teardown mechanism.
- A concurrency test describes and controls its event order: operation starts,
  reaches the synchronization point, is released or cancelled, and terminates.
- Polling is a last resort. It must use a monotonic deadline, produce a useful
  timeout diagnostic, and poll an observable boundary rather than private state.
- Unit tests do not depend on real network services, installed developer tools,
  machine speed, personal paths, or wall-clock time. Put unavoidable external
  dependencies in an explicitly identified integration test.
- Assert observable behavior. Do not weaken production behavior, expose private
  state solely for a test, or delete a test to satisfy the stability gate.

## Plugins in host tests

Tests in this repository and in the Core repository have zero dependency on any
concrete plugin. The definitions, the allowed inputs and the self-check command
are in `develop-lithe`, section 三, “插件归属与宿主零依赖”; this section only
states what that means for writing a test.

- A host test never reads a concrete plugin's package, repository checkout,
  build output or manifest, whether through an environment variable, a fixed
  path, a download or a Git submodule. It never uses a real plugin ID and never
  asserts what a concrete plugin does.
- To exercise a generic extension point, write a synthetic manifest inline in
  the test with an obviously fictional ID such as `dev.lithe.test.<name>`, and
  back it with a test double you control. Core contract fixtures (through
  `LITHE_PLUGIN_CONTRACT_DIR`) and the marketplace index snapshot are the only
  other plugin inputs; assertions on the snapshot apply a rule to every entry,
  never to one entry by ID.
- A test that needs a real plugin is a plugin test. It lives in that plugin's
  repository and runs in that repository's CI against a pinned host or Core
  version. Skipping it when the plugin is absent does not make it acceptable in
  the host: it keeps plugin knowledge in the host and never runs in CI.

## Required workflow

1. Read the changed behavior, implementation, and nearby tests. Identify every
   asynchronous boundary and resource whose completion the test will await.
2. Choose deterministic synchronization before writing assertions. For a race
   regression, write the intended event sequence explicitly in the test or its
   test-double names.
3. Run the fast static gate before the test suite:

   ```bash
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --base origin/preview
   ```

   On Windows use:

   ```powershell
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1 -BaseRevision origin/preview
   ```

   Without `--base` the gate compares the working tree with `HEAD`; with
   `--base` it compares the committed `HEAD` (or `--head`) with that revision,
   which is what CI runs with the pull request base. The gate is a ratchet on
   blocking patterns in test code: a pattern is new when the base revision has
   no line with the same rule, enclosing test declaration, and statement text.
   Moving a test between files or re-indenting it is therefore not a violation,
   while adding a second sleep to a test that already had one is. After
   changing the gate scripts, run their self-test:

   ```bash
   node .agents/skills/write-stable-tests/scripts/test-verify-test-stability.mjs
   ```

   The current static scanner covers Swift, TypeScript and Rust, not Go.
   Passing it does not establish Go test stability: manually inspect Go waits,
   cancellation and cleanup, and run the Go timing and race checks below.

4. Run the platform timing harness. A changed test is not verified until its
   individual duration appears in the generated HTML and JUnit reports:

   ```bash
   ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --package ./internal/workbench -- --filter '<focused-test>'
   ./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo -GoPackages ./internal/workbench -GoTestPattern '<focused-test>'
   ```

   Go runs serially with `-count=1` and records Go's own per-test elapsed time;
   zero matching tests, unfinished tests, failures and budget overruns fail the
   runner. A suite deadline stops the process tree; individual durations are
   checked after Go reports them, rather than interrupting a buffered result.
   Parent and subtest durations overlap, so totals are not wall time.
   The former Swift/Frontend/WindowsRust scopes remain historical and cannot
   verify the removed clients; do not report their absence as a passing lane.

5. Run the broader affected validation required by `develop-lithe`. Report the
   HTML report path, slowest changed tests, exact commands, and any suite that
   could not run on the current platform. Open
   `.artifacts/test-stability/index.html` to review failures, module health, and
   performance warnings before handoff.

## Exceptions

Do not add a scanner exception merely to make the gate pass. If a real-time or
blocking primitive is unavoidable at a native synchronous boundary, keep it
off the cooperative executor, add a short local timeout, guarantee cleanup, and
place this annotation immediately above the relevant line:

```text
test-stability: allow(<rule-id>) reason: <why deterministic synchronization is impossible>
```

The reason must describe the architectural constraint, not restate the code.
New exceptions require explicit mention in the handoff.
