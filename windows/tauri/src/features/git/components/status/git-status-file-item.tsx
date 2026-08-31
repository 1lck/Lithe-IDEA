import type { MouseEvent } from "react";
import { ThemedFileIcon } from "@/extensions/icon-themes/components/themed-file-icon";
import { writeSidebarResourceDragData } from "@/features/sidebar/utils/sidebar-resource-drag";
import { useTranslation } from "@/i18n/locale-provider";
import { Checkbox } from "@/ui/checkbox";
import { SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import { FILE_TREE_BASE_INDENT } from "@/features/file-explorer/lib/file-tree-row";
import { cn } from "@/utils/cn";
import type { GitFile } from "../../types/git.types";
import { getWorkingTreeStatusColorClassName } from "../../utils/git-file-status-visuals";

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
}: GitFileItemProps) => {
  const { t } = useTranslation();
  const pathParts = file.path.split("/");
  const fileName = pathParts.pop() || file.path;
  const directory = pathParts.join("/");

  return (
    <SidebarTreeRow
      depth={indentLevel}
      indentSize={indentSize}
      baseIndent={FILE_TREE_BASE_INDENT}
      showGuides={showIndentGuides}
      active={active}
      className={cn("group h-full overflow-clip py-0.5", className)}
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
      }
      draggable={!!repoPath}
      onDragStart={(event) => {
        if (!repoPath) return;
        writeSidebarResourceDragData(event.dataTransfer, {
          type: "git-file-diff",
          repoPath,
          filePath: file.path,
          staged: file.staged,
          status: file.status,
          name: fileName,
        });
      }}
      title={file.path}
    />
  );
};
