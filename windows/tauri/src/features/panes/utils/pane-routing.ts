import type { PaneGroup, PaneNode } from "../types/pane.types";
import { getAllPaneGroups } from "./pane-tree";

export interface WritablePaneRoutingInput {
  activePane: PaneGroup | null;
  bufferId?: string;
  bottomRoot: PaneNode;
  mostRecentActivePaneIds: string[];
  root: PaneNode;
}

export interface MainPaneRoutingInput {
  activePaneId: string;
  mostRecentActivePaneIds: string[];
  root: PaneNode;
}

export interface MainPaneBufferRoutingInput extends MainPaneRoutingInput {
  bufferId: string;
}

export function resolveMainPaneForExternalOpen({
  activePaneId,
  mostRecentActivePaneIds,
  root,
}: MainPaneRoutingInput): PaneGroup | null {
  const mainPanes = getAllPaneGroups(root);
  const paneById = new Map(mainPanes.map((pane) => [pane.id, pane] as const));

  return (
    paneById.get(activePaneId) ??
    mostRecentActivePaneIds.map((paneId) => paneById.get(paneId)).find(Boolean) ??
    mainPanes[0] ??
    null
  );
}

export function resolveMainPaneForBufferOpen({
  activePaneId,
  bufferId,
  mostRecentActivePaneIds,
  root,
}: MainPaneBufferRoutingInput): PaneGroup | null {
  const mainPanes = getAllPaneGroups(root);
  const paneWithBuffer = mainPanes.find((pane) => pane.bufferIds.includes(bufferId));
  if (paneWithBuffer) return paneWithBuffer;

  return resolveMainPaneForExternalOpen({ activePaneId, mostRecentActivePaneIds, root });
}

export function getPaneScopeForPaneId(root: PaneNode, bottomRoot: PaneNode, paneId: string) {
  const rootPanes = getAllPaneGroups(root);
  if (rootPanes.some((pane) => pane.id === paneId)) {
    return rootPanes;
  }

  return getAllPaneGroups(bottomRoot);
}

export function resolveWritablePaneForBuffer({
  activePane,
  bufferId,
  bottomRoot,
  mostRecentActivePaneIds,
  root,
}: WritablePaneRoutingInput): PaneGroup | null {
  if (!activePane) return null;

  if ((bufferId && activePane.bufferIds.includes(bufferId)) || !activePane.locked) {
    return activePane;
  }

  const paneScope = getPaneScopeForPaneId(root, bottomRoot, activePane.id);
  const paneById = new Map(paneScope.map((pane) => [pane.id, pane] as const));
  return (
    mostRecentActivePaneIds
      .map((paneId) => paneById.get(paneId))
      .find((pane) => pane && pane.id !== activePane.id && !pane.locked) ??
    [...paneById.values()].find((pane) => pane.id !== activePane.id && !pane.locked) ??
    null
  );
}
