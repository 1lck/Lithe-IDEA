import type { GitLogFilterScope } from "../stores/git-log-preferences.store";
import type { GitCommit } from "../types/git.types";

export function matchesGitLogCommit(
  commit: GitCommit,
  query: string,
  scope: GitLogFilterScope,
): boolean {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  if (!normalizedQuery) return true;

  const fields =
    scope === "author"
      ? [commit.author, commit.email ?? ""]
      : scope === "branch"
        ? [commit.decorations]
        : [commit.message, commit.description ?? "", commit.hash, commit.shortHash];
  return fields.some((field) => field.toLocaleLowerCase().includes(normalizedQuery));
}
