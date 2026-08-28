# Lithe Agent Entry Point

Before any work in this repository, load and follow the `develop-lithe` skill
at `.agents/skills/develop-lithe/SKILL.md`. That Skill is the single source of
truth for AI coding and verification rules, including the required Rust Core
comment standard.

If a task creates, modifies, or reviews test code or test infrastructure,
additionally load `.agents/skills/write-stable-tests/SKILL.md` before
proceeding. That Skill defines the mandatory bounded-wait, deterministic-time,
cleanup, and per-test timing rules for both macOS and Windows.

If a task prepares, validates, or publishes a stable Lithe release,
additionally load `.agents/skills/release-lithe/SKILL.md` before changing
release notes, version metadata, tags, or release workflows.

If the task involves building, running, diagnosing, or transferring files to the
Windows product through a Parallels guest VM, additionally load
`.agents/skills/debug-windows-on-parallels/SKILL.md` before proceeding.
