import type { RecentFolder } from "@/features/file-system/types/recent-folders.types";
import type { ProjectTab } from "@/features/window/stores/workspace-tabs.store";
import { RECENT_PROJECT_MENU_LIMIT } from "@/features/file-system/utils/recent-folders";
import { areProjectTabPathsEqual } from "./project-tab-path";


export function getTitleProjectMenuItemAriaCurrent(isActive: boolean): "true" | undefined {
  return isActive ? "true" : undefined;
}

export function getTitleProjectMenuProjects(
  projectTabs: ProjectTab[],
  recentFolders: RecentFolder[],
  maxRecentProjects = RECENT_PROJECT_MENU_LIMIT,
) {
  return {
    openProjects: projectTabs,
    recentProjects: recentFolders
      .filter(
        (recent) =>
          !projectTabs.some((project) => areProjectTabPathsEqual(project.path, recent.path)),
      )
      .slice(0, maxRecentProjects),
  };
}
