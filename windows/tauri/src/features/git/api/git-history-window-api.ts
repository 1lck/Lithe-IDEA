import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitCommit } from "../types/git.types";

// Note: shared/fixtures/git/history-window-v1.json defines every rule below.

const plan = <T>(request: Record<string, unknown>) =>
  tauriInvoke<T>("git.historyWindow", request);

const hashes = (commits: readonly Pick<GitCommit, "hash">[]) => commits.map((commit) => commit.hash);

/**
 * Size of the first page a refresh reads (`git.historyWindow` refreshPlan).
 * A refresh that keeps the loaded depth reads at least as many commits as the
 * window holds, so a deep history never shrinks back to the first page.
 */
export async function planGitHistoryRefreshLimit(
  loadedCount: number,
  pageSize: number,
  preserveLoaded: boolean,
): Promise<number> {
  const result = await plan<{ limit: number }>({
    operation: "refreshPlan",
    loadedCount,
    pageSize,
    preserveLoaded,
  });
  return result.limit;
}

/**
 * Commits to read after the refreshed first page so the previous window's tail
 * stays loaded when new commits appeared at the head; `0` keeps the page.
 */
export async function planGitHistoryExtension(
  previous: readonly Pick<GitCommit, "hash">[],
  page: readonly Pick<GitCommit, "hash">[],
  canContinue: boolean,
): Promise<number> {
  if (previous.length === 0 || !canContinue) return 0;
  const result = await plan<{ extensionLimit: number }>({
    operation: "extendPlan",
    previous: hashes(previous),
    page: hashes(page),
    canContinue,
  });
  return result.extensionLimit;
}

/** Appends a page to a window without repeating commits and bounds its size. */
export async function mergeGitHistoryPage(
  window: readonly GitCommit[],
  page: readonly GitCommit[],
  pageHasMore: boolean,
): Promise<{ commits: GitCommit[]; appended: number; hasMore: boolean }> {
  const result = await plan<{ append: number[]; hasMore: boolean }>({
    operation: "mergePage",
    window: hashes(window),
    page: hashes(page),
    pageHasMore,
  });
  const appended = result.append.map((index) => {
    const commit = page[index];
    if (!commit) throw new Error("Invalid Git history window plan");
    return commit;
  });
  return {
    commits: [...window, ...appended],
    appended: appended.length,
    hasMore: result.hasMore,
  };
}

export interface GitHistorySelectionState {
  selected: string[];
  focused: string | null;
  anchor: string | null;
}

/**
 * Keeps the selected commits, focus, and range anchor that are still loaded
 * after the window changed; falls back to the first loaded commit.
 */
export function reconcileGitHistorySelection(
  window: readonly Pick<GitCommit, "hash">[],
  state: GitHistorySelectionState,
): Promise<GitHistorySelectionState> {
  return plan<GitHistorySelectionState>({
    operation: "reconcileSelection",
    window: hashes(window),
    selected: state.selected,
    focused: state.focused,
    anchor: state.anchor,
  });
}
