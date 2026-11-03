import { create } from "zustand";

interface GitLogRevealRequest {
  repoPath: string;
  commitHash: string;
}

interface GitLogRevealStore {
  /** Commit the next Git Log visit must select, or null when nothing is pending. */
  pending: GitLogRevealRequest | null;
  request: (repoPath: string, commitHash: string) => void;
  clear: () => void;
}

/**
 * Hands one commit from the editor to the Git Log tool window. The editor knows
 * which commit an annotated line belongs to but not where that commit sits in
 * the paginated log, so the log owns the loading and the selection.
 */
export const useGitLogRevealStore = create<GitLogRevealStore>((set) => ({
  pending: null,
  request: (repoPath, commitHash) => set({ pending: { repoPath, commitHash } }),
  clear: () => set({ pending: null }),
}));
