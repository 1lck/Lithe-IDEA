import { create } from "zustand";
import { persist } from "zustand/middleware";
import { immer } from "zustand/middleware/immer";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createAppWindow } from "@/features/window/utils/create-app-window";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { createTranslator } from "@/i18n/locale";
import { showConfirmDialog } from "@/ui/dialog";
import { getFolderName } from "@/utils/path-helpers";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";
import type { RecentFolder, RecentFolderMetadata } from "../types/recent-folders.types";
import {
  chooseProjectOpenDestination,
  executeProjectOpenDecision,
  hasOpenProjectWorkspace,
} from "../controllers/project-open-destination";
import {
  removeMissingRecentFolders,
  toggleRecentFolderPinned,
  uniqueRecentFolderImports,
  updateRecentFolderMetadata,
  upsertRecentFolder,
} from "../utils/recent-folders";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

export interface RecentFolderImport {
  path: string;
  sourceId?: string;
  sourceName?: string;
}

interface RecentFoldersState {
  recentFolders: RecentFolder[];
}

interface RecentFoldersActions {
  addToRecents: (folderPath: string, metadata?: RecentFolderMetadata) => void;
  importRecentFolders: (folders: RecentFolderImport[]) => number;
  openRecentFolder: (folderPath: string) => Promise<void>;
  /** Marks the entry missing and asks whether to drop it; resolves after the user answers. */
  offerToRemoveUnavailableRecent: (
    folderPath: string,
    messageKey: "fileSystem.recentProjectUnavailable" | "fileSystem.recentProjectNotFolder",
  ) => Promise<void>;
  removeFromRecents: (folderPath: string) => void;
  removeMissingFromRecents: () => void;
  clearRecents: () => void;
  togglePinned: (folderPath: string) => void;
  updateRecentFolder: (folderPath: string, metadata: RecentFolderMetadata) => void;
}

interface RecentFoldersStore extends RecentFoldersState {
  actions: RecentFoldersActions;
}

