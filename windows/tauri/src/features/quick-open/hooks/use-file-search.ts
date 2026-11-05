import { useEffect, useMemo, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getOpenBufferSearchSnapshot } from "@/features/editor/utils/open-buffer-search-snapshot";
import { useRecentFilesStore } from "@/features/file-system/stores/recent-files.store";
import type { RecentFile } from "@/features/file-system/types/recent-files.types";
import { rankNames, type RankedName } from "@/features/file-search/lib/rank-names";
import {
  MAX_OPEN_BUFFERS_SHOWN,
  MAX_OTHER_FILES_SHOWN,
  MAX_RECENT_FILES_NO_QUERY,
  MAX_RESULTS,
} from "../constants/limits";
import type { CategorizedFiles, FileItem } from "../types/quick-open.types";
import { filterQuickOpenRecentFiles, shouldIgnoreFile } from "../utils/file-filtering";

interface FileSearchOptions {
  hasLoadedFiles?: boolean;
  rootFolderPath?: string | null;
}

function insertSortedLimited<T>(
  items: T[],
  candidate: T,
  compare: (a: T, b: T) => number,
  limit: number,
) {
  if (limit <= 0) return;

  let low = 0;
  let high = items.length;
  while (low < high) {
    const midpoint = (low + high) >> 1;
    if (compare(candidate, items[midpoint]) < 0) {
      high = midpoint;
    } else {
      low = midpoint + 1;
    }
  }

  if (low >= limit && items.length >= limit) {
    return;
  }

  items.splice(low, 0, candidate);
  if (items.length > limit) {
    items.pop();
  }
}

function recentFileToItem(file: RecentFile): FileItem {
  return {
    name: file.name,
    path: file.path,
    isDir: false,
  };
}

/** Buckets Core's ranked hits; Core already ordered them and limited each tier. */
function categorizeRankedHits(
  files: readonly FileItem[],
  hits: readonly RankedName[],
): CategorizedFiles {
  const openBuffers: FileItem[] = [];
  const recent: FileItem[] = [];
  const others: FileItem[] = [];
  for (const hit of hits) {
    const file = files[hit.index];
    if (!file) continue;
    if (hit.tier === "open") openBuffers.push(file);
    else if (hit.tier === "recent") recent.push(file);
    else others.push(file);
  }

  const openBufferFiles = openBuffers.slice(0, MAX_RESULTS);
  const recentFilesInResults = recent.slice(0, Math.max(0, MAX_RESULTS - openBufferFiles.length));
  const otherFiles = others.slice(
    0,
    Math.max(0, MAX_OTHER_FILES_SHOWN - openBufferFiles.length - recentFilesInResults.length),
  );

  return { openBufferFiles, recentFilesInResults, otherFiles };
}

const EMPTY_RESULT: CategorizedFiles = {
  openBufferFiles: [],
  recentFilesInResults: [],
  otherFiles: [],
};

/**
 * Quick Open file results. The empty query is a local switcher (open, recent, then name order);
 * a typed query is ranked by Core (`workspace.rankNames`) with open and recent files passed as
 * explicit context. Ranking is asynchronous: identical requests are issued once, a response for
 * an outdated query is dropped, and the previous list stays visible while the next one loads.
 */
