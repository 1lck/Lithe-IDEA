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
  applyRecentProjectsReduction,
  recordedRecentFolderMetadata,
  reduceRecentProjects,
  type RecentFolderDisplayMetadata,
  type RecentProjectsAction,
  updateRecentFolderMetadata,
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
  addToRecents: (folderPath: string, metadata?: RecentFolderMetadata) => Promise<void>;
  /** Resolves with the number of projects that were not listed before. */
  importRecentFolders: (folders: RecentFolderImport[]) => Promise<number>;
  openRecentFolder: (folderPath: string) => Promise<void>;
  /** Marks the entry missing and asks whether to drop it; resolves after the user answers. */
  offerToRemoveUnavailableRecent: (
    folderPath: string,
    messageKey: "fileSystem.recentProjectUnavailable" | "fileSystem.recentProjectNotFolder",
  ) => Promise<void>;
  removeFromRecents: (folderPath: string) => Promise<void>;
  removeMissingFromRecents: () => Promise<void>;
  clearRecents: () => Promise<void>;
  togglePinned: (folderPath: string) => Promise<void>;
  updateRecentFolder: (folderPath: string, metadata: RecentFolderDisplayMetadata) => void;
}

interface RecentFoldersStore extends RecentFoldersState {
  actions: RecentFoldersActions;
}

// Order-changing reductions run one at a time so each one starts from the list
// the previous one produced; metadata-only edits apply immediately.
let pendingReduction: Promise<unknown> = Promise.resolve();

function serialize<T>(operation: () => Promise<T>): Promise<T> {
  const run = pendingReduction.then(operation, operation);
  pendingReduction = run.catch(() => undefined);
  return run;
}

const useRecentFoldersStoreBase = create<RecentFoldersStore>()(
  immer(
    persist(
      (set, get) => {
        /** Runs one Core reduction and returns the paths it added; failures keep the list. */
        const reduce = (
          action: RecentProjectsAction | (() => RecentProjectsAction),
          describe?: Parameters<typeof applyRecentProjectsReduction>[2],
        ) =>
          serialize(async () => {
            const resolved = typeof action === "function" ? action() : action;
            try {
              const reduction = await reduceRecentProjects(get().recentFolders, resolved);
              set((state) => {
                state.recentFolders = applyRecentProjectsReduction(
                  get().recentFolders,
                  reduction,
                  describe,
                );
              });
              return reduction.added;
            } catch (error) {
              console.error("Failed to update recent projects:", resolved.kind, error);
              return [];
            }
          });

        return {
          recentFolders: [],

          actions: {
            addToRecents: (folderPath: string, metadata: RecentFolderMetadata = {}) =>
              reduce(
                {
                  kind: "record",
                  path: folderPath,
                  openedAt: metadata.lastOpenedAt ?? Date.now(),
                },
                (path, existing) =>
                  path === folderPath ? recordedRecentFolderMetadata(metadata)(existing) : {},
              ).then(() => undefined),

            importRecentFolders: async (folders: RecentFolderImport[]) => {
              const sources = new Map<string, RecentFolderImport>();
              for (const folder of folders) {
                if (!sources.has(folder.path)) sources.set(folder.path, folder);
              }
              if (sources.size === 0) return 0;
              // Imported projects rank below anything opened in this session.
              const added = await reduce(
                { kind: "import", paths: [...sources.keys()], openedAt: Date.now() - 60_000 },
                (path, existing) => {
                  const source = existing ? undefined : sources.get(path);
                  return source
                    ? {
                        missing: false,
                        importSourceId: source.sourceId,
                        importSourceName: source.sourceName,
                      }
                    : {};
                },
              );
              return added.length;
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
                await get().actions.removeFromRecents(folderPath);
              }
            },

            removeFromRecents: (folderPath: string) =>
              reduce({ kind: "remove", paths: [folderPath] }).then(() => undefined),

            removeMissingFromRecents: () =>
              reduce(() => ({
                kind: "remove",
                paths: get()
                  .recentFolders.filter((folder) => folder.missing)
                  .map((folder) => folder.path),
              })).then(() => undefined),

            clearRecents: () =>
              serialize(async () => {
                set((state) => {
                  state.recentFolders = [];
                });
              }),

            togglePinned: (folderPath: string) =>
              reduce({ kind: "togglePinned", path: folderPath }).then(() => undefined),

            updateRecentFolder: (folderPath: string, metadata: RecentFolderDisplayMetadata) => {
              set((state) => {
                state.recentFolders = updateRecentFolderMetadata(
                  state.recentFolders,
                  folderPath,
                  metadata,
                );
              });
            },
          },
        };
      },
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
