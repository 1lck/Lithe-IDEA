import type { IndexingErrorCode } from "@/features/file-explorer/stores/workspace-indexing";

export type ContentSearchFailure =
  | string
  | { kind: "indexing"; code: IndexingErrorCode }
  | { kind: "unknown" };

export interface FileItem {
  name: string;
  path: string;
  isDir: boolean;
}

export interface CategorizedFiles {
  openBufferFiles: FileItem[];
  recentFilesInResults: FileItem[];
  otherFiles: FileItem[];
}

export type FileCategory = "open" | "recent" | "other";

export interface SearchResult {
  file: FileItem;
  score: number;
}

export interface ContentSearchOptions {
  caseSensitive: boolean;
  wholeWord: boolean;
  useRegex: boolean;
}
