import { useEffect, useMemo, useSyncExternalStore } from "react";
import { useActiveWorkspaceId, useWorkspaceReady } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { windowsBuildWorkspaces } from "@/platform/build-workspaces";
import type { BuildWorkspaceSnapshot } from "../services/build-workspace-controller";

const empty: BuildWorkspaceSnapshot = { status: "idle", entries: [], manifests: {}, modelRevision: 0 };
const subscribeToNothing = () => () => {};
const emptySnapshot = () => empty;

/** A pane subscribes to catalog/model changes only. Output has its own leaf
 * subscription and cannot repaint the workbench for every progress chunk. */
export function useBuildWorkspace() {
  const workspaceID = useActiveWorkspaceId(), ready = useWorkspaceReady(workspaceID);
  const pathSnapshot = useMemo(() => () => workspaceRuntimeRegistry.getWorkspace(workspaceID)?.descriptor.path, [workspaceID]);
  const path = useSyncExternalStore(workspaceRuntimeRegistry.subscribe, pathSnapshot, pathSnapshot);
  const controller = useMemo(() => ready && path ? windowsBuildWorkspaces.get(workspaceID, path) : undefined, [workspaceID, path, ready]);
  const snapshot = useSyncExternalStore(controller?.subscribe ?? subscribeToNothing, controller?.snapshot ?? emptySnapshot, controller?.snapshot ?? emptySnapshot);
  useEffect(() => {
    if (controller?.snapshot().status === "idle") void controller.refresh();
  }, [controller]);
  return { controller, snapshot };
}
