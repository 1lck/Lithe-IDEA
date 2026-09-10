import { invoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";

export type GitIdentityScope = "local" | "global";
export type GitIdentityField = "name" | "email";
export interface GitRepositorySetup {
  isRepository: boolean;
  hasCommits: boolean;
  branch: string | null;
  scope: GitIdentityScope;
  configuredName: string | null;
  configuredEmail: string | null;
  effectiveName: string | null;
  effectiveEmail: string | null;
}

export function getGitRepositorySetup(root: string, scope: GitIdentityScope = "local") {
  // An uninitialized workspace must not pass through repository discovery first.
  return invoke<GitRepositorySetup>("git.repositorySetup", { root, scope });
}

export async function initializeGitRepository(root: string) {
  const result = await invoke<GitRepositorySetup>("git.initialize", { root, scope: "local" });
  emitGitChanged({
    repoPath: root,
    scopes: ["repository", "working-tree", "refs", "history"],
    source: "initialize-repository",
  });
  return result;
}

export async function configureGitIdentity(
  root: string,
  scope: GitIdentityScope,
  key: GitIdentityField,
  value: string | null,
) {
  const result = await invoke<GitRepositorySetup>("git.configureIdentity", {
    root,
    scope,
    key,
    value,
  });
  emitGitChanged({ repoPath: root, scopes: ["refs", "history"], source: "git-identity-settings" });
  return result;
}
