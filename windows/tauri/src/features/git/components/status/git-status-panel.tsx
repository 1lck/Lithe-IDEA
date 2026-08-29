import {
  ArchiveIcon as Archive,
  ArrowCounterClockwiseIcon as RotateCcw,
  CaretDownIcon as CaretDown,
  CaretRightIcon as CaretRight,
  CheckIcon as Check,
  FolderOpenIcon as FolderOpen,
  GitCommitIcon as GitCommit,
  GitDiffIcon as GitDiff,
  EyeSlashIcon as EyeSlash,
  MinusIcon as Minus,
  PlusIcon as Plus,
  TrashIcon as Trash2,
} from "@/ui/icons";
import type React from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { ThemedFileIcon } from "@/extensions/icon-themes/components/themed-file-icon";
import { useFileTreePresentation } from "@/features/file-explorer/hooks/use-file-tree-presentation";
import { FILE_TREE_BASE_INDENT } from "@/features/file-explorer/lib/file-tree-row";
import "@/features/file-explorer/styles/file-explorer-tree.css";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { writeSidebarResourceDragData } from "@/features/sidebar/utils/sidebar-resource-drag";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/ui/button-group";
import { Checkbox } from "@/ui/checkbox";
import { Dropdown, useDropdownMenu, type MenuItem } from "@/ui/dropdown";
import { Empty, EmptyMedia, EmptyTitle } from "@/ui/empty";
import { ScrollArea } from "@/ui/scroll-area";
import { showConfirmDialog } from "@/ui/dialog";
import { SidebarHeaderIconButton, SidebarSectionHeader, SidebarToolbar } from "@/ui/sidebar";
import { SidebarTree, SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import { compactPathTreeBranch, type PathTreeNode } from "@/features/sidebar/lib/path-tree";
import { cn } from "@/utils/cn";
import { joinPath } from "@/utils/path-helpers";
import { createStash } from "../../api/git-stash-api";
import {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  rollbackFilesChanges,
  setFilesStaged,
  stageAllFiles,
  unstageAllFiles,
} from "../../api/git-status-api";
import type { GitFile } from "../../types/git.types";
import {
  buildGitFolderTree,
  buildGitStatusPresentation,
  GIT_STATUS_ORDER,
  type GitFolderTree,
  type GitStatusGroup,
} from "../../utils/git-status-model";
import {
  buildGitIgnorePaths,
  collapseNestedGitStatusPaths,
  resolveGitStatusDeletionPaths,
  resolveGitStatusContextSelection,
  updateGitStatusSelection,
} from "../../utils/git-status-selection";
import { StashMessageModal } from "../stash/git-stash-modal";
import { GitFileItem } from "./git-status-file-item";

interface GitFileDiffStats {
  additions: number;
  deletions: number;
}

interface GitStatusPanelProps {
  files: GitFile[];
  fileDiffStats?: Record<string, GitFileDiffStats>;
  commitSelectedPaths: ReadonlySet<string>;
  onCommitSelectedPathsChange: (paths: Set<string>) => void;
  collapsedFolders: ReadonlySet<string>;
  onCollapsedFoldersChange: (folders: Set<string>) => void;
  collapsedSections: ReadonlySet<string>;
  onCollapsedSectionsChange: (sections: Set<string>) => void;
  onFileSelect?: (path: string, staged: boolean) => void;
  onOpenPath?: (path: string, isDirectory: boolean) => void;
  onViewDiff?: (scope?: GitStatusDiffScope) => void;
  onViewFilesDiff?: (filePaths: string[]) => void;
  onCommitSelection?: (filePaths: string[]) => void;
  onShowCommitDiffPicker?: () => void;
  onShowBranchDiffPicker?: () => void;
  onShowStashDiffPicker?: () => void;
  onRefresh?: () => void;
  repoPath?: string;
}

interface ContextMenuState {
  entryIds: string[];
}

interface GitStatusSelectionEntry {
  id: string;
  kind: "file" | "folder";
  path: string;
  filePaths: string[];
  files: GitFile[];
}

type StatusSection = "tracked" | "untracked";
type GitStatusDiffScope = "all" | "unstaged" | "staged";

const getFileEntryId = (filePath: string) => `file:${filePath}`;
const getFolderEntryId = (section: StatusSection, folderPath: string) =>
  `folder:${section}:${folderPath}`;

const GitStatusPanel = ({
  files,
  fileDiffStats,
  commitSelectedPaths,
  onCommitSelectedPathsChange,
  collapsedFolders,
  onCollapsedFoldersChange,
  collapsedSections,
  onCollapsedSectionsChange,
  onFileSelect,
  onOpenPath,
  onViewDiff,
  onViewFilesDiff,
  onCommitSelection,
  onShowCommitDiffPicker,
  onShowBranchDiffPicker,
  onShowStashDiffPicker,
  onRefresh,
  repoPath,
}: GitStatusPanelProps) => {
  const { t } = useTranslation();
  const gitChangesFolderView = useSettingsStore((state) => state.settings.gitChangesFolderView);
  const confirmBeforeDiscard = useSettingsStore((state) => state.settings.confirmBeforeDiscard);
  const fileTreePresentation = useFileTreePresentation();
  const deleteFile = useFileSystemStore((state) => state.deleteFile);
  const contextMenu = useDropdownMenu<ContextMenuState>();
  const diffMenuAnchorRef = useRef<HTMLDivElement>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isDiffMenuOpen, setIsDiffMenuOpen] = useState(false);
  const [optimisticStageMap, setOptimisticStageMap] = useState<Record<string, boolean>>({});
  const [selectedEntryIds, setSelectedEntryIds] = useState<Set<string>>(new Set());

  const [stashModal, setStashModal] = useState<{
    isOpen: boolean;
    type: "selection" | "all";
    filePaths?: string[];
    includeUntracked?: boolean;
  }>({
    isOpen: false,
    type: "selection",
  });

  useEffect(() => {
    setOptimisticStageMap({});
  }, [files]);

  const displayFiles = useMemo(() => {
    if (Object.keys(optimisticStageMap).length === 0) {
      return files;
    }

    return files.map((file) => ({
      ...file,
      staged: optimisticStageMap[file.path] ?? file.staged,
    }));
  }, [files, optimisticStageMap]);
  const {
    stagedFiles,
    unstagedFiles,
    hasStagedDiffableFiles,
    hasUnstagedDiffableFiles,
    visibleFiles,
    displayFileByPath,
    trackedFiles,
    untrackedFiles,
    groupedTrackedFiles,
    groupedUntrackedFiles,
  } = useMemo(() => buildGitStatusPresentation(displayFiles), [displayFiles]);
  const getDiffStats = useCallback(
    (file: GitFile) => {
      const primaryKey = `${file.staged ? "staged" : "unstaged"}:${file.path}`;
      const fallbackKey = `${file.staged ? "unstaged" : "staged"}:${file.path}`;

      return fileDiffStats?.[primaryKey] ?? fileDiffStats?.[fallbackKey];
    },
    [fileDiffStats],
  );
  const allDiffStats = useMemo(
    () =>
      displayFiles.reduce(
        (totals, file) => {
          const stats = getDiffStats(file);
          return {
            additions: totals.additions + (stats?.additions ?? 0),
            deletions: totals.deletions + (stats?.deletions ?? 0),
          };
        },
        { additions: 0, deletions: 0 },
      ),
    [displayFiles, getDiffStats],
  );
  const trackedFolderTree = useMemo(
    () => (gitChangesFolderView ? buildGitFolderTree(trackedFiles) : null),
    [gitChangesFolderView, trackedFiles],
  );
  const untrackedFolderTree = useMemo(
    () => (gitChangesFolderView ? buildGitFolderTree(untrackedFiles) : null),
    [gitChangesFolderView, untrackedFiles],
  );
  const entryById = useMemo(() => {
    const entries = new Map<string, GitStatusSelectionEntry>();

    for (const file of visibleFiles) {
      const id = getFileEntryId(file.path);
      entries.set(id, {
        id,
        kind: "file",
        path: file.path,
        filePaths: [file.path],
        files: [file],
      });
    }

    const registerFolders = (tree: GitFolderTree | null, section: StatusSection) => {
      if (!tree) return;

      const registerNode = (node: PathTreeNode<GitFile>) => {
        if (node.type === "leaf") return;
        const { branch } = compactPathTreeBranch(node);
        const folderState = tree.folderStateById.get(branch.id);
        if (!folderState) return;

        const id = getFolderEntryId(section, branch.path);
        entries.set(id, {
          id,
          kind: "folder",
          path: branch.path,
          filePaths: folderState.descendantFilePaths,
          files: folderState.descendantFilePaths.flatMap((filePath) => {
            const file = displayFileByPath.get(filePath);
            return file ? [file] : [];
          }),
        });
        branch.children.forEach(registerNode);
      };

      tree.nodes.forEach(registerNode);
    };

    registerFolders(trackedFolderTree, "tracked");
    registerFolders(untrackedFolderTree, "untracked");
    return entries;
  }, [displayFileByPath, trackedFolderTree, untrackedFolderTree, visibleFiles]);

  useEffect(() => {
    setSelectedEntryIds((current) => {
      const next = new Set([...current].filter((entryId) => entryById.has(entryId)));
      return next.size === current.size ? current : next;
    });
  }, [entryById]);

  const setOptimisticStage = (filePaths: string[], staged: boolean) => {
    setOptimisticStageMap((current) => {
      const next = { ...current };
      for (const filePath of filePaths) {
        next[filePath] = staged;
      }
      return next;
    });
  };

  const handleSetFilesStaged = async (filePaths: string[], staged: boolean): Promise<boolean> => {
    if (!repoPath || filePaths.length === 0) return false;

    setOptimisticStage(filePaths, staged);
    setIsLoading(true);
    try {
      const success = await setFilesStaged(repoPath, filePaths, staged);
      if (!success) {
        setOptimisticStage(filePaths, !staged);
        return false;
      }
      await onRefresh?.();
      return true;
    } finally {
      setIsLoading(false);
    }
  };

  const handleStageAll = async () => {
    if (!repoPath) return;
    setOptimisticStage(
      unstagedFiles.map((file) => file.path),
      true,
    );
    setIsLoading(true);
    try {
      const success = await stageAllFiles(repoPath);
      if (!success) {
        setOptimisticStage(
          unstagedFiles.map((file) => file.path),
          false,
        );
        return;
      }
      await onRefresh?.();
    } finally {
      setIsLoading(false);
    }
  };

  const handleUnstageAll = async () => {
    if (!repoPath) return;
    setOptimisticStage(
      stagedFiles.map((file) => file.path),
      false,
    );
    setIsLoading(true);
    try {
      const success = await unstageAllFiles(repoPath);
      if (!success) {
        setOptimisticStage(
          stagedFiles.map((file) => file.path),
          true,
        );
        return;
      }
      await onRefresh?.();
    } finally {
      setIsLoading(false);
    }
  };

  const getSelectionFilePaths = (entries: GitStatusSelectionEntry[]) => [
    ...new Set(entries.flatMap((entry) => entry.filePaths)),
  ];

  const handleCommitEntries = (entries: GitStatusSelectionEntry[]) => {
    const filePaths = getSelectionFilePaths(entries);
    if (filePaths.length === 0) return;
    onCommitSelectedPathsChange(new Set(filePaths));
    onCommitSelection?.(filePaths);
  };

  const handleRollbackEntries = async (entries: GitStatusSelectionEntry[]) => {
    if (!repoPath) return;
    const trackedFilePaths = [
      ...new Set(
        entries
          .flatMap((entry) => entry.files)
          .filter((file) => file.status !== "untracked")
          .map((file) => file.path),
      ),
    ];
    if (trackedFilePaths.length === 0) return;

    if (
      confirmBeforeDiscard &&
      !(await showConfirmDialog(t("git.rollbackPathsConfirm", { count: trackedFilePaths.length }), {
        title: t("git.rollback"),
        confirmLabel: t("git.rollback"),
      }))
    ) {
      return;
    }

    setIsLoading(true);
    try {
      await rollbackFilesChanges(repoPath, trackedFilePaths);
      await onRefresh?.();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      toast.error(t("git.operationError", { error: message }));
    } finally {
      setIsLoading(false);
    }
  };

  const handleDeleteEntries = async (entries: GitStatusSelectionEntry[]) => {
    if (!repoPath) return;
    const filePaths = resolveGitStatusDeletionPaths(entries);
    if (filePaths.length === 0) return;
    const selectionPaths = collapseNestedGitStatusPaths(entries.map((entry) => entry.path));

    if (
      !(await showConfirmDialog(
        t("git.deletePathsConfirm", {
          count: filePaths.length,
          paths: selectionPaths.join(", "),
        }),
        {
          title: t("git.delete"),
          confirmLabel: t("git.delete"),
        },
      ))
    ) {
      return;
    }

    setIsLoading(true);
    try {
      for (const filePath of filePaths) {
        await deleteFile(joinPath(repoPath, filePath));
      }
      setSelectedEntryIds(new Set());
      await onRefresh?.();
    } finally {
      setIsLoading(false);
    }
  };

  const handleAddToVcs = async (entries: GitStatusSelectionEntry[]) => {
    const untrackedFilePaths = [
      ...new Set(
        entries
          .flatMap((entry) => entry.files)
          .filter((file) => file.status === "untracked")
          .map((file) => file.path),
      ),
    ];
    if (untrackedFilePaths.length > 0) {
      await handleSetFilesStaged(untrackedFilePaths, true);
    }
  };

  const handleAddToIgnoreFile = async (
    entries: GitStatusSelectionEntry[],
    target: "gitignore" | "exclude",
  ) => {
    if (!repoPath) return;
    const paths = buildGitIgnorePaths(
      entries
        .filter((entry) => entry.files.some((file) => file.status === "untracked"))
        .map((entry) => ({ kind: entry.kind, path: entry.path })),
    );
    if (paths.length === 0) return;

    const targetLabel = target === "gitignore" ? t("git.gitignoreFile") : t("git.localExcludeFile");
    if (
      !(await showConfirmDialog(
        t("git.addPathsToIgnoreConfirm", {
          count: paths.length,
          paths: paths.join(", "),
          target: targetLabel,
        }),
        {
          title: targetLabel,
          confirmLabel: t("git.add"),
        },
      ))
    ) {
      return;
    }

    setIsLoading(true);
    try {
      const success =
        target === "gitignore"
          ? await addPathsToGitignore(repoPath, paths)
          : await addPathsToLocalGitExclude(repoPath, paths);
      if (success) {
        setSelectedEntryIds(new Set());
        await onRefresh?.();
      }
    } finally {
      setIsLoading(false);
    }
  };

  const handleStashEntries = (entries: GitStatusSelectionEntry[]) => {
    const filePaths = getSelectionFilePaths(entries);
    if (filePaths.length === 0) return;
    setStashModal({
      isOpen: true,
      type: "selection",
      filePaths,
      includeUntracked: entries
        .flatMap((entry) => entry.files)
        .some((file) => file.status === "untracked"),
    });
  };

  const handleSetCommitPathsSelected = (filePaths: string[], selected: boolean) => {
    const next = new Set(commitSelectedPaths);
    for (const filePath of filePaths) {
      if (selected) {
        next.add(filePath);
      } else {
        next.delete(filePath);
      }
    }
    onCommitSelectedPathsChange(next);
  };

  const handleStashAllUnstaged = async () => {
    setStashModal({
      isOpen: true,
      type: "all",
    });
  };

  const handleConfirmStash = async (message: string) => {
    if (!repoPath) return;

    if (stashModal.type === "selection" && stashModal.filePaths?.length) {
      await createStash(
        repoPath,
        message || t("git.stashSelectedDefault"),
        stashModal.includeUntracked,
        stashModal.filePaths,
      );
    } else if (stashModal.type === "all") {
      const paths = unstagedFiles.map((f) => f.path);
      if (paths.length === 0) return;

      await createStash(repoPath, message || t("git.stashAllUnstagedChanges"), false, paths);
    }

    await onRefresh?.();
  };

  const handleSelectEntry = (event: React.MouseEvent, entry: GitStatusSelectionEntry) => {
    setSelectedEntryIds((current) =>
      updateGitStatusSelection(current, entry.id, event.ctrlKey || event.metaKey),
    );
  };

  const handleContextMenu = (event: React.MouseEvent, entry: GitStatusSelectionEntry) => {
    const nextSelection = resolveGitStatusContextSelection(selectedEntryIds, entry.id);
    setSelectedEntryIds(nextSelection);
    contextMenu.open(event, { entryIds: [...nextSelection] });
  };

  const toggleFolderCollapsed = (section: StatusSection, folderPath: string) => {
    const key = `${section}:${folderPath}`;
    const next = new Set(collapsedFolders);
    if (next.has(key)) {
      next.delete(key);
    } else {
      next.add(key);
    }
    onCollapsedFoldersChange(next);
  };

  const toggleSectionCollapsed = (section: StatusSection) => {
    const next = new Set(collapsedSections);
    if (next.has(section)) {
      next.delete(section);
    } else {
      next.add(section);
    }
    onCollapsedSectionsChange(next);
  };

  const renderFlatFileList = (groupedFiles: Record<GitStatusGroup, GitFile[]>) => {
    return GIT_STATUS_ORDER.map((status) => {
      const statusFiles = groupedFiles[status];
      if (statusFiles.length === 0) return null;

      return (
        <div key={status}>
          {statusFiles.map((file) => {
            const entry = entryById.get(getFileEntryId(file.path));
            if (!entry) return null;
            return (
              <GitFileItem
                key={`${status}:${file.path}`}
                file={file}
                active={selectedEntryIds.has(entry.id)}
                diffStats={getDiffStats(file)}
                onClick={(event) => {
                  handleSelectEntry(event, entry);
                  if (!event.ctrlKey && !event.metaKey) {
                    onFileSelect?.(file.path, file.staged);
                  }
                }}
                onContextMenu={(event) => handleContextMenu(event, entry)}
                checked={commitSelectedPaths.has(file.path)}
                onCheckedChange={(checked) => handleSetCommitPathsSelected([file.path], checked)}
                showFileIcon={fileTreePresentation.showIcons}
                showIndentGuides={fileTreePresentation.showIndentGuides}
                indentSize={fileTreePresentation.indentSize}
                rowHeight={fileTreePresentation.rowHeight}
                repoPath={repoPath}
              />
            );
          })}
        </div>
      );
    });
  };

  const renderDiffStatsBadge = (stats: GitFileDiffStats, className?: string) => (
    <Badge
      variant="default"
      size="compact"
      className={cn("h-5 gap-1 border-border/50 bg-accent/60 tabular-nums", className)}
    >
      <span className="text-git-added">+{stats.additions}</span>
      <span className="text-git-deleted">-{stats.deletions}</span>
    </Badge>
  );

  const renderSectionHeader = (section: StatusSection, title: string, count: number) => (
    <SidebarSectionHeader
      variant="surface"
      count={count}
      expanded={!collapsedSections.has(section)}
      onToggle={() => toggleSectionCollapsed(section)}
    >
      {title}
    </SidebarSectionHeader>
  );

  const renderFolderTree = (tree: GitFolderTree, section: StatusSection) => {
    const renderNode = (node: PathTreeNode<GitFile>, depth: number): React.ReactNode => {
      if (node.type === "leaf") {
        const file = node.item;
        const entry = entryById.get(getFileEntryId(file.path));
        if (!entry) return null;
        return (
          <GitFileItem
            key={node.id}
            file={file}
            active={selectedEntryIds.has(entry.id)}
            diffStats={getDiffStats(file)}
            onClick={(event) => {
              handleSelectEntry(event, entry);
              if (!event.ctrlKey && !event.metaKey) {
                onFileSelect?.(file.path, file.staged);
              }
            }}
            onContextMenu={(event) => handleContextMenu(event, entry)}
            checked={commitSelectedPaths.has(file.path)}
            onCheckedChange={(checked) => handleSetCommitPathsSelected([file.path], checked)}
            showDirectory={false}
            showFileIcon={fileTreePresentation.showIcons}
            showIndentGuides={fileTreePresentation.showIndentGuides}
            indentSize={fileTreePresentation.indentSize}
            rowHeight={fileTreePresentation.rowHeight}
            indentLevel={depth}
            reserveDisclosureSpace
            repoPath={repoPath}
          />
        );
      }

      const compacted = fileTreePresentation.compactFolders
        ? compactPathTreeBranch(node)
        : { branch: node, label: node.name };
      const branch = compacted.branch;
      const collapseKey = `${section}:${branch.path}`;
      const isCollapsed = collapsedFolders.has(collapseKey);
      const folderState = tree.folderStateById.get(branch.id);
      if (!folderState) return null;
      const entry = entryById.get(getFolderEntryId(section, branch.path));
      if (!entry) return null;

      return (
        <div key={node.id}>
          <SidebarTreeRow
            depth={depth}
            indentSize={fileTreePresentation.indentSize}
            baseIndent={FILE_TREE_BASE_INDENT}
            showGuides={fileTreePresentation.showIndentGuides}
            active={selectedEntryIds.has(entry.id)}
            expanded={!isCollapsed}
            onToggle={() => toggleFolderCollapsed(section, branch.path)}
            onClick={(event) => handleSelectEntry(event, entry)}
            onContextMenu={(event) => handleContextMenu(event, entry)}
            label={compacted.label}
            className="h-full py-0.5"
            style={{ height: fileTreePresentation.rowHeight }}
            leading={
              fileTreePresentation.showIcons ? (
                <ThemedFileIcon
                  fileName={branch.name}
                  isDir
                  isExpanded={!isCollapsed}
                  className="file-tree-node-icon shrink-0 text-subtle-foreground"
                />
              ) : null
            }
            action={
              <Checkbox
                checked={folderState.descendantFilePaths.every((filePath) =>
                  commitSelectedPaths.has(filePath),
                )}
                onCheckedChange={(checked) =>
                  handleSetCommitPathsSelected(folderState.descendantFilePaths, checked)
                }
                disabled={folderState.descendantFilePaths.length === 0}
                aria-label={
                  folderState.descendantFilePaths.every((filePath) =>
                    commitSelectedPaths.has(filePath),
                  )
                    ? t("git.excludeFolderFromCommit", { name: compacted.label })
                    : t("git.includeFolderInCommit", { name: compacted.label })
                }
              />
            }
            draggable={!!repoPath}
            onDragStart={(event) => {
              if (!repoPath) return;
              writeSidebarResourceDragData(event.dataTransfer, {
                type: "file",
                path: `${repoPath}/${branch.path}`,
                name: branch.name,
                isDir: true,
              });
            }}
            title={branch.path}
          />
          {!isCollapsed ? branch.children.map((child) => renderNode(child, depth + 1)) : null}
        </div>
      );
    };

    return tree.nodes.map((node) => renderNode(node, 0));
  };

  const hasFiles = visibleFiles.length > 0;

  const contextMenuEntries = useMemo(
    () =>
      contextMenu.data?.entryIds.flatMap((entryId) => {
        const entry = entryById.get(entryId);
        return entry ? [entry] : [];
      }) ?? [],
    [contextMenu.data, entryById],
  );
  const contextMenuFilePaths = useMemo(
    () => getSelectionFilePaths(contextMenuEntries),
    [contextMenuEntries],
  );
  const contextMenuFiles = useMemo(
    () => contextMenuEntries.flatMap((entry) => entry.files),
    [contextMenuEntries],
  );
  const contextMenuDeletionPaths = useMemo(
    () => resolveGitStatusDeletionPaths(contextMenuEntries),
    [contextMenuEntries],
  );
  const contextMenuTarget = contextMenuEntries.length === 1 ? contextMenuEntries[0] : null;
  const contextMenuHasTrackedFiles = contextMenuFiles.some((file) => file.status !== "untracked");
  const contextMenuHasUntrackedFiles = contextMenuFiles.some((file) => file.status === "untracked");
  const openScopedDiff = useCallback(
    (scope: GitStatusDiffScope) => {
      setIsDiffMenuOpen(false);
      onViewDiff?.(scope);
    },
    [onViewDiff],
  );
  const openDiffPicker = useCallback((handler: (() => void) | undefined) => {
    setIsDiffMenuOpen(false);
    handler?.();
  }, []);
  const diffMenuItems = useMemo<MenuItem[]>(
    () => [
      {
        id: "unstaged",
        label: t("git.unstaged"),
        disabled: !hasUnstagedDiffableFiles || isLoading,
        onClick: () => openScopedDiff("unstaged"),
      },
      {
        id: "staged",
        label: t("git.staged"),
        disabled: !hasStagedDiffableFiles || isLoading,
        onClick: () => openScopedDiff("staged"),
      },
      { id: "sep-working-tree", label: "", separator: true, onClick: () => {} },
      {
        id: "commit",
        label: t("git.commit"),
        disabled: !onShowCommitDiffPicker,
        keybinding: <CaretRight className="size-3 text-subtle-foreground" />,
        onClick: () => openDiffPicker(onShowCommitDiffPicker),
      },
      {
        id: "branch",
        label: t("git.branch"),
        disabled: !onShowBranchDiffPicker,
        keybinding: <CaretRight className="size-3 text-subtle-foreground" />,
        onClick: () => openDiffPicker(onShowBranchDiffPicker),
      },
      {
        id: "stash",
        label: t("git.stash"),
        disabled: !onShowStashDiffPicker,
        keybinding: <CaretRight className="size-3 text-subtle-foreground" />,
        onClick: () => openDiffPicker(onShowStashDiffPicker),
      },
    ],
    [
      hasStagedDiffableFiles,
      hasUnstagedDiffableFiles,
      isLoading,
      onShowBranchDiffPicker,
      onShowCommitDiffPicker,
      onShowStashDiffPicker,
      openDiffPicker,
      openScopedDiff,
      t,
    ],
  );

  const selectedEntries = [...selectedEntryIds].flatMap((entryId) => {
    const entry = entryById.get(entryId);
    return entry ? [entry] : [];
  });

  return (
    <div
      className="flex h-full min-h-0 flex-col select-none"
      onKeyDown={(event) => {
        if (
          event.key !== "Delete" ||
          isLoading ||
          selectedEntries.length === 0 ||
          !(event.target as HTMLElement | null)?.closest('[role="treeitem"]')
        ) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        void handleDeleteEntries(selectedEntries);
      }}
    >
      {hasFiles ? (
        <>
          <SidebarToolbar>
            <div className="flex min-w-0 flex-1 items-center gap-1.5">
              <ButtonGroup ref={diffMenuAnchorRef}>
                <Button
                  type="button"
                  variant="default"
                  size="xs"
                  onClick={() => openScopedDiff("all")}
                  disabled={!onViewDiff || isLoading}
                  aria-label={t("git.viewDiff")}
                >
                  {t("git.viewDiff")}
                </Button>
                <ButtonGroupSeparator />
                <Button
                  type="button"
                  variant="default"
                  size="icon-xs"
                  onClick={() => setIsDiffMenuOpen((open) => !open)}
                  disabled={isLoading}
                  active={isDiffMenuOpen}
                  aria-label={t("git.chooseDiffSource")}
                  aria-haspopup="menu"
                  aria-expanded={isDiffMenuOpen}
                >
                  <CaretDown className="size-3" />
                </Button>
              </ButtonGroup>
              <Dropdown
                isOpen={isDiffMenuOpen}
                anchorRef={diffMenuAnchorRef}
                anchorAlign="start"
                onClose={() => setIsDiffMenuOpen(false)}
                items={diffMenuItems}
                className="min-w-37.5"
              />
              {renderDiffStatsBadge(allDiffStats, "shrink-0")}
            </div>
            <div className="flex shrink-0 items-center gap-1">
              {unstagedFiles.length > 0 && (
                <SidebarHeaderIconButton
                  onClick={handleStashAllUnstaged}
                  disabled={isLoading}
                  className="disabled:opacity-50"
                  tooltip={t("git.stashAllUnstaged")}
                  tooltipSide="bottom"
                  aria-label={t("git.stashAllUnstaged")}
                >
                  <Archive />
                </SidebarHeaderIconButton>
              )}
              {unstagedFiles.length > 0 && (
                <SidebarHeaderIconButton
                  onClick={handleStageAll}
                  disabled={isLoading}
                  className="disabled:opacity-50"
                  tooltip={t("git.stageAllChanges")}
                  tooltipSide="bottom"
                  aria-label={t("git.stageAllChanges")}
                >
                  <Plus />
                </SidebarHeaderIconButton>
              )}
              {stagedFiles.length > 0 && (
                <SidebarHeaderIconButton
                  onClick={handleUnstageAll}
                  disabled={isLoading}
                  className="disabled:opacity-50"
                  tooltip={t("git.unstageAllChanges")}
                  tooltipSide="bottom"
                  aria-label={t("git.unstageAllChanges")}
                >
                  <Minus />
                </SidebarHeaderIconButton>
              )}
            </div>
          </SidebarToolbar>
          <ScrollArea
            className="min-h-0 flex-1"
            contentClassName="px-2 py-2"
            reserveScrollbarGutter
          >
            {trackedFiles.length > 0 && (
              <section className="space-y-0.5">
                {renderSectionHeader("tracked", t("git.tracked"), trackedFiles.length)}
                {!collapsedSections.has("tracked") ? (
                  <SidebarTree
                    label={t("git.trackedFiles")}
                    className="file-tree-container overflow-visible!"
                    style={
                      {
                        "--file-tree-row-height": `${fileTreePresentation.rowHeight}px`,
                      } as React.CSSProperties
                    }
                  >
                    {gitChangesFolderView
                      ? trackedFolderTree && renderFolderTree(trackedFolderTree, "tracked")
                      : renderFlatFileList(groupedTrackedFiles)}
                  </SidebarTree>
                ) : null}
              </section>
            )}
            {untrackedFiles.length > 0 && (
              <section className="space-y-0.5 pt-2">
                {renderSectionHeader("untracked", t("git.untracked"), untrackedFiles.length)}
                {!collapsedSections.has("untracked") ? (
                  <SidebarTree
                    label={t("git.untrackedFiles")}
                    className="file-tree-container overflow-visible!"
                    style={
                      {
                        "--file-tree-row-height": `${fileTreePresentation.rowHeight}px`,
                      } as React.CSSProperties
                    }
                  >
                    {gitChangesFolderView
                      ? untrackedFolderTree && renderFolderTree(untrackedFolderTree, "untracked")
                      : renderFlatFileList(groupedUntrackedFiles)}
                  </SidebarTree>
                ) : null}
              </section>
            )}
          </ScrollArea>
        </>
      ) : (
        <Empty className="flex-1" tone="success">
          <EmptyMedia variant="icon">
            <Check />
          </EmptyMedia>
          <EmptyTitle>{t("git.workingTreeClean")}</EmptyTitle>
        </Empty>
      )}

      <Dropdown
        isOpen={contextMenu.isOpen}
        point={contextMenu.position}
        items={[
          {
            id: "commit-selection",
            label: t("git.commit"),
            icon: <GitCommit />,
            disabled: contextMenuEntries.length === 0 || isLoading,
            onClick: () => void handleCommitEntries(contextMenuEntries),
          },
          {
            id: "rollback-selection",
            label: t("git.rollback"),
            icon: <RotateCcw />,
            disabled: !contextMenuHasTrackedFiles || isLoading,
            onClick: () => void handleRollbackEntries(contextMenuEntries),
          },
          {
            id: "show-selection-diff",
            label: t("git.showDiff"),
            icon: <GitDiff />,
            disabled: contextMenuFilePaths.length === 0 || isLoading,
            onClick: () => onViewFilesDiff?.(contextMenuFilePaths),
          },
          {
            id: "jump-to-source",
            label: t("git.jumpToSource"),
            icon: <FolderOpen />,
            disabled: !contextMenuTarget || !onOpenPath,
            onClick: () => {
              if (contextMenuTarget) {
                onOpenPath?.(contextMenuTarget.path, contextMenuTarget.kind === "folder");
              }
            },
          },
          {
            id: "delete-selection",
            label: t("git.delete"),
            icon: <Trash2 />,
            disabled: contextMenuDeletionPaths.length === 0 || isLoading,
            className: "text-destructive",
            onClick: () => void handleDeleteEntries(contextMenuEntries),
          },
          ...(contextMenuHasUntrackedFiles
            ? [
                {
                  id: "add-selection-to-vcs",
                  label: t("git.addToVcs"),
                  icon: <Plus />,
                  disabled: isLoading,
                  onClick: () => void handleAddToVcs(contextMenuEntries),
                },
                {
                  id: "add-selection-to-gitignore",
                  label:
                    contextMenuEntries.length > 1
                      ? t("git.addSelectionToGitignore", { count: contextMenuEntries.length })
                      : t("git.addToGitignore"),
                  icon: <EyeSlash />,
                  disabled: isLoading,
                  onClick: () => void handleAddToIgnoreFile(contextMenuEntries, "gitignore"),
                },
                {
                  id: "add-selection-to-local-exclude",
                  label:
                    contextMenuEntries.length > 1
                      ? t("git.addSelectionToLocalExclude", { count: contextMenuEntries.length })
                      : t("git.addToLocalExclude"),
                  icon: <EyeSlash />,
                  disabled: isLoading,
                  onClick: () => void handleAddToIgnoreFile(contextMenuEntries, "exclude"),
                },
              ]
            : []),
          {
            id: "stash-selection",
            label: t("git.stash"),
            icon: <Archive />,
            disabled: contextMenuEntries.length === 0 || isLoading,
            onClick: () => handleStashEntries(contextMenuEntries),
          },
        ]}
        onClose={contextMenu.close}
      />

      <StashMessageModal
        isOpen={stashModal.isOpen}
        onClose={() => setStashModal((prev) => ({ ...prev, isOpen: false }))}
        onConfirm={handleConfirmStash}
        title={stashModal.type === "selection" ? t("git.stashSelected") : t("git.stashAllUnstaged")}
        placeholder={
          stashModal.type === "selection"
            ? t("git.stashMessageDefaultSelection")
            : t("git.stashMessageDefaultAll")
        }
      />
    </div>
  );
};

export default GitStatusPanel;
