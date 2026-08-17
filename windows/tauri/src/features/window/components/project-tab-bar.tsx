import { useMemo } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { FolderIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { getProjectTabBarItems } from "../utils/project-tab-bar-model";

export function ProjectTabBar() {
  const { t } = useTranslation();
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const switchToProject = useFileSystemStore((state) => state.switchToProject);
  const isSwitchingProject = useFileSystemStore((state) => state.isSwitchingProject);
  const projects = useMemo(() => getProjectTabBarItems(projectTabs), [projectTabs]);

  if (projects.length === 0) return null;

  return (
    <div
      className="flex h-10 shrink-0 items-center overflow-x-auto border-border/70 border-b bg-surface/90 px-1.5"
      role="tablist"
      aria-label={t("titleProject.openProjects")}
      aria-orientation="horizontal"
    >
      <div className="flex min-w-max items-center gap-1">
        {projects.map((project) => (
          <button
            key={project.id}
            type="button"
            role="tab"
            aria-selected={project.isActive}
            disabled={isSwitchingProject}
            title={project.path}
            onClick={() => {
              if (project.isActive) return;
              void switchToProject(project.id);
            }}
            className={cn(
              "group relative flex h-8 min-w-44 max-w-64 items-center gap-2 rounded-md border px-3 text-left ui-text-sm outline-none transition-colors focus-visible:ring-2 focus-visible:ring-primary/30",
              project.isActive
                ? "border-primary/45 bg-selected text-foreground"
                : "border-transparent text-subtle-foreground hover:border-border/70 hover:bg-accent hover:text-foreground",
            )}
          >
            <FolderIcon
              className={cn(
                "size-3.5 shrink-0",
                project.isActive ? "text-primary" : "text-subtle-foreground",
              )}
              aria-hidden="true"
            />
            <span className="min-w-0 truncate">{project.name}</span>
            {project.isActive ? (
              <span
                aria-hidden="true"
                className="absolute inset-x-3 -bottom-px h-px bg-primary"
              />
            ) : null}
          </button>
        ))}
      </div>
    </div>
  );
}
