import { useMemo, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { Button } from "@/ui/button";
import { FolderIcon, XIcon as X } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { getProjectTabBarItems } from "../utils/project-tab-bar-model";

export function ProjectTabBar() {
  const { t } = useTranslation();
  const [closingProjectId, setClosingProjectId] = useState<string | null>(null);
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const switchToProject = useFileSystemStore((state) => state.switchToProject);
  const closeProject = useFileSystemStore((state) => state.closeProject);
  const isSwitchingProject = useFileSystemStore((state) => state.isSwitchingProject);
  const projects = useMemo(() => getProjectTabBarItems(projectTabs), [projectTabs]);
  const isProjectActionPending = isSwitchingProject || closingProjectId !== null;

  const handleCloseProject = async (projectId: string) => {
    if (isProjectActionPending) return;

    setClosingProjectId(projectId);
    try {
      await closeProject(projectId);
    } finally {
      setClosingProjectId(null);
    }
  };

  if (projects.length === 0) return null;

  return (
    <div
      className="flex h-10 shrink-0 items-center overflow-x-auto border-border/70 border-b bg-surface/90 px-1.5"
      role="tablist"
      aria-label={t("titleProject.openProjects")}
      aria-orientation="horizontal"
    >
      <div className="flex min-w-max items-center gap-1">
        {projects.map((project) => {
          const closeLabel = t("titleProject.closeProject", { name: project.name });

          return (
            <div key={project.id} className="group relative">
              <button
                type="button"
                role="tab"
                aria-selected={project.isActive}
                disabled={isProjectActionPending}
                title={project.path}
                onClick={() => {
                  if (project.isActive) return;
                  void switchToProject(project.id);
                }}
                className={cn(
                  "relative flex h-8 min-w-44 max-w-64 items-center gap-2 rounded-md border py-0 pr-9 pl-3 text-left ui-text-sm outline-none transition-colors focus-visible:ring-2 focus-visible:ring-primary/30 disabled:cursor-not-allowed",
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
              <Button
                type="button"
                size="icon-xs"
                variant="ghost"
                aria-label={closeLabel}
                tooltip={closeLabel}
                disabled={isProjectActionPending}
                onClick={(event) => {
                  event.stopPropagation();
                  void handleCloseProject(project.id);
                }}
                className={cn(
                  "absolute top-1/2 right-1 z-10 -translate-y-1/2 transition-opacity",
                  project.isActive
                    ? "opacity-100"
                    : "pointer-events-none opacity-0 group-hover:pointer-events-auto group-hover:opacity-100 group-focus-within:pointer-events-auto group-focus-within:opacity-100",
                )}
              >
                <X className="pointer-events-none select-none" aria-hidden="true" />
              </Button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
