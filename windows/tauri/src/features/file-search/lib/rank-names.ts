import { invoke } from "@/platform/tauri-core";

/** One name to rank; `path` identifies it in the context lists and is a weaker match target. */
export interface RankNameCandidate {
  name: string;
  path?: string;
}

/** Explicit ranking context; Core never reads editor or history state itself. */
export interface RankNamesContext {
  openPaths?: readonly string[];
  /** Recently visited paths, most recent first. */
  recentPaths?: readonly string[];
}

export type RankTier = "open" | "recent" | "other";

export interface RankedName {
  /** Index into the candidates sent with the request. */
  index: number;
  degree: number;
  tier: RankTier;
  /** UTF-16 ranges in the candidate name; empty when only the path matched. */
  nameMatchRanges: Array<{ start: number; length: number }>;
}

/**
 * Scores host-listed names with Rust Core (`workspace.rankNames`), the matcher behind
 * Search Everywhere. Windows lists remote and WSL roots itself, so it sends the names
 * and the context and only applies the returned order; it never scores names locally.
 */
export async function rankNames(
  query: string,
  candidates: readonly RankNameCandidate[],
  context: RankNamesContext = {},
  limitPerTier?: number,
): Promise<RankedName[]> {
  if (!query.trim() || candidates.length === 0) return [];
  const { matches } = await invoke<{ matches: RankedName[] }>("workspace.rankNames", {
    query,
    candidates,
    context: { openPaths: context.openPaths ?? [], recentPaths: context.recentPaths ?? [] },
    ...(limitPerTier === undefined ? {} : { limitPerTier }),
  });
  return matches;
}
