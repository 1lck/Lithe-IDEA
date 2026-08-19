# Mac-Style Project Tab Bar

## Goal

Show every project opened in the current Windows workbench in a compact tab bar below the title bar, matching the macOS workbench pattern. Clicking a tab activates that project immediately while the existing title-bar project menu remains the entry point for creating, opening, cloning, and selecting recent projects.

## Design

- Add a `ProjectTabBar` presentation component between `TitleBarWithSettings` and the workbench content in `MainLayout`.
- Read project order and active state from `useWorkspaceTabsStore`; use `useFileSystemStore.switchToProject` for activation.
- Render one semantic button per open project with its project badge/icon, name, active styling, and a full-path tooltip/accessible label.
- Use a horizontal overflow container so the bar remains stable when many projects are open. Do not resize the title bar or use the tab bar as a native drag region.
- Disable project buttons while `isSwitchingProject` is true, preserving the existing stale-switch protection.
- Hide the bar when no project is open, so the welcome screen keeps its current vertical layout.
- Preserve the existing `TitleProjectMenu` dropdown and all of its actions.

## Accessibility And Visual Behavior

- Use `role="tablist"` on the strip and `role="tab"` plus `aria-selected` on each project button.
- Keep a visible focus ring and selected background/border using existing semantic design tokens.
- Use the existing project badge/icon rules and Lucide-style folder icon; no new color palette or decorative artwork.
- Keep the tab height and spacing fixed to prevent layout shift, and use text truncation with a tooltip for long names.

## Testing

- Add a pure model helper test that preserves project order and exposes exactly one active tab.
- Add component-level source/behavior coverage for the tab button activation callback where the existing frontend test setup permits it.
- Run focused Bun tests, typecheck, lint, frontend build, and a live Windows CDP check that opens two projects and activates the second tab.
