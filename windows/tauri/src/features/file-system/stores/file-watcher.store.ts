import { invoke } from "@/platform/tauri-core";
import { combine } from "zustand/middleware";
import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";

const initialState = {
  projectRoot: "",
  watchedPaths: new Set<string>(),
  pendingSaves: new Map<string, number>(), // path -> timestamp
};

export type FileWatcherInvoke = (command: string, arguments_: { path: string }) => Promise<unknown>;

export const createFileWatcherStore = (
  _workspaceId?: string,
  invokeCommand: FileWatcherInvoke = (command, arguments_) => invoke(command, arguments_),
) =>
  createStore(
    combine(initialState, (set, get) => {
      let watchOperationTask = Promise.resolve();
      const enqueueWatchOperation = <T>(operation: () => Promise<T>): Promise<T> => {
        const task = watchOperationTask.then(operation);
        watchOperationTask = task.then(
          () => undefined,
          () => undefined,
        );
        return task;
      };

      const startWatchingNow = async (path: string): Promise<boolean> => {
        const { projectRoot, watchedPaths } = get();
        if (!projectRoot) return false;
        if (watchedPaths.has(path)) {
          return true;
        }

        try {
          await invokeCommand("start_watching", { path });
          set((state) => ({
            watchedPaths: new Set(state.watchedPaths).add(path),
          }));
          return true;
        } catch (error) {
          console.error("Failed to start watching:", path, error);
          return false;
        }
      };

      const stopWatchingNow = async (path: string): Promise<boolean> => {
        const { watchedPaths } = get();
        if (!watchedPaths.has(path)) {
          return true;
        }

        try {
          await invokeCommand("stop_watching", { path });
          set((state) => {
            const newSet = new Set(state.watchedPaths);
            newSet.delete(path);
            return { watchedPaths: newSet };
          });
          return true;
        } catch (error) {
          console.error("Failed to stop watching:", path, error);
          return false;
        }
      };

      const startWatching = (path: string) => enqueueWatchOperation(() => startWatchingNow(path));
      const stopWatching = (path: string) => enqueueWatchOperation(() => stopWatchingNow(path));

      return {
        actions: {
          // Set the project root and start watching it
          setProjectRoot: (path: string) =>
            enqueueWatchOperation(async () => {
              if (!path) {
                set({ projectRoot: "" });
                for (const watchedPath of get().watchedPaths) {
                  await stopWatchingNow(watchedPath);
                }
              }

              try {
                await invokeCommand("set_project_root", { path });
                if (path) set({ projectRoot: path });
                return true;
              } catch (error) {
                console.error("Failed to set project root:", path, error);
                return false;
              }
            }),

          // Start watching a path (file or directory)
          startWatching,

          // Stop watching a path
          stopWatching,

          // Clear pending save status for a file
          clearPendingSave: (path: string) => {
            set((state) => {
              const newPendingSaves = new Map(state.pendingSaves);
              newPendingSaves.delete(path);
              return { pendingSaves: newPendingSaves };
            });
          },

          // Mark a file as having a pending save
          markPendingSave: (path: string) => {
            set((state) => {
              const newPendingSaves = new Map(state.pendingSaves);
              newPendingSaves.set(path, Date.now());
              return { pendingSaves: newPendingSaves };
            });

            // Auto-clear after 800ms to prevent stuck states (longer than Rust's 300ms debounce)
            setTimeout(() => {
              const { pendingSaves } = get();
              const timestamp = pendingSaves.get(path);
              if (timestamp && Date.now() - timestamp >= 800) {
                set((state) => {
                  const newPendingSaves = new Map(state.pendingSaves);
                  newPendingSaves.delete(path);
                  return { pendingSaves: newPendingSaves };
                });
              }
            }, 800);
          },

          // Reset state
          reset: () => {
            set({
              projectRoot: "",
              watchedPaths: new Set(),
              pendingSaves: new Map(),
            });
          },
        },
      };
    }),
  );

export const useFileWatcherStore = createWorkspaceScopedStore(
  "file-watcher",
  createFileWatcherStore,
);
