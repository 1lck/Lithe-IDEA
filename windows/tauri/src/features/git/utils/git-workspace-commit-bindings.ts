import { normalizePath } from "@/utils/path-helpers";
import type { WorkspaceRepositoryBinding } from "../types/git-workspace-commit.types";

/** Bind native roots to portable workspace IDs, including enclosing repositories. */
export function workspaceCommitBindings(
  workspace: string,
  roots: readonly string[],
): WorkspaceRepositoryBinding[] {
  const base = normalizePath(workspace).replace(/\/+$/, "").split("/");
  return [...new Set(roots)].map((root) => {
    const parts = normalizePath(root).replace(/\/+$/, "").split("/");
    let common = 0;
    while (
      common < base.length &&
      common < parts.length &&
      base[common]!.toLowerCase() === parts[common]!.toLowerCase()
    )
      common++;
    // Manually selected repositories on another volume have a virtual workspace ID.
    const id =
      common === 0
        ? `external/${parts.map((part) => encodeURIComponent(part)).join("/")}`
        : [...base.slice(common).map(() => ".."), ...parts.slice(common)].join("/") || ".";
    return { id, root };
  });
}
