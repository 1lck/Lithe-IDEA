import { invoke } from "@/platform/tauri-core";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { pathStartsWithRoot } from "@/utils/path-helpers";
import { emitGitChanged } from "../events/git-events";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";
import { createShelfWorkflow, type GitShelf, type ShelfLayer, type ShelfPhase, type ShelfSnapshot } from "../services/git-shelf-workflow";

export const listShelves = (root: string) =>
  invoke<GitShelf[]>("saved_changes_storage", { root, operation: "list" });
export const deleteShelf = (root: string, id: string) =>
  invoke<void>("saved_changes_storage", { root, operation: "delete", id });

export function assertSavedFiles(root: string) {
  if (
    useBufferStore
      .getState()
      .buffers.some(
        (buffer) =>
          buffer.type === "editor" && buffer.isDirty && pathStartsWithRoot(buffer.path, root),
      )
  )
    throw new Error("git.saved.unsaved");
}

function workflow(root: string, guardCurrent: () => void) {
  const guard = () => {
    guardCurrent();
    assertSavedFiles(root);
  };
  const callShelf = async <T>(args: Record<string, unknown>): Promise<T> => {
    guard();
    const resolved = await resolveRepositoryPathOrThrow(root);
    guard();
    try {
      return await invoke<T>("git.shelf", { root: resolved, ...args });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("SHELF_CHANGED")) throw new Error("git.saved.changed");
      if (message.includes("SHELF_CONFLICTS")) throw new Error("git.saved.conflicts");
      throw error;
    }
  };
  return createShelfWorkflow({
    guard,
    identity: () => crypto.randomUUID(),
    now: () => Date.now(),
    snapshot: () => callShelf<ShelfSnapshot>({ action: "capture" }),
    plan: async (phase) => (await callShelf<{ layers: ShelfLayer[] }>({ action: "plan", phase })).layers,
    step: async (phase: ShelfPhase, layer: ShelfLayer, snapshot: ShelfSnapshot) => {
      try {
        await callShelf({ action: phase, layer, snapshot });
      } finally {
        emitGitChanged({ repoPath: root, scopes: ["working-tree"], source: "apply-patch" });
      }
    },
    save: (entry) => invoke<void>("saved_changes_storage", { root, operation: "save", entry }),
    remove: (id) => deleteShelf(root, id),
  });
}
export const shelveChanges = (root: string, message: string, guardCurrent: () => void) =>
  workflow(root, guardCurrent).capture(message);
export const restoreShelf = (root: string, shelf: GitShelf, guardCurrent: () => void) =>
  workflow(root, guardCurrent).restore(shelf);

/** Core parses the complete patch once and preserves file identities and hunks. */
export async function inspectShelfDiffs(root: string, patch: string, isCurrent: () => boolean) {
  if (!isCurrent() || !patch) return [];
  const diffs = await invoke<import("../types/git.types").GitDiff[]>("git.parsePatch", { root, patch });
  return isCurrent() ? diffs : [];
}
