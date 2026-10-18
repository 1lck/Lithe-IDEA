import { invoke } from "@/platform/tauri-core";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { pathStartsWithRoot } from "@/utils/path-helpers";
import { applyGitPatch, exportGitPatch, isGitPatchApplied, previewGitPatch } from "./git-patch-api";
import { getGitStatus } from "./git-status-api";
import { createShelfWorkflow, type GitShelf } from "../services/git-shelf-workflow";

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
  return createShelfWorkflow({
    guard,
    identity: () => crypto.randomUUID(),
    now: () => Date.now(),
    snapshot: async () => {
      const status = await getGitStatus(root);
      if (!status) throw new Error("git.saved.failed");
      if (
        status.files.some(
          (file) =>
            file.rawStatus?.includes("U") || file.rawStatus === "AA" || file.rawStatus === "DD",
        )
      )
        throw new Error("git.saved.conflicts");
      const staged = await exportGitPatch(root, "staged", []);
      const working = await exportGitPatch(root, "unstaged", [], { includeUntracked: true });
      return {
        stagedPatch: staged.patch,
        workingPatch: working.patch,
        paths: [
          ...new Set(
            [...staged.files, ...working.files].flatMap((file) => [
              file.path,
              ...(file.originalPath ? [file.originalPath] : []),
            ]),
          ),
        ].sort(),
      };
    },
    save: (entry) => invoke<void>("saved_changes_storage", { root, operation: "save", entry }),
    remove: (id) => deleteShelf(root, id),
    isApplied: async (patch, target) => {
      guard();
      return isGitPatchApplied(root, patch, target);
    },
    apply: async (patch, target, reverse) => {
      guard();
      const preview = await previewGitPatch(root, patch, target, crypto.randomUUID(), reverse);
      if (!preview.applicable || !preview.expectedState)
        throw new Error(preview.diagnostic || "git.saved.changed");
      guard();
      await applyGitPatch(root, patch, target, preview.expectedState, reverse);
    },
  });
}
export const shelveChanges = (root: string, message: string, guardCurrent: () => void) =>
  workflow(root, guardCurrent).capture(message);
export const restoreShelf = (root: string, shelf: GitShelf, guardCurrent: () => void) =>
  workflow(root, guardCurrent).restore(shelf);

/** Core owns filenames; the existing parser supplies display-only line rows. */
export async function inspectShelfDiffs(root: string, patch: string, isCurrent: () => boolean) {
  const { parseRawDiffContent } = await import("../utils/git-diff-parser");
  const diffs: import("../types/git.types").GitDiff[] = [];
  for (const section of patch.split(/(?=^diff --git )/m).filter((value) => value.trim())) {
    if (!isCurrent()) return [];
    const preview = await previewGitPatch(
      root,
      section,
      "worktree",
      crypto.randomUUID(),
      false,
      true,
    );
    if (!isCurrent()) return [];
    const parsed = parseRawDiffContent(section, "shelf.patch");
    const diff = "files" in parsed ? parsed.files[0] : parsed;
    const file = preview.files[0];
    if (diff && file)
      diffs.push({
        ...diff,
        file_path: file.path,
        old_path: file.originalPath ?? (diff.is_new ? undefined : file.path),
        new_path: diff.is_deleted ? undefined : file.path,
        is_renamed: Boolean(file.originalPath),
        additions: file.additions ?? undefined,
        deletions: file.deletions ?? undefined,
      });
  }
  return diffs;
}
