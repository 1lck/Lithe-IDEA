import type { ProjectTab } from "../stores/workspace-tabs.store";

export function getProjectTabBarItems(projectTabs: ProjectTab[]): ProjectTab[] {
  const activeProjectId = projectTabs.find((projectTab) => projectTab.isActive)?.id;

  return projectTabs.map((projectTab) => ({
    ...projectTab,
    isActive: projectTab.id === activeProjectId,
  }));
}
