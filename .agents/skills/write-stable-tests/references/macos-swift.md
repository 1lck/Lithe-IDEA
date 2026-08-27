# macOS and Swift Test Stability

The macOS harness requires only Swift, zsh, and Node.js. Bun is not installed,
loaded, or invoked anywhere in this path.

## Preferred synchronization

- Prefer actor-owned state, checked continuations, `AsyncStream`, injected
  clocks, and explicit callbacks over polling or sleeping.
- Keep `@MainActor` tests fully asynchronous. Never call a semaphore, condition
  variable, blocking file read, or process wait from the main actor.
- When a synchronous production protocol forces a blocking test double, run it
  only on the production-owned worker thread. Use `DispatchSemaphore.wait(timeout:)`
  on both sides of the gate, propagate timeout state into an assertion, and
  release the gate from `defer`.
- Cancellation tests must retain the task, trigger cancellation explicitly,
  await termination, and verify owned resources were released.

## Prohibited coordination

- Bare `DispatchSemaphore.wait()` or condition waits without a deadline.
- `Thread.sleep`, `usleep`, or `Task.sleep` used to give background work time to
  run. A zero-duration yield is still inferior to an observable event.
- `Task.detached { blockingWait() }.value`; this hides blocking and can exhaust
  executor threads.
- `Process.waitUntilExit()` without a watchdog that terminates the process tree.
- `while` polling loops without a monotonic deadline and timeout diagnostic.

## Timing and verification

Use `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh`. It forces serial execution so the
currently running test is unambiguous, records every Swift Testing/XCTest case,
warns about slow cases, and terminates the suite when one case exceeds its local
budget. Reports are written below `.artifacts/test-stability/`. Each run
produces JSON and raw logs for diagnosis, JUnit XML for CI tooling, and a
self-contained HTML report for module and performance review.

Run a focused test while iterating, then run the affected target or complete
lane. Do not claim that a test was timed if it is absent from the report.
