# Test Stability Reports

## Outputs

Every timing runner writes these artifacts below `.artifacts/test-stability/`:

- `index.html` is the current runner dashboard. CI regenerates it as a combined
  dashboard after every selected lane in the job finishes.
- `<lane>.html` is a self-contained report for one Swift, Bun, or Rust lane.
- `<lane>.junit.xml` is the standard CI and IDE interchange report.
- `<lane>.json` is the normalized machine-readable timing source.
- `<lane>.log`, when available, contains the raw runner output.

The CI workflows upload the complete directory even when a test step fails.
Download the `test-stability-*` artifact and open `index.html`; it does not need
a server or external assets.

## Interpretation

The dashboard separates correctness from performance:

- `failed`, `error`, `timeout`, and `incomplete` are stability failures.
- A duration at or above `maxMs` exceeds the hard performance budget and is
  emitted as a JUnit failure even when the underlying assertion passed.
- Swift tests have a separate `terminateMs` deadline. Crossing `maxMs` reports
  the actionable budget error immediately; only `terminateMs` stops the test
  process tree so failure diagnostics have time to flush.
- A duration at or above `warnMs` but below `maxMs` is a performance warning.
  It remains a passing JUnit case but appears in the optimization queue.
- Faster passing cases are healthy. Skipped cases are reported separately.

Module health is derived from Swift Testing suites, Bun JUnit classes, and Rust
crate/module paths. Do not infer a production bottleneck from one slow test.
First determine whether the cost is test setup, external I/O, subprocess work,
or the behavior under test, then optimize the owning boundary.

## Regenerating HTML

The timing runners regenerate their own reports automatically. To intentionally
rebuild a combined HTML and JUnit view from every JSON file in the directory,
run:

```bash
node .agents/skills/write-stable-tests/scripts/generate-test-report.mjs
```
