import type { GitReference } from "../types/git.types";

/**
 * Mirrors IDEA's `GitRefNameValidator` (git4idea) so the new-branch dialog cleans and
 * validates names the same way while typing. The replacement symbol matches the
 * `git.branch.cleanup.symbol` advanced-setting default.
 */
const CLEANUP_SYMBOL = "-";

const DROP_PATTERN = new RegExp(
  [
    "(^\\.)", // begins with a dot
    "(^-)", // begins with '-'
    "(^/)", // begins with '/'
    '[~:^?*"\\[\\\\]+|(@\\{)+', // invalid character or "@{" sequence
    "/(?=/)", // double slash
    "(\\.(?=\\.))+", // two dots in a row
    "\\.(?=/)", // dot before a slash
    "(?<=/)\\.", // dot after a slash
  ].join("|"),
  "g",
);
// Spaces and ASCII control characters (0-31 and DEL).
// eslint-disable-next-line no-control-regex
const REPLACE_PATTERN = / +|[\u0000-\u001f\u007f]/g;
const END_PATTERN = /(?:[./]|\.lock)$/;

/** Typing-time cleanup: drops invalid characters and turns spaces into the cleanup symbol. */
export function cleanBranchNameOnTyping(name: string): string {
  return name.replace(DROP_PATTERN, "").replace(REPLACE_PATTERN, CLEANUP_SYMBOL);
}

/** Submit-time cleanup: typing cleanup plus removal of a trailing dot, slash or ".lock". */
export function cleanBranchName(name: string): string {
  return cleanBranchNameOnTyping(name).replace(END_PATTERN, "");
}

/** IDEA's `calculateNewBranchInitialName`: local keeps its name, remote drops the remote prefix. */
export function initialBranchName(reference: Pick<GitReference, "kind" | "shortName">): string {
  if (reference.kind !== "remote") return reference.shortName;
  const separator = reference.shortName.indexOf("/");
  return separator < 0 ? reference.shortName : reference.shortName.slice(separator + 1);
}

export type GitBranchNameError =
  | { code: "empty" }
  | { code: "head" }
  | { code: "clashesWithRemote"; name: string }
  | { code: "clashesWithDirectory"; name: string }
  | { code: "alreadyExists"; name: string };

function collectDirectories(branchNames: Iterable<string>): Set<string> {
  const directories = new Set<string>();
  for (const branchName of branchNames) {
    let index = branchName.indexOf("/");
    while (index !== -1) {
      directories.add(branchName.slice(0, index));
      index = branchName.indexOf("/", index + 1);
    }
  }
  return directories;
}

/**
 * Validates an already cleaned name against the repository references, in IDEA's order:
 * empty/HEAD, remote branch clash, local branch directory clash, existing local branch.
 * `empty` is only reported when `requireName` is set, as IDEA validates it on apply.
 */
export function validateNewBranchName(
  name: string,
  references: readonly Pick<GitReference, "kind" | "shortName">[],
  requireName: boolean,
): GitBranchNameError | null {
  if (!name.trim()) return requireName ? { code: "empty" } : null;
  if (name.toLowerCase() === "head") return { code: "head" };
  const localNames = references.filter((ref) => ref.kind === "local").map((ref) => ref.shortName);
  if (references.some((ref) => ref.kind === "remote" && ref.shortName === name)) {
    return { code: "clashesWithRemote", name };
  }
  if (collectDirectories(localNames).has(name)) return { code: "clashesWithDirectory", name };
  if (localNames.includes(name)) return { code: "alreadyExists", name };
  return null;
}
