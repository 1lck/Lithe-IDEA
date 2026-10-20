import type { GitPatchTarget } from "../types/git-patch.types";

export interface ShelfSnapshot {
  stagedPatch: string;
  workingPatch: string;
  paths: string[];
}
export interface GitShelf extends ShelfSnapshot {
  version: 1;
  id: string;
  message: string;
  createdAt: number;
}
export interface ShelfDependencies {
  snapshot: () => Promise<ShelfSnapshot>;
  save: (entry: GitShelf) => Promise<void>;
  remove: (id: string) => Promise<void>;
  apply: (patch: string, target: GitPatchTarget, reverse: boolean) => Promise<void>;
  isApplied: (patch: string, target: GitPatchTarget) => Promise<boolean>;
  guard: () => void;
  identity: () => string;
  now: () => number;
}

/** Capture durably before cleaning; partial failures retain the complete recovery record. */
export function createShelfWorkflow(deps: ShelfDependencies) {
  const same = (left: ShelfSnapshot, right: ShelfSnapshot) =>
    left.stagedPatch === right.stagedPatch && left.workingPatch === right.workingPatch;
  const restorePatch = async (patch: string, target: GitPatchTarget) => {
    deps.guard();
    try {
      await deps.apply(patch, target, false);
    } catch (failure) {
      deps.guard();
      // A previous attempt may have completed this layer before failing on the next one.
      const alreadyApplied = await deps.isApplied(patch, target);
      deps.guard();
      if (!alreadyApplied) throw failure;
    }
  };
  return {
    async capture(message: string): Promise<GitShelf> {
      deps.guard();
      const snapshot = await deps.snapshot();
      if (!snapshot.stagedPatch && !snapshot.workingPatch) throw new Error("git.saved.noChanges");
      const entry: GitShelf = {
        ...snapshot,
        version: 1,
        id: deps.identity(),
        message: message.trim() || "WIP",
        createdAt: deps.now(),
      };
      await deps.save(entry);
      deps.guard();
      if (!same(snapshot, await deps.snapshot())) throw new Error("git.saved.changed");
      deps.guard();
      if (entry.workingPatch) await deps.apply(entry.workingPatch, "worktree", true);
      if (entry.stagedPatch) {
        deps.guard();
        if ((await deps.snapshot()).stagedPatch !== entry.stagedPatch)
          throw new Error("git.saved.changed");
        await deps.apply(entry.stagedPatch, "indexAndWorktree", true);
      }
      return entry;
    },
    async restore(entry: GitShelf) {
      deps.guard();
      if (entry.stagedPatch) await restorePatch(entry.stagedPatch, "indexAndWorktree");
      deps.guard();
      if (entry.workingPatch) await restorePatch(entry.workingPatch, "worktree");
      deps.guard();
      await deps.remove(entry.id);
    },
  };
}
