import { configureWorkspaceIndexing } from "@/features/file-explorer/stores/workspace-indexing";
import { executeCore } from "@/core/lithe-core-client";
import { getFilenameFromPath } from "@/features/file-system/controllers/file-utils";
import { hiddenPathRules } from "@/features/settings/lib/hidden-path-rules";
import { rankNames } from "./rank-names";
import { joinPath, getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";

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
  next_file_offset: number | string;
  has_more: boolean;
  is_indexing: boolean;
  indexed_files: number;
  regex_fallback_error?: string | null;
}

export interface SearchFilesRequest {
  workspaceId?: string;
  root_paths: string[];
  scope_paths?: string[];
  query: string;
  case_sensitive?: boolean;
  whole_word?: boolean;
  use_regex?: boolean;
  max_results?: number;
  file_offset?: number | string;
  include_patterns?: string[];
  exclude_patterns?: string[];
  filter_root?: string;
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
  isIgnored?: boolean;
  kind: string;
  path: string;
  line: number | null;
  preview: string;
  sourceLine?: string;
  contentMatchRanges?: Array<{ start: number; length: number }>;
}

function coreData<T>(response: Awaited<ReturnType<typeof executeCore<T>>>): T {
  if (response.ok) return response.data;
  throw new Error(response.error.message);
}

interface NativeSearchCursor {
  rootIndex: number;
  cursor: string | null;
}

/** One Core keyset page; the continuation also tracks which workspace root owns it. */
export async function searchFilesContent(
  request: SearchFilesRequest,
): Promise<SearchFilesResponse> {
  const roots = request.root_paths.filter(
    (root) =>
      !request.scope_paths?.length ||
      request.scope_paths.some(
        (scope) => pathStartsWithRoot(scope, root) || pathStartsWithRoot(root, scope),
      ),
  );
  let cursor: NativeSearchCursor = { rootIndex: 0, cursor: null };
  if (typeof request.file_offset === "number" && request.file_offset !== 0)
    throw { kind: "unknown" };
  if (typeof request.file_offset === "string") {
    let decoded: unknown;
    try {
      decoded = JSON.parse(request.file_offset);
    } catch {
      throw { kind: "unknown" };
    }
    if (
      !decoded ||
      typeof decoded !== "object" ||
      !Number.isSafeInteger((decoded as NativeSearchCursor).rootIndex) ||
      (decoded as NativeSearchCursor).rootIndex < 0 ||
      (decoded as NativeSearchCursor).rootIndex >= roots.length ||
      !(
        (decoded as NativeSearchCursor).cursor === null ||
        typeof (decoded as NativeSearchCursor).cursor === "string"
      )
    ) {
      throw { kind: "unknown" };
    }
    cursor = decoded as NativeSearchCursor;
  }
  const root = roots[cursor.rootIndex];
  if (!root)
    return {
      results: [],
      total_files: 0,
      searched_files: 0,
      searchable_files: 0,
      files_with_matches: 0,
      next_file_offset: 0,
      has_more: false,
      is_indexing: false,
      indexed_files: 0,
    };
  await configureWorkspaceIndexing(root, [], false, request.workspaceId);
  const response = await executeCore<{ matches: CoreSearchMatch[]; nextCursor: string | null }>({
    id: crypto.randomUUID(),
    command: "workspace.searchEverywhere",
    payload: {
      root,
      workspaceRoots: request.root_paths,
      query: request.query,
      caseSensitive: request.case_sensitive ?? false,
      wholeWords: request.whole_word ?? false,
      regularExpression: request.use_regex ?? false,
      pageSize: Math.max(1, Math.min(request.max_results ?? 140, 200)),
      resultKinds: ["content"],
      cursor: cursor.cursor,
      scopePaths: request.scope_paths
        ?.filter((scope) => pathStartsWithRoot(scope, root) || pathStartsWithRoot(root, scope))
        .map((scope) => (pathStartsWithRoot(root, scope) ? "." : getRelativePath(scope, root))),
      includePathPatterns: request.include_patterns ?? [],
      excludePathPatterns: request.exclude_patterns ?? [],
      pathFilterPrefix: getRelativePath(root, request.filter_root ?? root).replace(/\\/g, "/"),
      includeContentRanges: true,
      ...hiddenPathRules(),
    },
  });
  const page = coreData(response);
  const grouped = new Map<string, FileSearchResult>();
  for (const match of page.matches) {
    if (match.kind !== "content") continue;
    const filePath = joinPath(root, match.path);
    const result = grouped.get(filePath) ?? { file_path: filePath, matches: [], total_matches: 0 };
    const lineContent = match.sourceLine ?? match.preview;
    const ranges =
      match.contentMatchRanges?.map((range) => ({
        start: range.start,
        end: range.start + range.length,
      })) ?? [];
    const columnStart = ranges[0]?.start ?? 0;
    result.matches.push({
      line_number: match.line ?? 1,
      line_content: lineContent,
      column_start: columnStart,
      column_end: ranges[0]?.end ?? columnStart,
      match_ranges: ranges,
    });
    result.total_matches++;
    grouped.set(filePath, result);
  }
  const next = page.nextCursor
    ? { rootIndex: cursor.rootIndex, cursor: page.nextCursor }
    : cursor.rootIndex + 1 < roots.length
      ? { rootIndex: cursor.rootIndex + 1, cursor: null }
      : null;
  const results = [...grouped.values()];
  return {
    results,
    total_files: results.length,
    searched_files: results.length,
    searchable_files: 0,
    files_with_matches: results.length,
    next_file_offset: next ? JSON.stringify(next) : 0,
    has_more: next !== null,
    is_indexing: false,
    indexed_files: 0,
  };
}

