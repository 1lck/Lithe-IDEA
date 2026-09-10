import type { MouseEvent } from "react";
import { ThemedFileIcon } from "@/extensions/icon-themes/components/themed-file-icon";
import { writeSidebarResourceDragData } from "@/features/sidebar/utils/sidebar-resource-drag";
import { useTranslation } from "@/i18n/locale-provider";
import { Checkbox } from "@/ui/checkbox";
import { Button } from "@/ui/button";
import { MinusIcon as Minus, PlusIcon as Plus } from "@/ui/icons";
import { SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import { FILE_TREE_BASE_INDENT } from "@/features/file-explorer/lib/file-tree-row";
import { cn } from "@/utils/cn";
import type { GitFile } from "../../types/git.types";
import { getWorkingTreeStatusColorClassName } from "../../utils/git-file-status-visuals";
import {
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../../utils/git-status-selection";
import {
  activateGitFileStageAction,
  getGitFileStageActionState,
  prepareGitFileStageAction,
} from "../../utils/git-file-stage-action";

interface GitFileItemProps {
  file: GitFile;
  active?: boolean;
  onClick?: (event: MouseEvent) => void;
  onContextMenu?: (e: MouseEvent) => void;
  checked: boolean;
  onCheckedChange: (checked: boolean) => void;
  disabled?: boolean;
  showDirectory?: boolean;
  showFileIcon?: boolean;
  showIndentGuides?: boolean;
  indentSize?: number;
  rowHeight?: number;
  indentLevel?: number;
  reserveDisclosureSpace?: boolean;
  className?: string;
  repoPath?: string;
  onStagedChange?: (staged: boolean) => void;
  stagePending?: boolean;
}

interface GitFileStageActionProps {
  staged: boolean;
  label: string;
  disabled?: boolean;
  pending?: boolean;
  onStagedChange: (staged: boolean) => void;
}

export function GitFileStageAction({
  staged,
  label,
  disabled,
  pending = false,
  onStagedChange,
}: GitFileStageActionProps) {
  const actionState = getGitFileStageActionState(staged, pending, disabled);

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      disabled={actionState.disabled}
      aria-busy={actionState.busy || undefined}
      className="size-5 opacity-0 group-hover/git-status-row:opacity-100 group-focus-within/git-status-row:opacity-100"
      tooltip={label}
      tooltipSide="left"
      onMouseDown={prepareGitFileStageAction}
      onClick={(event) =>
        activateGitFileStageAction(event, actionState.targetStaged, onStagedChange)
      }
      onContextMenu={(event) => event.stopPropagation()}
    >
      {pending ? (
        <span
          role="status"
          aria-label={label}
          className="size-3 animate-spin rounded-full border-2 border-current border-r-transparent"
        />
      ) : staged ? (
        <Minus />
      ) : (
        <Plus />
      )}
    </Button>
  );
}

export const GitFileItem = ({
  file,
  active = false,
  onClick,
  onContextMenu,
  checked,
  onCheckedChange,
  disabled,
  showDirectory = true,
  showFileIcon = false,
  showIndentGuides = true,
  indentSize = 14,
  rowHeight,
  indentLevel = 0,
  reserveDisclosureSpace = false,
  className,
  repoPath,
  onStagedChange,
  stagePending = false,
}: GitFileItemProps) => {
  const { t } = useTranslation();
  const pathParts = file.path.split("/");
  const fileName = pathParts.pop() || file.path;
  const directory = pathParts.join("/");
  const dragRepoPath = getGitFileRepositoryPath(file, repoPath);
  const dragFilePath = getGitFileRepositoryRelativePath(file);

  return (
    <SidebarTreeRow
      depth={indentLevel}
      indentSize={indentSize}
      baseIndent={FILE_TREE_BASE_INDENT}
      showGuides={showIndentGuides}
      active={active}
      containerClassName="group/git-status-row"
      className={cn("h-full overflow-clip py-0.5", className)}
      style={rowHeight ? { height: rowHeight } : undefined}
      onClick={onClick}
      onContextMenu={onContextMenu}
      reserveDisclosureSpace={reserveDisclosureSpace}
      label={<span className={getWorkingTreeStatusColorClassName(file.status)}>{fileName}</span>}
      description={showDirectory ? directory : undefined}
      leading={
        showFileIcon ? (
          <ThemedFileIcon
            fileName={fileName}
            isDir={false}
            className="file-tree-node-icon text-subtle-foreground"
          />
        ) : null
      }
      action={
        <div className="flex items-center gap-0.5">
          {onStagedChange ? (
            <GitFileStageAction
              staged={file.staged}
              disabled={disabled}
              pending={stagePending}
              label={t(file.staged ? "git.unstageFileNamed" : "git.stageFileNamed", {
                name: fileName,
              })}
              onStagedChange={onStagedChange}
            />
          ) : null}
          <Checkbox
            checked={checked}
            onCheckedChange={onCheckedChange}
            disabled={disabled}
            aria-label={
              checked
                ? t("git.excludeFileFromCommit", { name: fileName })
                : t("git.includeFileInCommit", { name: fileName })
            }
          />
        </div>
      }
      draggable={!!dragRepoPath}
      onDragStart={(event) => {
        if (!dragRepoPath) return;
        writeSidebarResourceDragData(event.dataTransfer, {
          type: "git-file-diff",
          repoPath: dragRepoPath,
          filePath: dragFilePath,
          staged: file.staged,
          status: file.status,
          name: fileName,
        });
      }}
      title={file.path}
    />
  );
};
