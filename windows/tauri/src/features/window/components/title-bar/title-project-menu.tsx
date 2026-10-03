import { useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { ProjectAvatar } from "@/features/window/components/project-avatar";
import { TitleWidgetChevron } from "./title-widget-chevron";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useRecentFoldersStore } from "@/features/file-system/stores/recent-folders.store";
import { useProjectGradientAnchor } from "@/features/window/hooks/use-project-gradient";
import { getProjectDisplayLabel } from "@/features/window/utils/project-display-label";
import { useTranslation } from "@/i18n/locale-provider";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import {
  getTitleProjectMenuItemAriaCurrent,
  getTitleProjectMenuProjects,
} from "@/features/window/utils/title-project-menu-model";
import type { ProjectPickerMode } from "@/features/window/utils/project-picker-mode";
import {
  CheckIcon,
  FolderOpenIcon,
  GitBranchIcon,
  PlusIcon,
} from "@/ui/icons";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import { Button } from "@/ui/button";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
import { cn } from "@/utils/cn";

interface TitleProjectMenuProps {
  onOpenProjectPicker: (mode: ProjectPickerMode) => void;
}

function ProjectMenuRow({
  name,
  path,
  iconPath,
  active = false,
  trailing,
  onClick,
  disabled = false,
}: {
  name: string;
  path: string;
  iconPath?: string;
  active?: boolean;
  trailing?: ReactNode;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <DropdownMenuItem
      aria-current={getTitleProjectMenuItemAriaCurrent(active)}
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "min-h-11 w-full items-start gap-2 rounded-md px-2 py-1.5",
        active && "bg-selected text-foreground",
      )}
    >
      {/* IntelliJ's project popup uses a 20px avatar aligned to the top, 8px before the name. */}
      <ProjectAvatar name={name} path={path} customIconPath={iconPath} className="mt-0.5" />
      <span className="min-w-0 flex-1 text-left">
        <span className="block truncate font-medium text-foreground ui-text-sm">{name}</span>
        <span className="block truncate text-subtle-foreground ui-text-xs">{path}</span>
      </span>
      {trailing}
    </DropdownMenuItem>
  );
}

export function TitleProjectMenu({ onOpenProjectPicker }: TitleProjectMenuProps) {
  const { t } = useTranslation();
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const activeProject = projectTabs.find((project) => project.isActive);
  const recentFolders = useRecentFoldersStore((state) => state.recentFolders);
  const openRecentFolder = useRecentFoldersStore((state) => state.actions.openRecentFolder);
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const switchToProject = useFileSystemStore((state) => state.switchToProject);
  const isSwitchingProject = useFileSystemStore((state) => state.isSwitchingProject);
  const projectLabel = activeProject
    ? getProjectDisplayLabel(activeProject)
    : t("projectOpen.title");
  const [isOpen, setIsOpen] = useState(false);
  const [menuNode, setMenuNode] = useState<HTMLDivElement | null>(null);
  const [badgeNode, setBadgeNode] = useState<HTMLElement | null>(null);
  useProjectGradientAnchor(badgeNode);
  const projects = useMemo(
    () => getTitleProjectMenuProjects(projectTabs, recentFolders),
    [projectTabs, recentFolders],
  );

  useLayoutEffect(() => {
    if (!menuNode) return;
    return bindScrollContainerWheel(menuNode);
  }, [menuNode]);

  const closeAndRun = (action: () => void) => {
    setIsOpen(false);
    action();
  };

  return (
    <DropdownMenu open={isOpen} onOpenChange={setIsOpen}>
      <DropdownMenuTrigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="xs"
            // IntelliJ ToolbarComboButton: 30px tall, 12px arc (6px radius), insets 10px left and
            // 6px right, 6px between icon and text, 2px before the chevron.
            className="h-[30px] max-w-56 justify-start gap-1.5 rounded-[6px] pr-1.5 pl-2.5"
            aria-label={t("titleProject.trigger", { project: projectLabel })}
          />
        }
      >
        {activeProject ? (
          <ProjectAvatar
            name={projectLabel}
            path={activeProject.path}
            customIconPath={activeProject.customIcon}
            avatarRef={setBadgeNode}
          />
        ) : (
          <FolderOpenIcon className="size-5 shrink-0" />
        )}
        <span className="min-w-0 truncate">{projectLabel}</span>
        {/* IntelliJ draws General.ChevronDown at its native 16px, 2px after the text, and
            leaves it unrotated while the popup is open. */}
        <TitleWidgetChevron />
      </DropdownMenuTrigger>

      <DropdownMenuContent
        ref={setMenuNode}
        align="start"
        side="bottom"
        className="max-h-[min(32.5rem,calc(100vh-3rem))] w-96 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-md p-1.5"
      >
        <DropdownMenuItem
          onClick={() => closeAndRun(() => onOpenProjectPicker("new-project"))}
          className="min-h-8 justify-start gap-2 rounded-md px-2"
        >
          <PlusIcon />
          {t("titleProject.newProject")}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => closeAndRun(() => void handleOpenFolder())}
          className="min-h-8 justify-start gap-2 rounded-md px-2"
        >
          <FolderOpenIcon />
          {t("titleProject.open")}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => closeAndRun(() => onOpenProjectPicker("clone-repository"))}
          className="min-h-8 justify-start gap-2 rounded-md px-2"
        >
          <GitBranchIcon />
          {t("titleProject.cloneRepository")}
        </DropdownMenuItem>

        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuLabel className="px-2 pt-1.5 pb-1 font-normal ui-text-xs">
            {t("titleProject.openProjects")}
          </DropdownMenuLabel>
          {projects.openProjects.map((project) => (
            <ProjectMenuRow
              key={project.id}
              name={getProjectDisplayLabel(project)}
              path={project.path}
              iconPath={project.customIcon}
              active={project.isActive}
              disabled={isSwitchingProject}
              onClick={() => {
                if (project.isActive) return;
                closeAndRun(() => void switchToProject(project.id));
              }}
              trailing={project.isActive ? <CheckIcon className="size-4 self-center text-primary" /> : null}
            />
          ))}
        </DropdownMenuGroup>

        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuLabel className="px-2 pt-1.5 pb-1 font-normal ui-text-xs">
            {t("titleProject.recentProjects")}
          </DropdownMenuLabel>
          {projects.recentProjects.length === 0 ? (
            <div className="px-2 py-3 text-subtle-foreground ui-text-xs">
              {t("titleProject.noRecentProjects")}
            </div>
          ) : null}
          {projects.recentProjects.map((folder) => (
            <ProjectMenuRow
              key={folder.path}
              name={folder.name}
              path={folder.path}
              iconPath={folder.customIcon}
              onClick={() => closeAndRun(() => void openRecentFolder(folder.path))}
            />
          ))}
        </DropdownMenuGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