export async function fffEnsureWorkspaces(
  rootPaths: readonly string[],
  workspaceId?: string,
): Promise<void> {
  await Promise.all(rootPaths.map((root) => listWorkspaceFiles(root, rootPaths, workspaceId)));
}

export async function fffScanStatus(
  rootPaths: readonly string[],
  workspaceId?: string,
): Promise<FffScanStatus> {
  const files = await Promise.all(
    rootPaths.map((root) => listWorkspaceFiles(root, rootPaths, workspaceId)),
  );
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
  workspaceId?: string,
): Promise<FffSearchHit[]> {
  const files = await fffListFiles(rootPaths, workspaceId);
  // Scoring belongs to Core; the inventory is the only thing this adapter contributes.
  const ranked = await rankNames(
    query.trim(),
    files.map((file) => ({ name: file.name, path: file.relative_path })),
    {},
    limit,
  );
  return ranked
    .slice(0, limit)
    .map((hit) => ({ ...files[hit.index], score: hit.degree }));
}

export async function fffListFiles(
  rootPaths: readonly string[],
  workspaceId?: string,
): Promise<FffIndexedFile[]> {
  const workspaces = await Promise.all(
    rootPaths.map(async (root) => ({
      root,
      files: await listWorkspaceFiles(root, rootPaths, workspaceId),
    })),
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

async function listWorkspaceFiles(
  root: string,
  workspaceRoots: readonly string[],
  workspaceId?: string,
): Promise<string[]> {
  await configureWorkspaceIndexing(root, [], false, workspaceId);
  // Search consumes a flat inventory; directory rows are loaded lazily by the tree.
  const response = await executeCore<{
    files: string[];
    incompleteDirectories?: string[];
  }>({
    id: crypto.randomUUID(),
    command: "workspace.snapshot",
    payload: { root, workspaceRoots, includeTree: false, ...hiddenPathRules() },
  });
  const data = coreData(response);
  if (data.incompleteDirectories?.length)
    throw new Error("Workspace scan is incomplete: " + data.incompleteDirectories.join(", "));
  return data.files;
}