const useRecentFoldersStoreBase = create<RecentFoldersStore>()(
  immer(
    persist(
      (set, get) => ({
        recentFolders: [],

        actions: {
          addToRecents: (folderPath: string, metadata: RecentFolderMetadata = {}) => {
            set((state) => {
              state.recentFolders = upsertRecentFolder(state.recentFolders, folderPath, metadata);
            });
          },

          importRecentFolders: (folders: RecentFolderImport[]) => {
            const uniqueFolders = uniqueRecentFolderImports(folders);
            const existingPaths = new Set(get().recentFolders.map((folder) => folder.path));
            const importedFolders = uniqueFolders.filter(
              (folder) => !existingPaths.has(folder.path),
            );

            if (importedFolders.length === 0) {
              return 0;
            }

            const importBaseTime = Date.now() - 60_000;
            set((state) => {
              state.recentFolders = importedFolders.reduce(
                (recentFolders, folder, index) =>
                  upsertRecentFolder(recentFolders, folder.path, {
                    lastOpenedAt: importBaseTime - index,
                    missing: false,
                    importSourceId: folder.sourceId,
                    importSourceName: folder.sourceName,
                  }),
                state.recentFolders,
              );
            });

            return importedFolders.length;
          },

          openRecentFolder: async (folderPath: string) => {
            try {
              const { getSymlinkInfo } = await import("../controllers/platform");
              const { useFileSystemStore } = await import("../stores/file-system.store");
              const fileSystemState = useFileSystemStore.getState();
              const { handleOpenFolderByPath, rootFolderPath } = fileSystemState;
              const hasOpenWorkspace = hasOpenProjectWorkspace({
                rootFolderPath,
                fileCount: fileSystemState.files.length,
                projectTabCount: useWorkspaceTabsStore.getState().projectTabs.length,
              });

              try {
                const pathInfo = await getSymlinkInfo(folderPath);
                if (!pathInfo.is_dir) {
                  await get().actions.offerToRemoveUnavailableRecent(
                    folderPath,
                    "fileSystem.recentProjectNotFolder",
                  );
                  return;
                }
              } catch (error) {
                console.error("Recent folder is no longer available:", folderPath, error);
                await get().actions.offerToRemoveUnavailableRecent(
                  folderPath,
                  "fileSystem.recentProjectUnavailable",
                );
                return;
              }

              const decision = await chooseProjectOpenDestination({
                projectName: getFolderName(folderPath),
                hasOpenWorkspace,
              });
              if (!decision) return;

              await executeProjectOpenDecision(decision, async (destination) => {
                if (destination === "new-window") {
                  await createAppWindow({
                    path: folderPath,
                    isDirectory: true,
                  });
                  get().actions.addToRecents(folderPath, {
                    missing: false,
                    openInNewWindow: true,
                  });
                  return true;
                }

                const opened = await handleOpenFolderByPath(folderPath, {
                  mode: destination === "this-window" ? "replace-active" : "attach",
                });
                if (opened) {
                  get().actions.addToRecents(folderPath, {
                    missing: false,
                    openInNewWindow: false,
                  });
                }
                return opened;
              });
            } catch (error) {
              console.error("Error opening recent folder:", error);
            }
          },

          // Stays inside the store's action scope so the removal goes through the same
          // `removeFromRecents` that the list UIs use.
          offerToRemoveUnavailableRecent: async (folderPath, messageKey) => {
            get().actions.updateRecentFolder(folderPath, { missing: true });
            const t = getCurrentTranslator();
            // IntelliJ's "Reopen Project" dialog: the project cannot be opened, so the only
            // useful follow-up is dropping the stale entry from the list.
            const shouldRemove = await showConfirmDialog(t(messageKey, { path: folderPath }), {
              title: t("fileSystem.recentProjectUnavailableTitle"),
              confirmLabel: t("fileSystem.removeFromList"),
              cancelLabel: t("projectOpen.cancel"),
            });
            if (shouldRemove) {
              get().actions.removeFromRecents(folderPath);
            }
          },

          removeFromRecents: (folderPath: string) => {
            set((state) => {
              state.recentFolders = state.recentFolders.filter((f) => f.path !== folderPath);
            });
          },

          removeMissingFromRecents: () => {
            set((state) => {
              state.recentFolders = removeMissingRecentFolders(state.recentFolders);
            });
          },

          clearRecents: () => {
            set((state) => {
              state.recentFolders = [];
            });
          },

          togglePinned: (folderPath: string) => {
            set((state) => {
              state.recentFolders = toggleRecentFolderPinned(state.recentFolders, folderPath);
            });
          },

          updateRecentFolder: (folderPath: string, metadata: RecentFolderMetadata) => {
            set((state) => {
              state.recentFolders = updateRecentFolderMetadata(
                state.recentFolders,
                folderPath,
                metadata,
              );
            });
          },
        },
      }),
      {
        name: "lithe-code-recent-folders",
        version: 2,
        storage: createSafeJSONStorage<RecentFoldersState>(),
        partialize: ({ recentFolders }) => ({ recentFolders }),
        merge: (persistedState, currentState) => ({
          ...currentState,
          ...(persistedState as RecentFoldersState),
          actions: currentState.actions,
        }),
        migrate: (persistedState): RecentFoldersState => {
          if (!persistedState || typeof persistedState !== "object") {
            return { recentFolders: [] };
          }

          const state = persistedState as RecentFoldersState;
          if (!Array.isArray(state.recentFolders)) {
            return { recentFolders: [] };
          }

          return {
            ...state,
            recentFolders: state.recentFolders.map((folder) => ({
              ...folder,
              lastOpenedAt:
                folder.lastOpenedAt ??
                (Number.isNaN(Date.parse(folder.lastOpened))
                  ? Date.now()
                  : Date.parse(folder.lastOpened)),
            })),
          };
        },
      },
    ),
  ),
);

export const useRecentFoldersStore = createSelectors(useRecentFoldersStoreBase);
