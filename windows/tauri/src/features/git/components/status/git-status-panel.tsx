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
import { useVirtualizer } from "@tanstack/react-virtual";
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
import { Button } from "@/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/ui/button-group";
import { Checkbox } from "@/ui/checkbox";
import { Dropdown, useDropdownMenu, type MenuItem } from "@/ui/dropdown";
import { Empty, EmptyMedia, EmptyTitle } from "@/ui/empty";
import { ScrollArea } from "@/ui/scroll-area";
import { showConfirmDialog } from "@/ui/dialog";
import { SidebarHeaderIconButton, SidebarSectionHeader, SidebarToolbar } from "@/ui/sidebar";
import { SidebarTree, SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import {
  compactPathTreeBranch,
  type PathTreeBranch,
  type PathTreeNode,
} from "@/features/sidebar/lib/path-tree";
import { cn } from "@/utils/cn";
import { getBaseName, joinPath } from "@/utils/path-helpers";
import { createStash } from "../../api/git-stash-api";
import {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  rollbackFilesChanges,
  setFilesStaged,
} from "../../api/git-status-api";
import type { GitFile } from "../../types/git.types";
import {
  buildGitFolderTree,
  buildGitStatusPresentation,
  GIT_STATUS_ORDER,
  type GitFolderTree,
  type GitStatusGroup,
} from "../../utils/git-status-model";
import { deleteGitStatusPaths } from "../../utils/git-status-deletion";
import {
  buildGitIgnorePaths,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
  resolveGitFileMutationPaths,
  resolveGitStatusDeletionPaths,
  resolveGitStatusContextSelection,
  updateGitStatusSelection,
} from "../../utils/git-status-selection";
import { StashMessageModal } from "../stash/git-stash-modal";
import { GitFileItem } from "./git-status-file-item";
import { showGitPatchDialog } from "../../services/git-patch-dialog-service";

interface GitStatusPanelProps {
  files: GitFile[];
  commitSelectedPaths: ReadonlySet<string>;
  onCommitSelectedPathsChange: (paths: Set<string>) => void;
  collapsedFolders: ReadonlySet<string>;
  onCollapsedFoldersChange: (folders: Set<string>) => void;
  collapsedSections: ReadonlySet<string>;
  onCollapsedSectionsChange: (sections: Set<string>) => void;
  onFileSelect?: (path: string, staged: boolean) => void;
  onOpenPath?: (path: string, isDirectory: boolean, repositoryPath?: string) => void;
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

type GitStatusVirtualRow =
  | {
      kind: "section";
      key: string;
      section: StatusSection;
      count: number;
    }
  | {
      kind: "folder";
      key: string;
      section: StatusSection;
      branch: PathTreeBranch<GitFile>;
      label: string;
      depth: number;
    }
  | {
      kind: "file";
      key: string;
      section: StatusSection;
      file: GitFile;
      depth: number;
      showDirectory: boolean;
      reserveDisclosureSpace: boolean;
    }
  | {
      kind: "spacer";
      key: string;
      size: number;
    };

const GIT_STATUS_SECTION_HEADER_HEIGHT = 32;
const GIT_STATUS_SECTION_CONTENT_GAP = 2;
const GIT_STATUS_SECTION_GAP = 8;
const GIT_STATUS_TREE_OVERSCAN = 12;

const getFileEntryId = (filePath: string) => `file:${filePath}`;
const getFolderEntryId = (section: StatusSection, folderPath: string) =>
  `folder:${section}:${folderPath}`;

function groupGitFilesByRepository(
  files: readonly GitFile[],
  fallbackRepoPath?: string,
): Array<{ repoPath: string; files: GitFile[] }> {
  const filesByRepository = new Map<string, GitFile[]>();

  for (const file of files) {
    const fileRepoPath = getGitFileRepositoryPath(file, fallbackRepoPath);
    if (!fileRepoPath) continue;
    const repositoryFiles = filesByRepository.get(fileRepoPath) ?? [];
    repositoryFiles.push(file);
    filesByRepository.set(fileRepoPath, repositoryFiles);
  }

  return [...filesByRepository.entries()].map(([fileRepoPath, repositoryFiles]) => ({
    repoPath: fileRepoPath,
    files: repositoryFiles,
  }));
}

function getRepoRelativePaths(files: readonly GitFile[]): string[] {
  return [
    ...new Set(files.map(getGitFileRepositoryRelativePath).filter(Boolean)),
  ].sort((left, right) => left.localeCompare(right));
}

const GitStatusPanel = ({
  files,
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
  const statusViewportRef = useRef<HTMLDivElement>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isDiffMenuOpen, setIsDiffMenuOpen] = useState(false);
  const [optimisticStageMap, setOptimisticStageMap] = useState<Record<string, boolean>>({});
  const [selectedEntryIds, setSelectedEntryIds] = useState<Set<string>>(new Set());

  const [stashModal, setStashModal] = useState<{
    isOpen: boolean;
    type: "selection" | "all";
    filePaths?: string[];
    includeUntracked?: boolean;
    repoPath?: string;
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
        filePaths: resolveGitFileMutationPaths([file]),
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
        const files = folderState.descendantFilePaths.flatMap((filePath) => {
          const file = displayFileByPath.get(filePath);
          return file ? [file] : [];
        });
        entries.set(id, {
          id,
          kind: "folder",
          path: branch.path,
          filePaths: resolveGitFileMutationPaths(files),
          files,
        });
        branch.children.forEach(registerNode);
      };

      tree.nodes.forEach(registerNode);
    };

    registerFolders(trackedFolderTree, "tracked");
    registerFolders(untrackedFolderTree, "untracked");
    return entries;
  }, [displayFileByPath, trackedFolderTree, untrackedFolderTree, visibleFiles]);

  const statusRows = useMemo(() => {
    const rows: GitStatusVirtualRow[] = [];

    const appendTreeNode = (node: PathTreeNode<GitFile>, depth: number, section: StatusSection) => {
      if (node.type === "leaf") {
        rows.push({
          kind: "file",
          key: `${section}:${node.id}`,
          section,
          file: node.item,
          depth,
          showDirectory: false,
          reserveDisclosureSpace: true,
        });
        return;
      }

      const compacted = fileTreePresentation.compactFolders
        ? compactPathTreeBranch(node)
        : { branch: node, label: node.name };
      const branch = compacted.branch;
      rows.push({
        kind: "folder",
        key: `${section}:${node.id}`,
        section,
        branch,
        label: compacted.label,
        depth,
      });

      if (collapsedFolders.has(`${section}:${branch.path}`)) return;
      for (const child of branch.children) appendTreeNode(child, depth + 1, section);
    };

    const appendSection = (
      section: StatusSection,
      fileCount: number,
      tree: GitFolderTree | null,
      groupedFiles: Record<GitStatusGroup, GitFile[]>,
    ) => {
      if (fileCount === 0) return;
      if (rows.length > 0) {
        rows.push({ kind: "spacer", key: `${section}:section-gap`, size: GIT_STATUS_SECTION_GAP });
      }
      rows.push({ kind: "section", key: `${section}:header`, section, count: fileCount });
      if (collapsedSections.has(section)) return;

      rows.push({
        kind: "spacer",
        key: `${section}:content-gap`,
        size: GIT_STATUS_SECTION_CONTENT_GAP,
      });
      if (gitChangesFolderView && tree) {
        for (const node of tree.nodes) appendTreeNode(node, 0, section);
        return;
      }

      for (const status of GIT_STATUS_ORDER) {
        for (const file of groupedFiles[status]) {
          rows.push({
            kind: "file",
            key: `${section}:${status}:${file.staged ? "staged" : "unstaged"}:${file.path}`,
            section,
            file,
            depth: 0,
            showDirectory: true,
            reserveDisclosureSpace: false,
          });
        }
      }
    };

    appendSection("tracked", trackedFiles.length, trackedFolderTree, groupedTrackedFiles);
    appendSection("untracked", untrackedFiles.length, untrackedFolderTree, groupedUntrackedFiles);
    return rows;
  }, [
    collapsedFolders,
    collapsedSections,
    fileTreePresentation.compactFolders,
    gitChangesFolderView,
    groupedTrackedFiles,
    groupedUntrackedFiles,
    trackedFiles.length,
    trackedFolderTree,
    untrackedFiles.length,
    untrackedFolderTree,
  ]);

  const statusVirtualizer = useVirtualizer({
    count: statusRows.length,
    getScrollElement: () => statusViewportRef.current,
    estimateSize: (index) => {
      const row = statusRows[index];
      if (row?.kind === "section") return GIT_STATUS_SECTION_HEADER_HEIGHT;
      if (row?.kind === "spacer") return row.size;
      return fileTreePresentation.rowHeight;
    },
    getItemKey: (index) => statusRows[index]?.key ?? index,
    overscan: GIT_STATUS_TREE_OVERSCAN,
  });

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

  const handleSetFilesStaged = async (filesToStage: GitFile[], staged: boolean): Promise<boolean> => {
    const repositoryGroups = groupGitFilesByRepository(filesToStage, repoPath);
    if (repositoryGroups.length === 0) return false;
    const displayFilePaths = filesToStage.map((file) => file.path);

    setOptimisticStage(displayFilePaths, staged);
    setIsLoading(true);
    try {
      const results = await Promise.all(
        repositoryGroups.map(({ repoPath: fileRepoPath, files: repositoryFiles }) =>
          setFilesStaged(fileRepoPath, resolveGitFileMutationPaths(repositoryFiles), staged),
        ),
      );
      const success = results.every(Boolean);
      if (!success) {
        setOptimisticStage(displayFilePaths, !staged);
        return false;
      }
      await onRefresh?.();
      return true;
    } finally {
      setIsLoading(false);
    }
  };

  const handleStageAll = async () => {
    const repositoryGroups = groupGitFilesByRepository(unstagedFiles, repoPath);
    if (repositoryGroups.length === 0) return;
    setOptimisticStage(
      unstagedFiles.map((file) => file.path),
      true,
    );
    setIsLoading(true);
    try {
      const results = await Promise.all(
        repositoryGroups.map(({ repoPath: fileRepoPath, files: repositoryFiles }) =>
          setFilesStaged(fileRepoPath, resolveGitFileMutationPaths(repositoryFiles), true),
        ),
      );
      const success = results.every(Boolean);
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
    const repositoryGroups = groupGitFilesByRepository(stagedFiles, repoPath);
    if (repositoryGroups.length === 0) return;
    setOptimisticStage(
      stagedFiles.map((file) => file.path),
      false,
    );
    setIsLoading(true);
    try {
      const results = await Promise.all(
        repositoryGroups.map(({ repoPath: fileRepoPath, files: repositoryFiles }) =>
          setFilesStaged(fileRepoPath, resolveGitFileMutationPaths(repositoryFiles), false),
        ),
      );
      const success = results.every(Boolean);
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
    const filePaths = [
      ...new Set(entries.flatMap((entry) => entry.files.map((file) => file.path))),
    ];
    if (filePaths.length === 0) return;
    onCommitSelectedPathsChange(new Set(filePaths));
    onCommitSelection?.(filePaths);
  };

  const handleRollbackEntries = async (entries: GitStatusSelectionEntry[]) => {
    const trackedFilesToRollback = entries
      .flatMap((entry) => entry.files)
      .filter((file) => file.status !== "untracked");
    const displayTrackedFilePaths = [...new Set(trackedFilesToRollback.map((file) => file.path))];
    if (displayTrackedFilePaths.length === 0) return;

    if (
      confirmBeforeDiscard &&
      !(await showConfirmDialog(t("git.rollbackPathsConfirm", { count: displayTrackedFilePaths.length }), {
        title: t("git.rollback"),
        confirmLabel: t("git.rollback"),
      }))
    ) {
      return;
    }

    setIsLoading(true);
    try {
      await Promise.all(
        groupGitFilesByRepository(trackedFilesToRollback, repoPath).map(
          ({ repoPath: fileRepoPath, files: repositoryFiles }) =>
            rollbackFilesChanges(fileRepoPath, getRepoRelativePaths(repositoryFiles)),
        ),
      );
      await onRefresh?.();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      toast.error(t("git.operationError", { error: message }));
    } finally {
      setIsLoading(false);
    }
  };

  const handleDeleteEntries = async (entries: GitStatusSelectionEntry[]) => {
    const filePaths = resolveGitStatusDeletionPaths(entries);
    if (filePaths.length === 0) return;
    const singleFileEntry = entries.length === 1 && entries[0]?.kind === "file";
    const confirmationMessage = singleFileEntry
      ? t("git.deleteFileConfirm", {
          name: getBaseName(filePaths[0] ?? "", filePaths[0] ?? ""),
        })
      : t("git.deleteFilesConfirm", { count: filePaths.length });

    if (
      !(await showConfirmDialog(confirmationMessage, {
        title: t("git.delete"),
        confirmLabel: t("git.delete"),
      }))
    ) {
      return;
    }

    setIsLoading(true);
    try {
      const result = await deleteGitStatusPaths(filePaths, async (filePath) => {
        const file = entries.flatMap((entry) => entry.files).find((candidate) => candidate.path === filePath);
        const fileRepoPath = file ? getGitFileRepositoryPath(file, repoPath) : repoPath;
        const relativePath = file ? getGitFileRepositoryRelativePath(file) : filePath;
        if (!fileRepoPath) throw new Error("Missing Git repository path for delete operation");
        return deleteFile(joinPath(fileRepoPath, relativePath));
      }, async () => onRefresh?.());
      for (const failure of result.failures) {
        console.error(`Failed to delete source-control file ${failure.path}:`, failure.error);
      }
      if (result.refreshError) {
        console.error(
          "Failed to refresh source control after deleting files:",
          result.refreshError,
        );
        toast.error(t("git.refreshAfterDeleteFailed"));
      }
      if (result.failures.length > 0) {
        toast.error(t("git.deleteFilesFailed", { count: result.failures.length }));
      }
      setSelectedEntryIds(new Set());
    } finally {
      setIsLoading(false);
    }
  };

  const handleAddToVcs = async (entries: GitStatusSelectionEntry[]) => {
    const untrackedFilesToAdd = entries
      .flatMap((entry) => entry.files)
      .filter((file) => file.status === "untracked");
    if (untrackedFilesToAdd.length > 0) {
      await handleSetFilesStaged(untrackedFilesToAdd, true);
    }
  };

  const handleAddToIgnoreFile = async (
    entries: GitStatusSelectionEntry[],
    target: "gitignore" | "exclude",
  ) => {
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
      const results = await Promise.all(
        groupGitFilesByRepository(
          entries.flatMap((entry) => entry.files).filter((file) => file.status === "untracked"),
          repoPath,
        ).map(({ repoPath: fileRepoPath, files: repositoryFiles }) => {
          const repositoryPaths = buildGitIgnorePaths(
            repositoryFiles.map((file) => ({
              kind: "file" as const,
              path: getGitFileRepositoryRelativePath(file),
            })),
          );
          return target === "gitignore"
            ? addPathsToGitignore(fileRepoPath, repositoryPaths)
            : addPathsToLocalGitExclude(fileRepoPath, repositoryPaths);
        }),
      );
      if (results.every(Boolean)) {
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
    const repositoryGroups = groupGitFilesByRepository(
      entries.flatMap((entry) => entry.files),
      repoPath,
    );
    if (repositoryGroups.length !== 1) {
      toast.error(t("git.selectSingleRepositoryForStash"));
      return;
    }
    setStashModal({
      isOpen: true,
      type: "selection",
      filePaths: resolveGitFileMutationPaths(repositoryGroups[0]?.files ?? []),
      includeUntracked: entries
        .flatMap((entry) => entry.files)
        .some((file) => file.status === "untracked"),
      repoPath: repositoryGroups[0]?.repoPath,
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
    const repositoryGroups = groupGitFilesByRepository(unstagedFiles, repoPath);
    if (repositoryGroups.length !== 1) {
      toast.error(t("git.selectSingleRepositoryForStash"));
      return;
    }
    setStashModal({
      isOpen: true,
      type: "all",
      filePaths: resolveGitFileMutationPaths(repositoryGroups[0]?.files ?? []),
      includeUntracked: false,
      repoPath: repositoryGroups[0]?.repoPath,
    });
  };

  const handleConfirmStash = async (message: string) => {
    if (!repoPath) return;

    if (stashModal.filePaths?.length) {
      await createStash(
        stashModal.repoPath ?? repoPath,
        message || t(stashModal.type === "all" ? "git.stashAllUnstagedChanges" : "git.stashSelectedDefault"),
        stashModal.includeUntracked,
        stashModal.filePaths,
      );
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

  const renderSectionHeader = (section: StatusSection, title: string, count: number) => (
    <SidebarSectionHeader
      variant="surface"
      count={count}
      expanded={!collapsedSections.has(section)}
      onToggle={() => toggleSectionCollapsed(section)}
      className="h-full"
      style={{ height: "100%" }}
    >
      {title}
    </SidebarSectionHeader>
  );

  const focusStatusRow = (index: number) => {
    statusVirtualizer.scrollToIndex(index, { align: "auto" });
    globalThis.requestAnimationFrame?.(() => {
      statusViewportRef.current
        ?.querySelector<HTMLButtonElement>(
          `[data-git-status-row-index="${index}"] [role="treeitem"]`,
        )
        ?.focus();
    });
  };

  const findFocusableStatusRow = (start: number, step: -1 | 1) => {
    for (let index = start; index >= 0 && index < statusRows.length; index += step) {
      const row = statusRows[index];
      if (row?.kind === "folder" || row?.kind === "file") return index;
    }
    return -1;
  };

  const handleStatusTreeKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const target = event.target as HTMLElement;
    if (!target.closest("[role=treeitem]")) return;
    const rowElement = target.closest<HTMLElement>("[data-git-status-row-index]");
    const rowIndex = Number(rowElement?.dataset.gitStatusRowIndex);
    const row = statusRows[rowIndex];
    if (!Number.isInteger(rowIndex) || (row?.kind !== "folder" && row?.kind !== "file")) return;

    let targetIndex = -1;
    if (event.key === "ArrowDown") {
      targetIndex = findFocusableStatusRow(rowIndex + 1, 1);
    } else if (event.key === "ArrowUp") {
      targetIndex = findFocusableStatusRow(rowIndex - 1, -1);
    } else if (event.key === "Home") {
      targetIndex = findFocusableStatusRow(0, 1);
    } else if (event.key === "End") {
      targetIndex = findFocusableStatusRow(statusRows.length - 1, -1);
    } else if (event.key === "ArrowRight" && row.kind === "folder") {
      const collapsed = collapsedFolders.has(`${row.section}:${row.branch.path}`);
      if (collapsed) {
        event.preventDefault();
        toggleFolderCollapsed(row.section, row.branch.path);
        return;
      }
      const nextIndex = findFocusableStatusRow(rowIndex + 1, 1);
      const nextRow = statusRows[nextIndex];
      if (
        nextRow &&
        (nextRow.kind === "folder" || nextRow.kind === "file") &&
        nextRow.section === row.section &&
        nextRow.depth === row.depth + 1
      ) {
        targetIndex = nextIndex;
      }
    } else if (event.key === "ArrowLeft") {
      if (row.kind === "folder" && !collapsedFolders.has(`${row.section}:${row.branch.path}`)) {
        event.preventDefault();
        toggleFolderCollapsed(row.section, row.branch.path);
        return;
      }
      for (let index = rowIndex - 1; index >= 0; index -= 1) {
        const candidate = statusRows[index];
        if (
          candidate &&
          (candidate.kind === "folder" || candidate.kind === "file") &&
          candidate.section === row.section &&
          candidate.depth < row.depth
        ) {
          targetIndex = index;
          break;
        }
      }
    }

    if (targetIndex < 0) return;
    event.preventDefault();
    focusStatusRow(targetIndex);
  };

  const renderStatusRow = (row: GitStatusVirtualRow) => {
    if (row.kind === "spacer") return null;
    if (row.kind === "section") {
      return renderSectionHeader(
        row.section,
        t(row.section === "tracked" ? "git.tracked" : "git.untracked"),
        row.count,
      );
    }

    if (row.kind === "file") {
      const entry = entryById.get(getFileEntryId(row.file.path));
      if (!entry) return null;
      return (
        <GitFileItem
          file={row.file}
          active={selectedEntryIds.has(entry.id)}
          onClick={(event) => {
            handleSelectEntry(event, entry);
            if (!event.ctrlKey && !event.metaKey) {
              onFileSelect?.(row.file.path, row.file.staged);
            }
          }}
          onContextMenu={(event) => handleContextMenu(event, entry)}
          checked={commitSelectedPaths.has(row.file.path)}
          onCheckedChange={(checked) => handleSetCommitPathsSelected([row.file.path], checked)}
          showDirectory={row.showDirectory}
          showFileIcon={fileTreePresentation.showIcons}
          showIndentGuides={fileTreePresentation.showIndentGuides}
          indentSize={fileTreePresentation.indentSize}
          rowHeight={fileTreePresentation.rowHeight}
          indentLevel={row.depth}
          reserveDisclosureSpace={row.reserveDisclosureSpace}
          repoPath={repoPath}
        />
      );
    }

    const tree = row.section === "tracked" ? trackedFolderTree : untrackedFolderTree;
    const folderState = tree?.folderStateById.get(row.branch.id);
    const entry = entryById.get(getFolderEntryId(row.section, row.branch.path));
    if (!folderState || !entry) return null;
    const isCollapsed = collapsedFolders.has(`${row.section}:${row.branch.path}`);
    const isChecked = folderState.descendantFilePaths.every((filePath) =>
      commitSelectedPaths.has(filePath),
    );

    return (
      <SidebarTreeRow
        depth={row.depth}
        indentSize={fileTreePresentation.indentSize}
        baseIndent={FILE_TREE_BASE_INDENT}
        showGuides={fileTreePresentation.showIndentGuides}
        active={selectedEntryIds.has(entry.id)}
        expanded={!isCollapsed}
        onToggle={() => toggleFolderCollapsed(row.section, row.branch.path)}
        onClick={(event) => {
          handleSelectEntry(event, entry);
          if (!event.ctrlKey && !event.metaKey) {
            onViewFilesDiff?.(entry.filePaths);
          }
        }}
        onDoubleClick={() => toggleFolderCollapsed(row.section, row.branch.path)}
        onContextMenu={(event) => handleContextMenu(event, entry)}
        label={row.label}
        trailing={
          <span className="shrink-0 text-[10px] leading-none text-subtle-foreground">
            {t("git.diffFileCount", {
              count: entry.files.length,
              plural: entry.files.length === 1 ? "" : "s",
            })}
          </span>
        }
        className="h-full py-0.5"
        style={{ height: fileTreePresentation.rowHeight }}
        leading={
          fileTreePresentation.showIcons ? (
            <ThemedFileIcon
              fileName={row.branch.name}
              isDir
              isExpanded={!isCollapsed}
              className="file-tree-node-icon shrink-0 text-subtle-foreground"
            />
          ) : null
        }
        action={
          <Checkbox
            checked={isChecked}
            onCheckedChange={(checked) =>
              handleSetCommitPathsSelected(folderState.descendantFilePaths, checked)
            }
            disabled={folderState.descendantFilePaths.length === 0}
            aria-label={
              isChecked
                ? t("git.excludeFolderFromCommit", { name: row.label })
                : t("git.includeFolderInCommit", { name: row.label })
            }
          />
        }
        draggable={!!repoPath}
        onDragStart={(event) => {
          if (!repoPath) return;
          writeSidebarResourceDragData(event.dataTransfer, {
            type: "file",
            path: `${repoPath}/${row.branch.path}`,
            name: row.branch.name,
            isDir: true,
          });
        }}
        title={row.branch.path}
      />
    );
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
  const contextMenuRepositories = groupGitFilesByRepository(contextMenuFiles, repoPath);
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
      onContextMenu={(event) => contextMenu.open(event, { entryIds: [] })}
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
            viewportProps={{ ref: statusViewportRef }}
            reserveScrollbarGutter
          >
            <SidebarTree
              label={`${t("git.trackedFiles")} / ${t("git.untrackedFiles")}`}
              className="file-tree-container relative overflow-visible!"
              onKeyDown={handleStatusTreeKeyDown}
              style={
                {
                  "--file-tree-row-height": `${fileTreePresentation.rowHeight}px`,
                  height: statusVirtualizer.getTotalSize(),
                } as React.CSSProperties
              }
            >
              {statusVirtualizer.getVirtualItems().map((virtualRow) => {
                const row = statusRows[virtualRow.index];
                if (!row) return null;
                return (
                  <div
                    key={row.key}
                    data-git-status-row-index={virtualRow.index}
                    className="absolute inset-x-0 top-0"
                    style={{
                      height: virtualRow.size,
                      transform: `translateY(${virtualRow.start}px)`,
                    }}
                  >
                    {renderStatusRow(row)}
                  </div>
                );
              })}
            </SidebarTree>
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
        items={
          contextMenu.data?.entryIds.length === 0
            ? [
                {
                  id: "no-actions-here",
                  label: t("ui.noActionsHere"),
                  disabled: true,
                  onClick: () => {},
                },
              ]
            : [
                {
                  id: "create-patch-selection",
                  label: contextMenuRepositories.length === 1 ? t("git.patch.create") : t("git.patch.singleRepository"),
                  icon: <GitDiff />,
                  disabled: isLoading || contextMenuRepositories.length !== 1,
                  onClick: () => {
                    const repository = contextMenuRepositories[0];
                    if (repository) void showGitPatchDialog(repository.repoPath, { mode: "export", paths: getRepoRelativePaths(repository.files) });
                  },
                },
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
                      const file = contextMenuTarget.files[0];
                      const isDirectory = contextMenuTarget.kind === "folder";
                      const prefixLength = file?.repositoryRelativePath
                        ? file.path.length - file.repositoryRelativePath.length
                        : 0;
                      const path = isDirectory
                        ? contextMenuTarget.path.slice(prefixLength)
                        : contextMenuTarget.path;
                      onOpenPath?.(path, isDirectory, file?.repositoryPath);
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
                            ? t("git.addSelectionToGitignore", {
                                count: contextMenuEntries.length,
                              })
                            : t("git.addToGitignore"),
                        icon: <EyeSlash />,
                        disabled: isLoading,
                        onClick: () => void handleAddToIgnoreFile(contextMenuEntries, "gitignore"),
                      },
                      {
                        id: "add-selection-to-local-exclude",
                        label:
                          contextMenuEntries.length > 1
                            ? t("git.addSelectionToLocalExclude", {
                                count: contextMenuEntries.length,
                              })
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
              ]
        }
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
