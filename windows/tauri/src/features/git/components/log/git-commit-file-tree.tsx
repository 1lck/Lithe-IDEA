import { CaretDownIcon, CaretRightIcon, FileIcon, FolderIcon } from "@/ui/icons";
import { useMemo, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import type { GitCommitFile } from "../../types/git.types";

interface FileTreeNode {
  id: string;
  name: string;
  path: string;
  file?: GitCommitFile;
  children: FileTreeNode[];
}

interface MutableFileTreeNode extends FileTreeNode {
  children: MutableFileTreeNode[];
}

function buildFileTree(files: GitCommitFile[]): FileTreeNode[] {
  const roots: MutableFileTreeNode[] = [];
  for (const file of files) {
    const parts = file.path.split("/").filter(Boolean);
    let children = roots;
    let path = "";
    parts.forEach((name, index) => {
      path = path ? `${path}/${name}` : name;
      let node = children.find((candidate) => candidate.name === name);
      if (!node) {
        node = { id: path, name, path, children: [] };
        children.push(node);
      }
      if (index === parts.length - 1) node.file = file;
      children = node.children;
    });
  }
  const sort = (nodes: MutableFileTreeNode[]) => {
    nodes.sort((left, right) => {
      if (Boolean(left.children.length) !== Boolean(right.children.length)) {
        return left.children.length ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });
    nodes.forEach((node) => sort(node.children));
  };
  sort(roots);
  return roots;
}

function statusClassName(status: string) {
  if (status.startsWith("A")) return "text-emerald-400";
  if (status.startsWith("D")) return "text-red-400";
  if (status.startsWith("R")) return "text-amber-400";
  return "text-sky-400";
}

function FileNode({
  node,
  depth,
  collapsed,
  selectedPath,
  onToggle,
  onSelect,
  onOpen,
}: {
  node: FileTreeNode;
  depth: number;
  collapsed: Set<string>;
  selectedPath: string | null;
  onToggle: (path: string) => void;
  onSelect: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  const { t } = useTranslation();
  const isDirectory = node.children.length > 0 && !node.file;
  const isCollapsed = collapsed.has(node.path);

  return (
    <>
      <button
        type="button"
        className={cn(
          "flex h-6 w-full min-w-0 items-center gap-1.5 rounded px-1.5 text-left hover:bg-accent/80",
          node.file && selectedPath === node.path && "bg-accent text-accent-foreground",
        )}
        style={{ paddingLeft: 7 + depth * 14 }}
        onClick={() => (node.file ? onSelect(node.path) : onToggle(node.path))}
        onDoubleClick={() => node.file && onOpen(node.path)}
        title={node.file ? t("git.log.openFileDiff") : node.path}
      >
        {isDirectory ? (
          isCollapsed ? (
            <CaretRightIcon className="size-3 shrink-0" />
          ) : (
            <CaretDownIcon className="size-3 shrink-0" />
          )
        ) : (
          <span className="size-3 shrink-0" />
        )}
        {isDirectory ? (
          <FolderIcon className="size-3.5 shrink-0 text-subtle-foreground" />
        ) : (
          <FileIcon className="size-3.5 shrink-0 text-subtle-foreground" />
        )}
        <span className="truncate">{node.name}</span>
        {node.file ? (
          <span
            className={cn(
              "ml-auto shrink-0 pr-1 font-mono text-[10px]",
              statusClassName(node.file.status),
            )}
          >
            {node.file.status}
          </span>
        ) : (
          <span className="ml-auto pr-1 text-subtle-foreground tabular-nums">
            {node.children.length}
          </span>
        )}
      </button>
      {!isCollapsed &&
        node.children.map((child) => (
          <FileNode
            key={child.id}
            node={child}
            depth={depth + 1}
            collapsed={collapsed}
            selectedPath={selectedPath}
            onToggle={onToggle}
            onSelect={onSelect}
            onOpen={onOpen}
          />
        ))}
    </>
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
  const tree = useMemo(() => buildFileTree(files), [files]);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggle = (path: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  return (
    <div className="min-h-0 flex-1 overflow-auto p-1.5">
      {tree.map((node) => (
        <FileNode
          key={node.id}
          node={node}
          depth={0}
          collapsed={collapsed}
          selectedPath={selectedPath}
          onToggle={toggle}
          onSelect={onSelect}
          onOpen={onOpen}
        />
      ))}
    </div>
  );
}
