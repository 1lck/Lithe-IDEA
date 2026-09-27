import type { HighlightToken } from "@/features/editor/types/wasm-parser/wasm-parser.types";
import type { GitDiff, GitDiffLine, GitHunk } from "./git.types";

export interface DiffViewerProps {
  onStageHunk?: (hunk: GitHunk) => void;
  onUnstageHunk?: (hunk: GitHunk) => void;
}

export interface DiffLineWithIndex extends GitDiffLine {
  diffIndex: number;
}

export interface ParsedHunk {
  header: GitDiffLine;
  lines: DiffLineWithIndex[];
  id: number;
}

export interface ImageContainerProps {
  label: string;
  labelColor: string;
  base64?: string;
  alt: string;
  zoom: number;
  removed?: boolean;
  emptyLabel?: string;
}

export interface DiffHeaderProps {
  fileName?: string;
  title?: string;
  diff?: GitDiff;
  viewMode?: "unified" | "split";
  onViewModeChange?: (mode: "unified" | "split") => void;

  commitHash?: string;
  totalFiles?: number;
  onExpandAll?: () => void;
  onCollapseAll?: () => void;

  showWhitespace: boolean;
  onShowWhitespaceChange: (show: boolean) => void;
  onClose?: () => void;
  showDisplayControls?: boolean;
}

export interface DiffHunkHeaderProps {
  hunk: ParsedHunk;
  stats?: { additions: number; deletions: number };
  hasInvisibleChanges?: boolean;
  hiddenLineCount?: number | null;
  isCollapsed: boolean;
  onToggleCollapse: () => void;
  isStaged: boolean;
  filePath: string;
  onStageHunk?: (hunk: GitHunk) => void;
  onUnstageHunk?: (hunk: GitHunk) => void;
  isInMultiFileView?: boolean;
}

export interface DiffLineProps {
  line: GitDiffLine;
  viewMode: "unified" | "split";
  splitSide?: "left" | "right";
  wordWrap: boolean;
  showWhitespace: boolean;
  fontSize: number;
  lineHeight: number;
  tabSize: number;
  tokens?: HighlightToken[];
  searchHighlights?: DiffSearchHighlight[];
  searchLineIndex?: number;
}

export interface DiffSearchHighlight {
  start: number;
  end: number;
  isCurrent: boolean;
}

export interface TextDiffViewerProps {
  diff: GitDiff;
  isStaged: boolean;
  viewMode: "unified" | "split";
  showWhitespace: boolean;
  onStageHunk?: (hunk: GitHunk) => void;
  onUnstageHunk?: (hunk: GitHunk) => void;
  isInMultiFileView?: boolean;
  isEmbeddedInScrollView?: boolean;
  searchHighlights?: Map<number, DiffSearchHighlight[]>;
}

export interface ImageDiffViewerProps {
  diff: GitDiff;
  fileName: string;
  onClose: () => void;
  commitHash?: string;
}

/**
 * Repository-owned identity of a working-tree file diff. Refreshes reuse it so
 * they read the same repository, path, and HEAD-to-worktree semantics as the
 * initial open instead of re-deriving them from workspace display paths.
 */
export interface WorkingTreeDiffTarget {
  repoPath: string;
  /** Path relative to repoPath. */
  filePath: string;
  /** Repository-relative source path for renames. */
  originalPath?: string;
  untracked: boolean;
}

export interface MultiFileDiff {
  title?: string;
  repoPath?: string;
  commitHash: string;
  commitMessage?: string;
  commitDescription?: string;
  commitAuthor?: string;
  commitDate?: string;
  files: GitDiff[];
  totalFiles: number;
  totalAdditions: number;
  totalDeletions: number;
  fileKeys?: string[];
  fileLabels?: string[];
  initiallyExpandedFileKey?: string;
  initiallySelectedFileKey?: string;
  /** Working-tree refresh identities keyed by file key. */
  workingTreeTargets?: Record<string, WorkingTreeDiffTarget>;
  isLoading?: boolean;
  indexingProgress?: {
    processed: number;
    total: number;
    label?: string;
  };
}
