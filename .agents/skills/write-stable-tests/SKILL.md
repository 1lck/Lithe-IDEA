---
name: write-stable-tests
description: Write and review deterministic, bounded Lithe tests for macOS Swift, Windows TypeScript, and Rust. Use whenever creating, modifying, or reviewing test code or test infrastructure, especially concurrency, timers, polling, subprocess, watcher, lifecycle, or cancellation tests that could hang CI.
---

# Write Stable Tests

Apply this Skill after `develop-lithe`. Its purpose is to make a broken test
fail locally with a useful diagnostic instead of waiting for a CI job timeout.

## Toolchain boundaries

- macOS uses Swift, `zsh`, and Node.js. It does not require Bun, `npm`, or a
  JavaScript package installation for stability checks, timing, JUnit output,
  or HTML report generation.
- Windows Rust scopes use Node.js plus Cargo. Windows `Frontend` additionally
  uses the repository's Bun toolchain because the product tests run under Bun;
  this dependency is isolated to that scope.

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

## Required workflow

1. Read the changed behavior, implementation, and nearby tests. Identify every
   asynchronous boundary and resource whose completion the test will await.
2. Choose deterministic synchronization before writing assertions. For a race
   regression, write the intended event sequence explicitly in the test or its
   test-double names.
3. Run the fast static gate before the test suite:

   ```bash
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
   ```

   On Windows use:

   ```powershell
   ./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
   ```

4. Run the platform timing harness. A changed test is not verified until its
   individual duration appears in the generated HTML and JUnit reports:

   ```bash
   ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter '<focused-test>'
   ./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend
   ./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust
   ```

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
