import { useEffect, useRef } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useWorkspaceTabsStore } from "../stores/workspace-tabs.store";
import { composeWindowTitle, getActiveFileTitleSegment } from "../utils/window-title";

/**
 * Keeps the native window title in sync with the active project and the file
 * open in the editor area, so the Windows taskbar preview, Alt+Tab, and the
 * window list show `project – file` (or the project name alone when no file is
 * open; long titles are folded by Windows itself). Renders nothing and reads
 * both stores through string/object selectors so buffer edits and unrelated
 * tab updates never re-render the workbench.
 */
export function NativeWindowTitleHost() {
  const activeProject = useWorkspaceTabsStore(
    (state) => state.projectTabs.find((tab) => tab.isActive) ?? null,
  );
  const activeFileName = useBufferStore((state) =>
    getActiveFileTitleSegment(state.buffers, state.activeBufferId),
  );
  const title = composeWindowTitle(activeProject, activeFileName);
  const appliedTitleRef = useRef<string | null>(null);

  useEffect(() => {
    // Effect re-runs (StrictMode) without a title change must not re-send IPC.
    if (appliedTitleRef.current === title) {
      return;
    }

    appliedTitleRef.current = title;
    getCurrentWindow()
      .setTitle(title)
      .catch((error: unknown) => {
        console.warn("[native-window-title] failed to update window title:", error);
      });
  }, [title]);

  return null;
}
