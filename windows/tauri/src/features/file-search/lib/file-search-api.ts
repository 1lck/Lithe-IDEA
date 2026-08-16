import { executeCore } from "@/core/lithe-core-client";
import { getFilenameFromPath } from "@/features/file-system/controllers/file-utils";
import { joinPath } from "@/utils/path-helpers";

export interface SearchMatchRange {
  start: number;
  end: number;
}

export interface SearchMatch {
  line_number: number;
  line_content: string;
  column_start: number;
  column_end: number;
  match_ranges?: SearchMatchRange[];
  context_before?: string[];
  context_after?: string[];
}

export interface FileSearchResult {
  file_path: string;
  matches: SearchMatch[];
  total_matches: number;
}

export interface SearchFilesResponse {
  results: FileSearchResult[];
  total_files: number;
  searched_files: number;
  searchable_files: number;
  files_with_matches: number;
  next_file_offset: number;
  has_more: boolean;
  is_indexing: boolean;
  indexed_files: number;
  regex_fallback_error?: string | null;
}

export interface SearchFilesRequest {
  root_paths: string[];
  query: string;
  case_sensitive?: boolean;
  whole_word?: boolean;
  use_regex?: boolean;
  max_results?: number;
  file_offset?: number;
  context_lines?: number;
}

export interface FffSearchHit {
  path: string;
  name: string;
  relative_path: string;
  score: number;
}

export interface FffIndexedFile {
  path: string;
  name: string;
  relative_path: string;
}

export interface FffScanStatus {
  is_scanning: boolean;
  scanned_files_count: number;
  indexed_files: number;
  is_watcher_ready: boolean;
  is_warmup_complete: boolean;
}

interface CoreSearchMatch {
  kind: string;
  path: string;
  line: number | null;
  preview: string;
}

interface CoreWorkspaceNode {
  path: string;
}

function coreData<T>(response: Awaited<ReturnType<typeof executeCore<T>>>): T {
  if (response.ok) return response.data;
  throw new Error(response.error.message);
}

export async function searchFilesContent(
  request: SearchFilesRequest,
): Promise<SearchFilesResponse> {
  const maxResults = request.max_results ?? 500;
  const responses = await Promise.all(
    request.root_paths.map(async (root) => {
      const response = await executeCore<{ matches: CoreSearchMatch[] }>(
        {
          id: crypto.randomUUID(),
          command: "workspace.search",
          payload: {
            root,
            query: request.query,
            caseSensitive: request.case_sensitive ?? false,
            wholeWords: request.whole_word ?? false,
            regularExpression: request.use_regex ?? false,
            maxResults,
            fileMask: "",
          },
        },
      );
      return { root, matches: coreData(response).matches };
    }),
  );

  const grouped = new Map<string, FileSearchResult>();
  for (const { root, matches } of responses) {
    for (const match of matches) {
      if (match.kind !== "content") continue;
      const filePath = joinPath(root, match.path);
      const result = grouped.get(filePath) ?? {
        file_path: filePath,
        matches: [],
        total_matches: 0,
      };
      const lineContent = match.preview;
      const columnStart = Math.max(
        0,
        request.case_sensitive
          ? lineContent.indexOf(request.query)
          : lineContent.toLocaleLowerCase().indexOf(request.query.toLocaleLowerCase()),
      );
      result.matches.push({
        line_number: match.line ?? 1,
        line_content: lineContent,
        column_start: columnStart,
        column_end: columnStart + request.query.length,
      });
      result.total_matches += 1;
      grouped.set(filePath, result);
    }
  }

  const results = [...grouped.values()].slice(0, maxResults);
  return {
    results,
    total_files: results.length,
    searched_files: results.length,
    searchable_files: results.length,
    files_with_matches: results.length,
    next_file_offset: results.length,
    has_more: grouped.size > results.length,
    is_indexing: false,
    indexed_files: results.length,
  };
}

export async function fffEnsureWorkspaces(rootPaths: readonly string[]): Promise<void> {
  await Promise.all(rootPaths.map((root) => listWorkspaceFiles(root)));
}

export async function fffScanStatus(rootPaths: readonly string[]): Promise<FffScanStatus> {
  const files = await Promise.all(rootPaths.map((root) => listWorkspaceFiles(root)));
  const count = files.reduce((total, entries) => total + entries.length, 0);
  return {
    is_scanning: false,
    scanned_files_count: count,
    indexed_files: count,
    is_watcher_ready: true,
    is_warmup_complete: true,
  };
}

export async function fffSearchFiles(
  query: string,
  rootPaths: readonly string[],
  limit = 100,
): Promise<FffSearchHit[]> {
  const files = await fffListFiles(rootPaths);
  const normalizedQuery = query.toLocaleLowerCase();
  return files
    .filter((file) => file.relative_path.toLocaleLowerCase().includes(normalizedQuery))
    .slice(0, limit)
    .map((file, index) => ({ ...file, score: limit - index }));
}

export async function fffListFiles(rootPaths: readonly string[]): Promise<FffIndexedFile[]> {
  const workspaces = await Promise.all(
    rootPaths.map(async (root) => ({ root, files: await listWorkspaceFiles(root) })),
  );
  return workspaces.flatMap(({ root, files }) =>
    files.map((relativePath) => ({
      path: joinPath(root, relativePath),
      name: getFilenameFromPath(relativePath),
      relative_path: relativePath,
    })),
  );
}

export async function fffTrackAccess(_path: string): Promise<void> {
  // Access ranking is frontend-owned until the shared contract exposes it.
}

async function listWorkspaceFiles(root: string): Promise<string[]> {
  const response = await executeCore<{ root: CoreWorkspaceNode; files: string[] }>({
    id: crypto.randomUUID(),
    command: "workspace.snapshot",
    payload: { root },
  });
  return coreData(response).files;
}
