import type { VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";
export type VcsWriteAction =
  | { operation: "checkin"; paths: string[]; message: string }
  | { operation: "rollback"; paths: string[] }
  | { operation: "update" }
  | { operation: "resolve"; paths: string[] }
  | { operation: "add" | "delete"; paths: string[] }
  | { operation: "cleanup" };
export interface VcsWriteSnapshot {
  requestId: string;
  generation: number;
  rootId: string;
  vcs: string;
  operation: VcsWriteAction["operation"];
  result: { revision?: { display: string } | null; conflicts?: string[] };
}
export interface VcsReview {
  status: VcsStatusSnapshot;
  statusId: string;
  rootPath: string;
  paths: string[];
  action: VcsWriteAction;
}
export function isConflict(change: VcsStatusSnapshot["result"]["changes"][number]): boolean {
  return change.status === "conflicted" || change.flags.includes("treeConflict");
}
/** Selection eligibility only; the native preflight must prove file type,
 * canonical spelling, every endpoint's Core owner and current package scope. */
export function permitsFileOperation(
  change: VcsStatusSnapshot["result"]["changes"][number],
  operation: "add" | "delete",
): boolean {
  if (change.flags.some((flag) => ["external", "submodule", "treeConflict"].includes(flag)))
    return false;
  return operation === "add"
    ? change.status === "unversioned" && !change.oldPath && !change.path.includes("/")
    : ["modified", "added", "renamed", "copied", "replaced", "typeChanged", "switched"].includes(
        change.status,
      );
}
/** v1 root-wide writes cannot express a narrower workspace or exclude nested roots. */
export function permitsWholeCopy(source: VcsSnapshot | null, rootId: string): boolean {
  return (
    !!source &&
    !source.detection.truncated &&
    rootId === "" &&
    source.detection.roots.length === 1 &&
    source.detection.roots[0]?.id === "" &&
    source.detection.ambiguous.length === 0
  );
}
/** Both endpoints of a move are visible in confirmation and sent by native
 * code. The UI only submits current row IDs from this exact status receipt. */
export function reviewPaths(status: VcsStatusSnapshot, action: VcsWriteAction): string[] {
  const capability =
    action.operation === "resolve"
      ? "conflicts"
      : action.operation === "add" || action.operation === "delete"
        ? "fileOperations"
        : action.operation;
  if (status.result.truncated || status.capabilities?.[capability] !== 1)
    throw new Error("vcs.capability.unsupported");
  if (action.operation === "update" || action.operation === "cleanup") return [];
  if (
    !action.paths.length ||
    action.paths.length > 10000 ||
    (action.operation === "checkin" &&
      (!action.message.trim() || new TextEncoder().encode(action.message).length > 1048576))
  )
    throw new Error("invalidRequest");
  const changes = new Map(status.result.changes.map((change) => [change.path, change]));
  const paths = [
    ...new Set(
      action.paths.flatMap((path) => {
        const change = changes.get(path);
        if (
          !change ||
          change.status === "ignored" ||
          ((action.operation === "add" || action.operation === "delete") &&
            !permitsFileOperation(change, action.operation)) ||
          (action.operation === "resolve" && !isConflict(change)) ||
          (action.operation === "rollback" && change.status === "unversioned")
        )
          throw new Error("invalidRequest");
        return change.oldPath && action.operation !== "resolve"
          ? [change.oldPath, change.path]
          : [change.path];
      }),
    ),
  ].sort();
  if (["checkin", "resolve", "delete"].includes(action.operation)) {
    for (const path of paths) {
      const endpoint = changes.get(path);
      if (action.operation === "delete" && endpoint && !permitsFileOperation(endpoint, "delete"))
        throw new Error("vcs.provider.pathUnavailable");
      let end = path.lastIndexOf("/");
      while (end >= 0) {
        const parent = path.slice(0, end);
        const ancestor = changes.get(parent);
        if (
          ["added", "replaced", "renamed", "copied"].includes(ancestor?.status ?? "") ||
          (action.operation === "delete" &&
            !!ancestor &&
            (["unversioned", "ignored"].includes(ancestor.status) ||
              ancestor.flags.some((flag) =>
                ["external", "submodule", "treeConflict"].includes(flag),
              )))
        )
          throw new Error("vcs.provider.pathUnavailable");
        end = parent.lastIndexOf("/");
      }
    }
  }
  return paths;
}
