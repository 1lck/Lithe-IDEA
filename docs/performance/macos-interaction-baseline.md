# macOS Interaction Baseline

Issue #490 provides the repeatable measurement entry point for the #467
performance work. The product stays unchanged unless the baseline environment
variable is set.

## Fixed matrix

| ID | Scenario | Fixture |
| --- | --- | --- |
| T | Continuous typing for 10 seconds, then pause for 2 seconds | 10 KiB, 500 KiB, 2 MiB |
| N | Open the large file and stay idle for 10 seconds | 500 KiB |
| D | Drag the sidebar, bottom bar, Git Log, Run, Tests, and Diff splitters | 500 KiB |
| S | Toggle Search Everywhere 20 cold and 20 warm times | 500 KiB |
| Term | Produce terminal output for 10 seconds | 500 KiB |
| R | Produce Run/Tests output for 10 seconds | 500 KiB |

## Run

List the matrix:

```sh
scripts/measure-macos-performance-baseline.sh --list
```

Run three Release startup sessions for a scenario and fixture:

```sh
scripts/measure-macos-performance-baseline.sh \
  --scenario T \
  --fixture 500KiB \
  --runs 3
```

For the interactive scenarios, keep the process alive while carrying out the
actions in the table:

```sh
scripts/measure-macos-performance-baseline.sh \
  --scenario D \
  --fixture 500KiB \
  --runs 3 \
  --interactive
```

The script writes a TSV report and prints the median resident set size. Use
Instruments' Points of Interest template to inspect the `editor.input`,
`appmodel.relay`, `split.drag`, and `search.everywhere` signposts. The baseline
mode disables `FrameRateMonitor`, whose per-vsync MainActor task would otherwise
pollute the interaction trace.
