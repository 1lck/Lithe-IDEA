import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { invoke } from "@/platform/tauri-core";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { createProjectWindowRouter, type ProjectWindowOwner } from "./project-window-router";

const currentWindow = getCurrentWebviewWindow();
export const projectWindowRouting = createProjectWindowRouter({
  label: currentWindow.label,
  tabs: () => useWorkspaceTabsStore.getState().projectTabs,
  claim: (tab, activate) =>
    invoke<ProjectWindowOwner>("claim_project_window", {
      path: tab.path,
      workspaceId: tab.id,
      activate,
    }),
  release: (workspaceId) => invoke("release_project_window", { workspaceId }),
  listen: (activate) =>
    currentWindow.listen<string>("activate_project_workspace", (event) => {
      activate(event.payload);
    }),
  switchTo: async (workspaceId) => {
    const { useFileSystemStore } = await import("@/features/file-system/stores/file-system.store");
    return useFileSystemStore.getState().switchToProject(workspaceId);
  },
  reportError: (error) => console.warn("[project-window] routing failed:", error),
});

window.addEventListener("unload", () => projectWindowRouting.dispose(), { once: true });
