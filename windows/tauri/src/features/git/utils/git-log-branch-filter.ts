import type { GitReference } from "../types/git.types";
import { naturalCompare } from "./git-graph-layout";
import { isRemoteSymbolicReference } from "./git-log-refresh";

export interface GitLogBranchFilterGroup {
  /** Stable section id: `local` or `remote:<name>`. */
  id: string;
  /** Remote name for a remote group; the other groups are labelled by their kind. */
  remoteName?: string;
  references: GitReference[];
}

const byShortName = (left: GitReference, right: GitReference) =>
  naturalCompare(left.shortName, right.shortName);

/**
 * Splits references into the Branch filter groups: Local, then one group per remote
 * (`origin/…`). Tags are not branches and are left out, as are empty groups and remote
 * symbolic `HEAD` pointers.
 */
export function groupGitLogBranchFilterReferences(
  references: readonly GitReference[],
): GitLogBranchFilterGroup[] {
  const groups: GitLogBranchFilterGroup[] = [];

  const locals = references.filter((reference) => reference.kind === "local");
  if (locals.length > 0) groups.push({ id: "local", references: locals.sort(byShortName) });

  const remotes = new Map<string, GitReference[]>();
  for (const reference of references) {
    if (reference.kind !== "remote" || isRemoteSymbolicReference(reference)) continue;
    const remoteName = reference.shortName.split("/")[0] || reference.shortName;
    remotes.set(remoteName, [...(remotes.get(remoteName) ?? []), reference]);
  }
  for (const remoteName of [...remotes.keys()].sort(naturalCompare)) {
    groups.push({
      id: `remote:${remoteName}`,
      remoteName,
      references: remotes.get(remoteName)!.sort(byShortName),
    });
  }

  return groups;
}
