# Project Tab Bar

## Goal

Add a Mac-style project tab bar below the Windows title bar so projects open in the current window are visible and directly switchable.

## Phases

- [complete] Explore existing macOS and Windows project-session patterns.
- [complete] Add failing model and interaction tests.
- [complete] Implement the project tab bar and connect project switching.
- [complete] Run frontend verification and live Windows checks.
- [complete] Review and create one focused implementation commit.

## Scope

- Worktree: `D:\code\Lithe-IDEA-preview-0.3.0`
- Branch: `fix/windows-new-window-blank`
- Preserve all existing dirty files and stage only this task's files.
- Keep the existing title-bar project dropdown and project persistence behavior.

## Errors Encountered

| Error | Attempt | Resolution |
| --- | --- | --- |
| No project-tab component exists in the Windows layout | 1 | Use the macOS `projectTabBar` structure as the reference and create a focused Windows presentation component. |
