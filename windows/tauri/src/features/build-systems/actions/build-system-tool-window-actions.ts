import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { buildSystemViewId } from "../build-systems-store";
import type { BuildCatalogEntry } from "../build-systems-types";

/**
 * Tool-window actions for declarative build systems. The shell (docking,
 * visibility) reuses the shared right tool-window registry; entries appear
 * per enabled plugin build system and stay available with an empty state
 * while no project is detected.
 */

export function toggleBuildSystemWindow(entry: BuildCatalogEntry): void {
  applyRightToolWindowIntent(buildSystemViewId(entry.pluginId, entry.buildSystemId), "toggle");
}

export function closeBuildSystemWindow(entry: BuildCatalogEntry): void {
  applyRightToolWindowIntent(buildSystemViewId(entry.pluginId, entry.buildSystemId), "close");
}
