import type { RecentFolder } from "@/features/file-system/types/recent-folders.types";
import type { ProjectTab } from "@/features/window/stores/workspace-tabs.store";
import { MAX_RECENT_PROJECTS } from "@/features/file-system/utils/recent-folders";
import { areProjectTabPathsEqual } from "./project-tab-path";

const PROJECT_BADGE_TONES = [
  "bg-sky-600",
  "bg-emerald-600",
  "bg-orange-600",
  "bg-violet-600",
  "bg-rose-600",
] as const;

export function getTitleProjectBadge(name: string) {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const initials =
    words
      .slice(0, 2)
      .map((word) => Array.from(word)[0] ?? "")
      .join("")
      .toUpperCase() || "LI";
  const hash = Array.from(name).reduce(
    (value, character) => (value * 31 + (character.codePointAt(0) ?? 0)) & 0x7fffffff,
    0,
  );

  return {
    initials,
    tone: PROJECT_BADGE_TONES[hash % PROJECT_BADGE_TONES.length] ?? PROJECT_BADGE_TONES[0],
  };
}

export function getTitleProjectMenuItemAriaCurrent(isActive: boolean): "true" | undefined {
  return isActive ? "true" : undefined;
}

export function getTitleProjectMenuProjects(
  projectTabs: ProjectTab[],
  recentFolders: RecentFolder[],
  maxRecentProjects = MAX_RECENT_PROJECTS,
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
