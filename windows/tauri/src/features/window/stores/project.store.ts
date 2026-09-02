import { combine } from "zustand/middleware";
import { createStore } from "zustand/vanilla";
import { connectionStore } from "@/features/remote/stores/remote-connection.store";
import { parseRemotePath } from "@/features/remote/utils/remote-path";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getFolderName } from "@/utils/path-helpers";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { createTranslator } from "@/i18n/locale";
import { getProjectDisplayLabel } from "../utils/project-display-label";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

const createProjectStore = () =>
  createStore(
    combine(
      {
        projectName: getCurrentTranslator()("files.title"),
        rootFolderPath: undefined as string | undefined,
        activeProjectId: undefined as string | undefined,
      },
      (set, get) => ({
        actions: {
          setProjectName: (name: string) => set({ projectName: name }),
          setRootFolderPath: (path: string | undefined) => set({ rootFolderPath: path }),
          setActiveProjectId: (id: string | undefined) => set({ activeProjectId: id }),

          getProjectName: async () => {
            // Try to get from workspace tabs first
            const activeTab = useWorkspaceTabsStore.getState().actions.getActiveProjectTab();
            if (activeTab) {
              const remoteInfo = parseRemotePath(activeTab.path);
              if (remoteInfo) {
                try {
                  const connection = await connectionStore.getConnection(remoteInfo.connectionId);
                  return connection
                    ? getCurrentTranslator()("projectPicker.remoteProjectName", {
                        name: connection.name,
                      })
                    : getProjectDisplayLabel(activeTab);
                } catch {
                  return getProjectDisplayLabel(activeTab);
                }
              }

              return getProjectDisplayLabel(activeTab);
            }

            const { rootFolderPath } = get();
            if (!rootFolderPath) return getCurrentTranslator()("files.title");

            return getFolderName(rootFolderPath);
          },
        },
      }),
    ),
  );

export const useProjectStore = createWorkspaceScopedStore("project", createProjectStore);
