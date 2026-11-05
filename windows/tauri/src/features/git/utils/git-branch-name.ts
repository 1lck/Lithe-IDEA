import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitReference } from "../types/git.types";

/** Reference facts the preview validates against; the command never runs Git. */
export type BranchNameReference = Pick<GitReference, "kind" | "shortName">;

export type GitBranchNameError =
  | { code: "empty" }
  | { code: "head" }
  | { code: "clashesWithRemote"; name: string }
  | { code: "clashesWithDirectory"; name: string }
  | { code: "alreadyExists"; name: string }
  | { code: "clashesWithBranchPrefix"; name: string; branch: string };

export interface GitBranchNamePreview {
  /** Name shown while typing: invalid characters dropped, spaces replaced by `-`. */
  typingCleanedName: string;
  /** Name committed on apply: typing cleanup plus trailing dot, slash and `.lock`. */
  cleanedName: string;
  /** Suggested name for a branch created from `reference`. */
  initialName: string;
  error: GitBranchNameError | null;
}

const referenceFacts = ({ kind, shortName }: BranchNameReference) => ({ kind, shortName });

/**
 * Cleans and validates a new branch name with the shared Core implementation
 * (`git.branchNamePreview`). IDEA's `GitRefNameValidator` rules live in Core so
 * both platforms agree; this wrapper only marshals the repository references
 * the dialog already loaded.
 */
export function previewBranchName({
  rawName,
  requireName,
  references,
  reference,
}: {
  rawName: string;
  requireName: boolean;
  references: readonly BranchNameReference[];
  reference?: BranchNameReference | null;
}): Promise<GitBranchNamePreview> {
  return tauriInvoke<GitBranchNamePreview>("git.branchNamePreview", {
    rawName,
    requireName,
    references: references.map(referenceFacts),
    ...(reference ? { reference: referenceFacts(reference) } : {}),
  });
}