export const useFileSearch = (
  files: FileItem[],
  debouncedQuery: string,
  options: FileSearchOptions = {},
) => {
  const bufferSearchSnapshot = useBufferStore((state) =>
    getOpenBufferSearchSnapshot(state.buffers, state.activeBufferId),
  );
  const getRecentFilesOrderedByFrecency = useRecentFilesStore(
    (state) => state.actions.getRecentFilesOrderedByFrecency,
  );
  const trimmedQuery = debouncedQuery.trim();

  const switcherAndContext = useMemo(() => {
    const { activeBufferPath, openBufferPaths, openBuffers } = bufferSearchSnapshot;
    const indexedFilePaths = new Set(files.map((file) => file.path));
    const recentFiles = filterQuickOpenRecentFiles(
      getRecentFilesOrderedByFrecency(),
      options.rootFolderPath,
      indexedFilePaths,
      options.hasLoadedFiles ?? false,
    );
    // An empty query is a switcher; a filename query must also find the active file.
    const matchingOpenBufferPaths = new Set(openBufferPaths);
    if (activeBufferPath) matchingOpenBufferPaths.add(activeBufferPath);

    const context = {
      openPaths: [...matchingOpenBufferPaths],
      recentPaths: recentFiles.map((file) => file.path),
    };

    // The empty-query switcher hides noise files; a typed query searches the full snapshot.
    const isSwitcherCandidate = (file: { path: string }) => !shouldIgnoreFile(file.path);
    const openBufferFiles = openBuffers.slice(0, MAX_OPEN_BUFFERS_SHOWN).map((file) => ({
      name: file.name,
      path: file.path,
      isDir: false,
    }));
    const openAndActivePaths = new Set(openBufferPaths);
    if (activeBufferPath) openAndActivePaths.add(activeBufferPath);

    const recentFilesInResults = recentFiles
      .filter((file) => !openAndActivePaths.has(file.path) && isSwitcherCandidate(file))
      .slice(
        0,
        Math.min(MAX_RECENT_FILES_NO_QUERY, Math.max(0, MAX_RESULTS - openBufferFiles.length)),
      )
      .map(recentFileToItem);

    const excludedPaths = new Set([
      ...openAndActivePaths,
      ...recentFilesInResults.map((file) => file.path),
    ]);
    const otherCandidates: FileItem[] = [];
    for (const file of files) {
      if (excludedPaths.has(file.path) || !isSwitcherCandidate(file)) continue;
      insertSortedLimited(
        otherCandidates,
        file,
        (a, b) => a.name.localeCompare(b.name),
        MAX_RESULTS,
      );
    }
    const otherFiles = otherCandidates.slice(
      0,
      Math.max(0, MAX_RESULTS - openBufferFiles.length - recentFilesInResults.length),
    );

    return { switcher: { openBufferFiles, recentFilesInResults, otherFiles }, context };
  }, [
    files,
    bufferSearchSnapshot,
    getRecentFilesOrderedByFrecency,
    options.hasLoadedFiles,
    options.rootFolderPath,
  ]);

  const [ranked, setRanked] = useState<CategorizedFiles>(EMPTY_RESULT);
  const issuedKeyRef = useRef<string | null>(null);
  const latestRequestRef = useRef(0);
  const filesIdentity = identityOf(files);

  useEffect(() => {
    if (!trimmedQuery) {
      // Invalidate in-flight work so a late answer cannot repaint a cleared query.
      issuedKeyRef.current = null;
      latestRequestRef.current += 1;
      return;
    }
    const key = JSON.stringify([trimmedQuery, filesIdentity, switcherAndContext.context]);
    if (issuedKeyRef.current === key) return;
    issuedKeyRef.current = key;
    const request = ++latestRequestRef.current;
    rankNames(
      trimmedQuery,
      files.map((file) => ({ name: file.name, path: file.path })),
      switcherAndContext.context,
      MAX_RESULTS,
    )
      .then((hits) => {
        if (request === latestRequestRef.current) setRanked(categorizeRankedHits(files, hits));
      })
      .catch((error) => {
        // Keep the previous list; the next query retries with a fresh key.
        if (request === latestRequestRef.current) issuedKeyRef.current = null;
        console.error("Quick Open ranking failed:", error);
      });
  }, [files, filesIdentity, switcherAndContext, trimmedQuery]);

  return trimmedQuery ? ranked : switcherAndContext.switcher;
};

const identities = new WeakMap<object, number>();
let nextIdentity = 0;

/** Stable small id per array instance, so request keys do not serialize the whole inventory. */
function identityOf(value: object): number {
  let id = identities.get(value);
  if (id === undefined) {
    id = ++nextIdentity;
    identities.set(value, id);
  }
  return id;
}
