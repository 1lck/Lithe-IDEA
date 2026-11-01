import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import { getPathIdentity } from "@/utils/path-helpers";

// Editor hooks own mounted copies. Runtime reconciliation owns only dormant buffers.
const owners = new WeakMap<WorkspaceRuntime, Map<string, number>>();

export function registerMountedLspDocument(runtime: WorkspaceRuntime, path: string): () => void {
  const documents = owners.get(runtime) ?? new Map<string, number>();
  owners.set(runtime, documents);
  const key = getPathIdentity(path);
  documents.set(key, (documents.get(key) ?? 0) + 1);
  let active = true;
  return () => {
    if (!active) return;
    active = false;
    const remaining = (documents.get(key) ?? 1) - 1;
    if (remaining) documents.set(key, remaining); else documents.delete(key);
  };
}

export function hasMountedLspDocument(runtime: WorkspaceRuntime, path: string): boolean {
  return (owners.get(runtime)?.get(getPathIdentity(path)) ?? 0) > 0;
}
