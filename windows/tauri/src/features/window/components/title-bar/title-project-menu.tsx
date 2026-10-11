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
  XIcon,
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
  missing = false,
  trailing,
  onClick,
  onRemove,
  removeLabel,
  unavailableLabel,
  disabled = false,
}: {
  name: string;
  path: string;
  iconPath?: string;
  active?: boolean;
  /** The folder was found missing when it was last opened; IntelliJ greys such rows out. */
  missing?: boolean;
  trailing?: ReactNode;
  onClick: () => void;
  /** Drops the row from the recent list. Only recent rows pass it; open projects use close. */
  onRemove?: () => void;
  removeLabel?: string;
  unavailableLabel?: string;
  disabled?: boolean;
}) {
  const row = (
    <DropdownMenuItem
      aria-current={getTitleProjectMenuItemAriaCurrent(active)}
      onClick={onClick}
      // IntelliJ's Remove-selected action is bound to Delete; Backspace is its macOS spelling.
      onKeyDown={
        onRemove
          ? (event) => {
              if (event.key !== "Delete" && event.key !== "Backspace") return;
              event.preventDefault();
              event.stopPropagation();
              onRemove();
            }
          : undefined
      }
      disabled={disabled}
      title={missing ? unavailableLabel : undefined}
      className={cn(
        "min-h-11 w-full items-start gap-2 rounded-md px-2 py-1.5",
        active && "bg-selected text-foreground",
        onRemove && "pr-9",
      )}
    >
      {/* IntelliJ's project popup uses a 20px avatar aligned to the top, 8px before the name. */}
      <ProjectAvatar
        name={name}
        path={path}
        customIconPath={iconPath}
        missing={missing}
        className="mt-0.5"
      />
      <span className={cn("min-w-0 flex-1 text-left", missing && "opacity-60")}>
        <span className="block truncate font-medium text-foreground ui-text-sm">{name}</span>
        <span className="block truncate text-subtle-foreground ui-text-xs">{path}</span>
      </span>
      {trailing}
    </DropdownMenuItem>
  );

  if (!onRemove) return row;

  // The remove button is a sibling of the menu item, not a child: a click inside the item would
  // also run its open action and close the menu, while the user only wants to prune the list.
  return (
    <div className="group/project-row relative">
      {row}
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        aria-label={removeLabel}
        title={removeLabel}
        onClick={onRemove}
        className={cn(
          "absolute top-1/2 right-2 -translate-y-1/2 focus-visible:opacity-100 group-hover/project-row:opacity-100 group-has-data-highlighted/project-row:opacity-100",
          // A missing project's only useful action is removal, so IntelliJ shows it permanently.
          missing ? "opacity-100" : "opacity-0",
        )}
      >
        <XIcon />
      </Button>
    </div>
  );
}


export function TitleProjectMenu({ onOpenProjectPicker }: TitleProjectMenuProps) {
  const { t } = useTranslation();
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const activeProject = projectTabs.find((project) => project.isActive);
  const recentFolders = useRecentFoldersStore((state) => state.recentFolders);
  const openRecentFolder = useRecentFoldersStore((state) => state.actions.openRecentFolder);
  const removeFromRecents = useRecentFoldersStore((state) => state.actions.removeFromRecents);
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
        <span className="min-w-0 truncate text-foreground">{projectLabel}</span>
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
              missing={folder.missing}
              unavailableLabel={t("fileSystem.recentProjectUnavailableBadge")}
              removeLabel={t("welcome.removeRecent", { name: folder.name })}
              onRemove={() => removeFromRecents(folder.path)}
              onClick={() => closeAndRun(() => void openRecentFolder(folder.path))}
            />
          ))}
        </DropdownMenuGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
