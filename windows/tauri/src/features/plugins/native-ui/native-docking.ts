import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useUIState, type UIState } from "@/features/window/stores/ui-state.store";
import type { NativeContribution } from "./native-ui.types";
import type { DeclarativeWebToolWindow } from "../declarative-plugin-launch";

export type NativePlacement = "left" | "bottom" | "right";
export type DockableContribution = NativeContribution | DeclarativeWebToolWindow;
export type NativeViewId = `plugin-native:${string}` | `plugin-web:${string}`;
export const nativeViewId = (entry: DockableContribution): NativeViewId =>
  `${"entry" in entry ? "plugin-web" : "plugin-native"}:${encodeURIComponent(entry.pluginId)}/${encodeURIComponent(entry.windowId)}`;
export const isPluginToolWindow = (view: string) =>
  view.startsWith("plugin-native:") || view.startsWith("plugin-web:");

// Workspace/window-local preferences survive hidden or temporarily absent entries.
// No layout draft, request or state is written to an installed plugin package.
export const useNativeDocking = createWorkspaceScopedStore("native-plugin-docking", () =>
  createStore<{ placements: Record<string, NativePlacement> }>(() => ({
    placements: {},
  })),
);

export function nativePlacement(
  entry: DockableContribution,
  placements: Record<string, NativePlacement>,
) {
  const placement = placements[nativeViewId(entry)] ?? entry.placement;
  if (placement !== "left" && placement !== "bottom" && placement !== "right")
    throw new Error("pluginNative.placementUnavailable");
  return placement;
}

export function nativeSlot(state: UIState, placement: NativePlacement) {
  if (placement === "left")
    return { view: state.activeSidebarView, visible: state.isSidebarVisible };
  if (placement === "bottom")
    return {
      view: state.bottomPaneActiveTab,
      visible: state.isBottomPaneVisible,
    };
  return {
    view: state.activeRightSidebarView,
    visible: state.isRightSidebarVisible,
  };
}

function selectSlot(state: UIState, placement: NativePlacement, view: NativeViewId) {
  if (placement === "left") state.setActiveView(view);
  else if (placement === "bottom") state.setBottomPaneActiveTab(view);
  else state.setActiveRightSidebarView(view);
}

function showSlot(state: UIState, placement: NativePlacement, visible: boolean) {
  if (placement === "left") state.setIsSidebarVisible(visible);
  else if (placement === "bottom") state.setIsBottomPaneVisible(visible);
  else state.setIsRightSidebarVisible(visible);
}

export function openNativeContribution(entry: DockableContribution): void {
  const placement = nativePlacement(entry, useNativeDocking.getState().placements);
  const state = useUIState.getState();
  const slot = nativeSlot(state, placement);
  const view = nativeViewId(entry);
  selectSlot(state, placement, view);
  showSlot(state, placement, !(slot.visible && slot.view === view));
}

export function moveNativeContribution(
  entry: DockableContribution,
  placement: NativePlacement,
): void {
  const state = useUIState.getState();
  const view = nativeViewId(entry);
  // Clear only this contribution's previous selection. Other tools keep their
  // selection/visibility, and only one slot can mount this native owner.
  for (const previous of ["left", "bottom", "right"] as const) {
    if (previous !== placement && nativeSlot(state, previous).view === view)
      showSlot(state, previous, false);
  }
  useNativeDocking.setState(({ placements }) => ({
    placements: { ...placements, [view]: placement },
  }));
  selectSlot(state, placement, view);
  showSlot(state, placement, true);
}

export function closeNativeContribution(
  view: string,
  placement: NativePlacement,
  workspaceId: string,
): void {
  // The existing UI actions persist through the active project adapter. A
  // stale callback must not run a parked workspace's actions for a new project.
  if (workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId) return;
  const state = useUIState.getStore(workspaceId).getState();
  if (nativeSlot(state, placement).view === view) showSlot(state, placement, false);
}

export const nativeTriggerId = (view: string) => `native-trigger-${view}`;
