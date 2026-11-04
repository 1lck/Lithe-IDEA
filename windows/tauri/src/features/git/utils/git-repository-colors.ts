import { useEffect, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { normalizeRepositoryPath } from "../api/git-repo-api";

/** Eight platform presentation colors; Core owns assignment and fallback slots. */
export const GIT_REPOSITORY_COLOR_PALETTE: readonly string[] = [
  "#55d68b", "#65a9ff", "#d77eea", "#f3aa59",
  "#e76c72", "#56c7cf", "#b08cff", "#ffd166",
];

const PAGE_SIZE = 128;
const EMPTY_ROOTS: readonly string[] = [];
type Page = {
  assignments: { id: string; slot: number }[];
  fallbackSlot: number;
  showColors: boolean;
};
type RequestPage = (request: {
  offset: number; totalCount: number; repositoryIds: string[];
}) => Promise<Page>;
export type RepositoryColors = { colors: Map<string, string>; fallback: string; showColors: boolean };

/** Load ordered, unique repository identities in bounded pages outside row rendering. */
export async function loadRepositoryColors(
  roots: readonly string[],
  requestPage: RequestPage = (request) => invoke<Page>("git.repositoryColorAssignments", request),
  isCurrent: () => boolean = () => true,
): Promise<RepositoryColors | null> {
  const colors = new Map<string, string>();
  let first: Page | undefined;
  for (let offset = 0; offset < roots.length || (offset === 0 && roots.length === 0); offset += PAGE_SIZE) {
    if (!isCurrent()) return null;
    const repositoryIds = roots.slice(offset, offset + PAGE_SIZE).map(normalizeRepositoryPath);
    const page = await requestPage({ offset, totalCount: roots.length, repositoryIds });
    if (!isCurrent()) return null;
    if (page.assignments.length !== repositoryIds.length ||
        page.assignments.some((item, index) => item.id !== repositoryIds[index] ||
          !Number.isInteger(item.slot) || !GIT_REPOSITORY_COLOR_PALETTE[item.slot]) ||
        !GIT_REPOSITORY_COLOR_PALETTE[page.fallbackSlot] ||
        (first && (page.fallbackSlot !== first.fallbackSlot || page.showColors !== first.showColors))) {
      throw new Error("Invalid Core repository color page");
    }
    first ??= page;
    for (const { id, slot } of page.assignments) colors.set(id, GIT_REPOSITORY_COLOR_PALETTE[slot]);
    if (roots.length === 0) break;
  }
  if (!first) return null;
  return { colors, fallback: GIT_REPOSITORY_COLOR_PALETTE[first.fallbackSlot], showColors: first.showColors };
}

/** Discard late results when the ordered full root list changes or the view unmounts. */
export function useRepositoryColors(repositoryPaths?: readonly string[]): RepositoryColors | null {
  const roots = repositoryPaths ?? EMPTY_ROOTS;
  const [snapshot, setSnapshot] = useState<{ roots: readonly string[]; colors: RepositoryColors } | null>(null);
  useEffect(() => {
    let current = true;
    void loadRepositoryColors(roots, undefined, () => current)
      .then((result) => { if (current && result) setSnapshot({ roots, colors: result }); })
      .catch((error) => { if (current) console.error("Failed to resolve repository colors:", error); });
    return () => { current = false; };
  }, [roots]);
  return snapshot?.roots === roots ? snapshot.colors : null;
}
