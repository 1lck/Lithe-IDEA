# Lithe Agent Entry Point

Before any work in this repository, load and follow the `develop-lithe` skill
at `.agents/skills/develop-lithe/SKILL.md`. That skill is the single source of
truth for AI coding and verification rules, including the required Rust Core
comment standard.

If a task creates, modifies, or reviews test code or test infrastructure,
additionally load `.agents/skills/write-stable-tests/SKILL.md` before
proceeding. That skill defines the mandatory bounded-wait, deterministic-time,
cleanup, and per-test timing rules for both macOS and Windows.

If a task prepares, validates, or publishes a stable Lithe release,
additionally load `.agents/skills/release-lithe/SKILL.md` before changing
release notes, version metadata, tags, or release workflows.

If the task involves building, running, diagnosing, or transferring files to the
Windows product through a Parallels guest VM, additionally load
`.agents/skills/debug-windows-on-parallels/SKILL.md` before proceeding.

## Test Process Lifecycle and Cleanup

Unless the user gives a specific instruction to keep a process running, any
Lithe application started for building, testing, debugging, previewing, or
verification must be shut down when the task or test run is complete. Clean up
all child processes, helper processes, temporary app instances, and related
resources, then verify that no Lithe processes remain before handing the work
back. Do not launch duplicate Lithe instances during repeated checks, and do
not leave test-built applications open in the user's application list. If a
process cannot be stopped cleanly, report it explicitly and make a bounded
best-effort cleanup before continuing.

## High-Performance UI Interaction and Resizable Layout Requirements

When working on draggable splitters, resizable panels, continuous dragging,
scrolling, or other high-frequency UI interactions, prioritize reusing the
project's existing high-performance layout containers and interaction
components. Do not quickly implement these behaviors by stacking custom
`DragGesture` handlers in a business parent view, writing to multiple `@State`
properties on every event, or duplicating splitter logic.

- Resizable macOS panels must use `LitheSplitPaneView` and `SplitHandleView`
  whenever possible. If they genuinely cannot be reused, explain why in the
  change summary and preserve the same behavioral contract.
- Drag handling must use a stable coordinate space, preferably global
  coordinates for continuous dragging, to prevent the moving splitter from
  changing the coordinate origin and causing jumps.
- High-frequency drag events must be throttled, coalesced, or filtered with a
  dead zone. Do not trigger unnecessary parent-view reconstruction on every
  pointer event. Keep mutable size state in a local layout container whenever
  possible so dragging does not recompute the entire feature page.
- Provide explicit minimum and maximum sizes and available-space constraints so
  adjacent panels retain their minimum usable widths. Window resizing, panel
  hiding, and panel restoration must not produce negative sizes or layout
  overflow.
- Interaction behavior should match existing Git, editor, and tool windows,
  including hover/drag highlighting, the platform-appropriate resize cursor,
  help text, and accessibility labels.
- If sizes must persist across refreshes or restarts, commit the final size
  through the existing layout-persistence mechanism rather than continuously
  writing to persistent storage during dragging.
- After adding or modifying this type of UI, at minimum complete the relevant
  product build, `git diff --check`, and boundary checks. During code review,
  explicitly confirm that dragging does not cause high-frequency full-page
  redraws.

These requirements apply to both macOS and Windows. Each platform may use its
own native implementation, but interaction semantics, performance goals, size
constraints, and accessibility requirements must remain consistent.
