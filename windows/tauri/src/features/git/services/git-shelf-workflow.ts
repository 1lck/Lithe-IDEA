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
export type ShelfPhase = "clean" | "restore";
export type ShelfLayer = "staged" | "working";
export interface ShelfDependencies {
  snapshot: () => Promise<ShelfSnapshot>;
  plan: (phase: ShelfPhase) => Promise<ShelfLayer[]>;
  step: (phase: ShelfPhase, layer: ShelfLayer, snapshot: ShelfSnapshot) => Promise<void>;
  save: (entry: GitShelf) => Promise<void>;
  remove: (id: string) => Promise<void>;
  guard: () => void;
  identity: () => string;
  now: () => number;
}

/** Storage and session lifetime stay native; Core owns the layer plan and safety checks. */
export function createShelfWorkflow(deps: ShelfDependencies) {
  const run = async (phase: ShelfPhase, snapshot: ShelfSnapshot) => {
    deps.guard();
    const layers = await deps.plan(phase);
    for (const layer of layers) {
      deps.guard();
      await deps.step(phase, layer, snapshot);
    }
    deps.guard();
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
      deps.guard();
      await deps.save(entry);
      await run("clean", snapshot);
      return entry;
    },
    async restore(entry: GitShelf) {
      await run("restore", entry);
      await deps.remove(entry.id);
    },
  };
}
