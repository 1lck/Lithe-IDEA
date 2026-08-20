import type { ProjectTab } from "../stores/workspace-tabs.store";

export function getProjectTabBarItems(projectTabs: ProjectTab[]): ProjectTab[] {
  const activeProjectId = projectTabs.find((projectTab) => projectTab.isActive)?.id;

  return projectTabs.map((projectTab) => ({
    ...projectTab,
    isActive: projectTab.id === activeProjectId,
  }));
}

export function shouldShowProjectTabBar(projectCount: number, hideWhenSingle = false): boolean {
  return projectCount > 0 && (!hideWhenSingle || projectCount > 1);
}
