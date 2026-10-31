export type VcsReadQuery =
  | { operation: "history"; cursor: string | null; limit: number }
  | { operation: "fileHistory"; path: string; cursor: string | null; limit: number }
  | { operation: "baseContent"; path: string; currentPath: string };
export interface VcsHistoryEntry {
  revision: { id: string; display: string; kind: string };
  author: string | null;
  date: string | null;
  message: string;
  changes: Array<{ path: string; oldPath: string | null; status: string; flags: string[] }>;
  changesTruncated: boolean;
}
export interface VcsHistoryPage {
  entries: VcsHistoryEntry[];
  nextCursor: string | null;
}
export interface VcsBaseContent {
  path: string;
  currentPath: string;
  content: string | null;
  binary: boolean;
  currentContent: string | null;
  currentBinary: boolean;
}
export interface VcsQuerySnapshot {
  requestId: string;
  generation: number;
  rootId: string;
  vcs: string;
  operation: VcsReadQuery["operation"];
  result: VcsHistoryPage | VcsBaseContent;
}
