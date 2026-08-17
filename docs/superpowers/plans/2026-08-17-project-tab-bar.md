# Mac-Style Project Tab Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** Add a horizontal project tab bar below the Windows title bar so every project open in the current window is visible and can be activated with one click.

**Architecture:** Keep project persistence and switching in the existing Zustand/file-system stores. Add a small pure model helper to normalize the active tab for deterministic tests, a focused `ProjectTabBar` presentation component for rendering and activation, and mount it from `MainLayout` directly below `TitleBarWithSettings`. The existing title-bar project dropdown remains unchanged as the project-management menu.

**Tech Stack:** React 19, TypeScript, Zustand selectors, Base UI-compatible buttons, Tailwind semantic tokens, Bun tests, Vite Plus.

---

### Task 1: Normalize Project Tab Data

**Files:**
- Create: `windows/tauri/src/features/window/utils/project-tab-bar-model.ts`
- Create: `windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts`

- [ ] **Step 1: Write the failing test**

Add a fixture with two project tabs and assert that `getProjectTabBarItems` preserves order, marks only the first active project, and repairs an invalid multiple-active input by keeping the first active tab.

```ts
test("preserves project order and exposes one active tab", () => {
  const result = getProjectTabBarItems([
    { id: "a", name: "Alpha", path: "D:/alpha", isActive: true, lastOpened: 1 },
    { id: "b", name: "Beta", path: "D:/beta", isActive: true, lastOpened: 2 },
  ]);

  expect(result.map((tab) => tab.name)).toEqual(["Alpha", "Beta"]);
  expect(result.map((tab) => tab.isActive)).toEqual([true, false]);
});
```

- [ ] **Step 2: Run the focused test and confirm the expected failure**

Run from `windows/tauri`:

```powershell
bun test src/features/window/utils/project-tab-bar-model.test.ts
```

Expected: the test fails because `project-tab-bar-model.ts` does not exist yet.

- [ ] **Step 3: Implement the minimal model helper**

Implement `getProjectTabBarItems(projectTabs)` by finding the first `isActive` tab and mapping the input in its original order, setting `isActive` only for that ID while preserving the other display fields.

- [ ] **Step 4: Run the focused test and confirm it passes**

Run the same Bun test. Expected: 1 test passes, 0 failures.

### Task 2: Build The Project Tab Bar

**Files:**
- Create: `windows/tauri/src/features/window/components/project-tab-bar.tsx`
- Create: `windows/tauri/src/features/window/components/project-tab-bar.test.ts`

- [ ] **Step 1: Write the failing component contract test**

Add a source-level contract test that requires the component to expose `role="tablist"`, `role="tab"`, `aria-selected`, `isSwitchingProject`, and `switchToProject`. This protects the accessibility and switching contract without introducing a new renderer test dependency.

- [ ] **Step 2: Run the focused test and confirm the expected failure**

Run:

```powershell
bun test src/features/window/components/project-tab-bar.test.ts
```

Expected: the test fails because the component file does not exist yet.

- [ ] **Step 3: Implement the component**

Implement the component with these exact behaviors:

```tsx
const projectTabs = useWorkspaceTabsStore.use.projectTabs();
const switchToProject = useFileSystemStore((state) => state.switchToProject);
const isSwitchingProject = useFileSystemStore((state) => state.isSwitchingProject);
const projects = getProjectTabBarItems(projectTabs);

if (projects.length === 0) return null;

return (
  <div role="tablist" aria-label={t("titleProject.openProjects")}>
    {projects.map((project) => (
      <button
        key={project.id}
        type="button"
        role="tab"
        aria-selected={project.isActive}
        disabled={isSwitchingProject || project.isActive}
        title={project.path}
        onClick={() => void switchToProject(project.id)}
      >
        {project.name}
      </button>
    ))}
  </div>
);
```

Use the existing `FolderOpenIcon`, semantic surface/border/selected tokens, fixed 30px tab height, horizontal overflow, visible focus styles, and truncated names. Do not add a native drag region or duplicate project-management actions.

- [ ] **Step 4: Run the focused component contract test**

Run the same Bun test. Expected: 1 test passes, 0 failures.

### Task 3: Mount The Bar In The Workbench

**Files:**
- Modify: `windows/tauri/src/features/layout/components/main-layout.tsx`

- [ ] **Step 1: Add the import and mount point**

Import `ProjectTabBar` from the window feature and render `<ProjectTabBar />` immediately after `<TitleBarWithSettings />`, before the root-folder conditional. The component itself returns `null` when no project is open, preserving the welcome screen layout.

- [ ] **Step 2: Run focused tests and typecheck**

Run:

```powershell
bun test src/features/window/utils/project-tab-bar-model.test.ts src/features/window/components/project-tab-bar.test.ts
bun run typecheck
```

Expected: all focused tests pass and TypeScript exits with code 0.

### Task 4: Verify The User Workflow

**Files:**
- No additional source files.

- [ ] **Step 1: Run lint and frontend build**

```powershell
bunx vp lint src/features/layout/components/main-layout.tsx src/features/window/components/project-tab-bar.tsx src/features/window/components/project-tab-bar.test.ts src/features/window/utils/project-tab-bar-model.ts src/features/window/utils/project-tab-bar-model.test.ts
bun run build
git diff --check
```

Expected: all commands exit 0. Existing dependency warnings are acceptable if they do not introduce errors.

- [ ] **Step 2: Rebuild and launch Windows Release**

Stop the current preview process, run `.\scripts\build-windows.ps1 -Configuration Release` from the repository root, and launch `windows/tauri/src-tauri/target/x86_64-pc-windows-msvc/release/lithe-windows.exe`.

- [ ] **Step 3: Verify the live tab interaction through CDP**

Open two projects in the current window, assert a visible `[role="tablist"]` contains both project names, click the inactive `[role="tab"]`, and assert its `aria-selected` becomes `true` while the previous tab becomes `false`. Confirm the title-bar project label changes to the newly active project.

- [ ] **Step 4: Run the final focused checks**

```powershell
bun test src/features/window/utils/project-tab-bar-model.test.ts src/features/window/components/project-tab-bar.test.ts
bun run typecheck
git diff --check
```

Expected: all tests pass, typecheck passes, and no whitespace errors are reported.

### Task 5: Review And Commit

**Files:**
- Stage only the new project-tab-bar source/tests, `main-layout.tsx`, and the task plan/progress files.

- [ ] **Step 1: Inspect the task diff and run an independent review**

Check `git diff` and confirm unrelated pre-existing changes remain unstaged. Resolve any Critical or Important review findings before committing.

- [ ] **Step 2: Create one focused implementation commit**

```powershell
git add -- windows/tauri/src/features/layout/components/main-layout.tsx windows/tauri/src/features/window/components/project-tab-bar.tsx windows/tauri/src/features/window/components/project-tab-bar.test.ts windows/tauri/src/features/window/utils/project-tab-bar-model.ts windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts .planning/2026-08-17-project-tab-bar/task_plan.md .planning/2026-08-17-project-tab-bar/findings.md .planning/2026-08-17-project-tab-bar/progress.md docs/superpowers/plans/2026-08-17-project-tab-bar.md
git commit -m "feat: add mac-style project tabs"
```
