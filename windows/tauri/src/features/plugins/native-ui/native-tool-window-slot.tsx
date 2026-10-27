import { lazy, Suspense, useEffect, type ReactNode } from "react";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useDeclarativePluginUI } from "../declarative-plugin-ui";
import {
  closeNativeContribution,
  nativePlacement,
  nativeSlot,
  nativeTriggerId,
  nativeViewId,
  useNativeDocking,
  type NativePlacement,
} from "./native-docking";

const NativeToolWindow = lazy(() => import("./native-tool-window"));

/** Shared slot adapter: visibility is owned by the existing workbench stores.
 * Hidden native content unmounts even when its parent preserves other tools. */
export function NativeToolWindowSlot({
  placement,
  children,
}: {
  placement: NativePlacement;
  children?: ReactNode;
}) {
  const view = useUIState((state) => nativeSlot(state, placement).view);
  const visible = useUIState((state) => nativeSlot(state, placement).visible);
  const placements = useNativeDocking((state) => state.placements);
  const entry = useDeclarativePluginUI((state) =>
    state.nativeWindows?.find((entry) => nativeViewId(entry) === view),
  );
  const workspaceId = useActiveWorkspaceId();
  const selected = view.startsWith("plugin-native:");
  const matches = !!entry && nativePlacement(entry, placements) === placement;
  useEffect(() => {
    if (selected && visible && !matches) closeNativeContribution(view, placement, workspaceId);
  }, [selected, visible, matches, view, placement, workspaceId]);
  if (!selected) return children;
  if (!visible || !entry || !matches) return null;
  return (
    <div className="h-full min-h-0 min-w-0" data-native-tool-window-slot={placement}>
      <Suspense fallback={null}>
        <NativeToolWindow
          view={view}
          onClose={() => {
            const current = useDeclarativePluginUI
              .getState()
              .nativeWindows.find((candidate) => nativeViewId(candidate) === view);
            if (
              !current ||
              workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId ||
              nativeSlot(useUIState.getState(), placement).view !== view ||
              current.packageIdentity !== entry.packageIdentity ||
              nativePlacement(current, useNativeDocking.getState().placements) !== placement
            )
              return;
            closeNativeContribution(view, placement, workspaceId);
            document.getElementById(nativeTriggerId(view))?.focus();
          }}
        />
      </Suspense>
    </div>
  );
}
