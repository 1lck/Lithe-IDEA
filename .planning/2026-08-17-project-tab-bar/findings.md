# Findings

- The macOS reference renders `projectSessions.openProjects` in a horizontal `projectTabBar` below the title area. Each tab has a folder icon, project name, active styling, and direct activation.
- Windows already persists the same concept in `useWorkspaceTabsStore.projectTabs` and exposes `useFileSystemStore.switchToProject` plus `isSwitchingProject`.
- Windows currently renders `TitleProjectMenu` inside the title bar; its dropdown already lists open projects and should remain for project-management actions.
- `MainLayout` places `TitleBarWithSettings` immediately before the workbench and is the correct ownership boundary for a full-width tab strip.
