export type GitPatchSource = "workingTree" | "staged" | "unstaged" | "commits";
export type GitPatchTarget = "worktree" | "indexAndWorktree";

export interface GitPatchFile {
  path: string;
  originalPath: string | null;
  additions: number | null;
  deletions: number | null;
}

export interface GitPatchExport {
  patch: string;
  files: GitPatchFile[];
  byteLength: number;
}

export interface GitPatchPreview {
  applicable: boolean;
  files: GitPatchFile[];
  diagnostic: string;
  expectedState: string | null;
  byteLength: number;
}

export { GIT_PATCH_MAX_BYTES } from "@/config/git-limits";
