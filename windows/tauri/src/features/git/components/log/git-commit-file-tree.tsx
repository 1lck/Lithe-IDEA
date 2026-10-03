import type { CSSProperties } from "react";
import { useMemo, useRef, useState } from "react";
import { ThemedFileIcon } from "@/extensions/icon-themes/components/themed-file-icon";
import {
  useFileTreePresentation,
  type FileTreePresentation,
} from "@/features/file-explorer/hooks/use-file-tree-presentation";
import { FILE_TREE_BASE_INDENT } from "@/features/file-explorer/lib/file-tree-row";
import "@/features/file-explorer/styles/file-explorer-tree.css";
import { SidebarTree, SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import {
  buildPathTree,
  compactPathTreeBranch,
  type PathTreeNode,
} from "@/features/sidebar/lib/path-tree";
import { useTranslation } from "@/i18n/locale-provider";
import { ScrollArea } from "@/ui/scroll-area";
import { useTreeContentWidth } from "../../hooks/use-tree-content-width";
import type { GitCommitFile } from "../../types/git.types";
import { getCommitFileStatusColorClassName } from "../../utils/git-file-status-visuals";

export function countCommitFileTreeLeaves(node: PathTreeNode<GitCommitFile>): number {
  if (node.type === "leaf") return 1;
  return node.children.reduce((count, child) => count + countCommitFileTreeLeaves(child), 0);
}

/** Path of the first file in the order the tree renders, so previews match what the user sees. */
export function getFirstCommitFilePath(files: readonly GitCommitFile[]): string | null {
  const firstLeaf = (nodes: readonly PathTreeNode<GitCommitFile>[]): string | null => {
    for (const node of nodes) {
      if (node.type === "leaf") return node.path;
      const nested = firstLeaf(node.children);
      if (nested) return nested;
    }
    return null;
  };

  return firstLeaf(
    buildPathTree([...files], {
      getPath: (file) => file.path,
      getKey: (file) => file.path,
    }),
  );
}

function FileNode({
  node,
  depth,
  collapsed,
  selectedPath,
  presentation,
  onToggle,
  onSelect,
  onOpen,
}: {
  node: PathTreeNode<GitCommitFile>;
  depth: number;
  collapsed: ReadonlySet<string>;
  selectedPath: string | null;
  presentation: FileTreePresentation;
  onToggle: (path: string) => void;
  onSelect: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  const { t } = useTranslation();

  if (node.type === "branch") {
    const compacted = presentation.compactFolders
      ? compactPathTreeBranch(node)
      : { branch: node, label: node.name };
    const branch = compacted.branch;
    const expanded = !collapsed.has(branch.path);
    const fileCount = countCommitFileTreeLeaves(branch);

    return (
      <div>
        <SidebarTreeRow
          depth={depth}
          indentSize={presentation.indentSize}
          baseIndent={FILE_TREE_BASE_INDENT}
          showGuides={presentation.showIndentGuides}
          expanded={expanded}
          onToggle={() => onToggle(branch.path)}
          onClick={() => onToggle(branch.path)}
          label={compacted.label}
          leading={
            presentation.showIcons ? (
              <ThemedFileIcon
                fileName={branch.name}
                isDir
                isExpanded={expanded}
                className="file-tree-node-icon shrink-0 text-subtle-foreground"
              />
            ) : null
          }
          description={
            <span className="tabular-nums">
              {t(fileCount === 1 ? "git.log.fileCountOne" : "git.log.filesCount", {
                count: fileCount,
              })}
            </span>
          }
          title={branch.path}
          className="h-full py-0.5"
          style={{ height: presentation.rowHeight }}
        />
        {expanded
          ? branch.children.map((child) => (
              <FileNode
                key={child.id}
                node={child}
                depth={depth + 1}
                collapsed={collapsed}
                selectedPath={selectedPath}
                presentation={presentation}
                onToggle={onToggle}
                onSelect={onSelect}
                onOpen={onOpen}
              />
            ))
          : null}
      </div>
    );
  }

  const file = node.item;
  const statusColorClassName = getCommitFileStatusColorClassName(file.status);
  return (
    <SidebarTreeRow
      depth={depth}
      indentSize={presentation.indentSize}
      baseIndent={FILE_TREE_BASE_INDENT}
      showGuides={presentation.showIndentGuides}
      reserveDisclosureSpace
      active={selectedPath === node.path}
      onClick={() => onSelect(node.path)}
      onDoubleClick={() => onOpen(node.path)}
      label={<span className={statusColorClassName}>{node.name}</span>}
      leading={
        presentation.showIcons ? (
          <ThemedFileIcon
            fileName={node.path}
            isDir={false}
            className="file-tree-node-icon shrink-0 text-subtle-foreground"
          />
        ) : null
      }
      title={t("git.log.openFileDiff")}
      className="h-full py-0.5"
      style={{ height: presentation.rowHeight }}
    />
  );
}

export function GitCommitFileTree({
  files,
  selectedPath,
  onSelect,
  onOpen,
}: {
  files: GitCommitFile[];
  selectedPath: string | null;
  onSelect: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  const { t } = useTranslation();
  const presentation = useFileTreePresentation();
  const viewportRef = useRef<HTMLDivElement>(null);
  const tree = useMemo(
    () =>
      buildPathTree(files, {
        getPath: (file) => file.path,
        getKey: (file) => file.path,
      }),
    [files],
  );
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggle = (path: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };
  // IntelliJ's commit-files tree scrolls horizontally instead of truncating long names,
  // like the changes tree: the tree widens to the widest rendered row (see
  // use-tree-content-width.ts) and the viewport scrolls both ways.
  const treeContentWidth = useTreeContentWidth({
    viewportRef,
    rowSelector: "[data-sidebar-tree-row]",
    resetKey: `${files.map((file) => file.path).join("\u0000")}\u0000${presentation.compactFolders}`,
  });

  return (
    <ScrollArea
      className="min-h-0 flex-1"
      orientation="both"
      contentClassName="p-1.5"
      viewportProps={{ ref: viewportRef }}
      reserveScrollbarGutter
    >
      <SidebarTree
        label={t("git.log.commitFiles")}
        className="file-tree-container relative overflow-visible!"
        style={
          {
            "--file-tree-row-height": `${presentation.rowHeight}px`,
            minWidth: treeContentWidth > 0 ? treeContentWidth : undefined,
          } as CSSProperties
        }
      >
        {tree.map((node) => (
          <FileNode
            key={node.id}
            node={node}
            depth={0}
            collapsed={collapsed}
            selectedPath={selectedPath}
            presentation={presentation}
            onToggle={toggle}
            onSelect={onSelect}
            onOpen={onOpen}
          />
        ))}
      </SidebarTree>
    </ScrollArea>
  );
}
