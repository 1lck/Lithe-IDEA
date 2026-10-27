import type { VcsStatusSnapshot } from "./vcs-root-types";
export type VcsWriteAction =
  | { operation: "checkin"; paths: string[]; message: string }
  | { operation: "rollback"; paths: string[] }
  | { operation: "update" };
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
  rootPath: string;
  paths: string[];
  action: VcsWriteAction;
}
/** Both endpoints of a move are visible in confirmation and sent by native
 * code. The UI only submits current row IDs from this exact status receipt. */
export function reviewPaths(status: VcsStatusSnapshot, action: VcsWriteAction): string[] {
  if (status.result.truncated || status.capabilities?.[action.operation] !== 1)
    throw new Error("vcs.capability.unsupported");
  if (action.operation === "update") return [];
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
          (action.operation === "rollback" && change.status === "unversioned")
        )
          throw new Error("invalidRequest");
        return change.oldPath ? [change.oldPath, change.path] : [change.path];
      }),
    ),
  ].sort();
  if (action.operation === "checkin") {
    for (const path of paths) {
      let end = path.lastIndexOf("/");
      while (end >= 0) {
        const parent = path.slice(0, end);
        if (["added", "replaced", "renamed", "copied"].includes(changes.get(parent)?.status ?? ""))
          throw new Error("vcs.provider.pathUnavailable");
        end = parent.lastIndexOf("/");
      }
    }
  }
  return paths;
}
