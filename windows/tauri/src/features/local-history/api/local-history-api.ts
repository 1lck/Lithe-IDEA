import {
  historyWorkspaceIdentity,
  toLocalEntry,
  type CoreHistoryEntry,
  type LocalHistoryEntry,
} from "../utils/history-metadata";
export type { LocalHistoryEntry } from "../utils/history-metadata";
import { appDataDir, join } from "@tauri-apps/api/path";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { useProjectStore } from "@/features/window/stores/project.store";
import { getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";

const coreData = <T>(response: CoreResponse<T>): T => {
  if (response.ok) return response.data;
  throw new Error(`${response.error.code}: ${response.error.message}`);
};

export async function workspaceHistoryStorage(workspaceRoot: string): Promise<string> {
  const key = await historyWorkspaceIdentity(workspaceRoot);
  return join(await appDataDir(), "local-history", "workspaces", key);
}

const historyContext = async (path: string) => {
  const workspaceRoot = useProjectStore.getState().rootFolderPath;
  if (!workspaceRoot) throw new Error("Open a workspace before using local history");
  if (!pathStartsWithRoot(path, workspaceRoot)) {
    throw new Error("Local history path must be inside the active workspace");
  }
  const relativePath = getRelativePath(path, workspaceRoot).replace(/\\/g, "/");
  if (!relativePath) throw new Error("Local history requires a file path");
  return {
    workspaceRoot,
    relativePath,
    storageRoot: await workspaceHistoryStorage(workspaceRoot),
  };
};

const listCoreEntries = async (
  context: Awaited<ReturnType<typeof historyContext>>,
): Promise<CoreHistoryEntry[]> => {
  const response = await executeCore<{ entries: CoreHistoryEntry[] }>({
    id: crypto.randomUUID(),
    command: "history.entries",
    payload: {
      workspaceRoot: context.workspaceRoot,
      storageRoot: context.storageRoot,
      path: context.relativePath,
    },
  });
  return coreData(response).entries;
};

export const recordLocalHistoryFile = async (
  path: string,
  reason: "save" | "auto-save" | "restore" | "manual" = "save",
  label?: string,
): Promise<LocalHistoryEntry | null> => {
  const context = await historyContext(path);
  const coreReason = reason === "restore" ? "restored" : "saved";
  const recorded = coreData(
    await executeCore<CoreHistoryEntry | null>({
      id: crypto.randomUUID(),
      command: "history.record",
      payload: {
        workspaceRoot: context.workspaceRoot,
        storageRoot: context.storageRoot,
        path: context.relativePath,
        reason: coreReason,
      },
    }),
  );
  if (!recorded) return null;
  if (!label) return toLocalEntry(recorded);
  return toLocalEntry(
    coreData(
      await executeCore<CoreHistoryEntry>({
        id: crypto.randomUUID(),
        command: "history.rename",
        payload: {
          storageRoot: context.storageRoot,
          path: context.relativePath,
          id: recorded.id,
          label,
        },
      }),
    ),
  );
};

export const listLocalHistoryFile = async (path: string): Promise<LocalHistoryEntry[]> =>
  (await listCoreEntries(await historyContext(path))).map(toLocalEntry);

export const readLocalHistoryEntry = async (path: string, entryId: string): Promise<string> => {
  const context = await historyContext(path);
  const entry = (await listCoreEntries(context)).find((candidate) => candidate.id === entryId);
  if (!entry) throw new Error("Local history entry was not found");
  const response = await executeCore<{ text: string }>({
    id: crypto.randomUUID(),
    command: "history.content",
    payload: { storageRoot: context.storageRoot, contentPath: entry.contentPath },
  });
  return coreData(response).text;
};

export const deleteLocalHistoryEntry = async (path: string, entryId: string): Promise<void> => {
  const context = await historyContext(path);
  coreData(
    await executeCore<{ deleted: boolean }>({
      id: crypto.randomUUID(),
      command: "history.delete",
      payload: { storageRoot: context.storageRoot, path: context.relativePath, id: entryId },
    }),
  );
};

export const renameLocalHistoryEntry = async (
  path: string,
  entryId: string,
  label: string | null,
): Promise<LocalHistoryEntry> => {
  const context = await historyContext(path);
  const response = await executeCore<CoreHistoryEntry>({
    id: crypto.randomUUID(),
    command: "history.rename",
    payload: {
      storageRoot: context.storageRoot,
      path: context.relativePath,
      id: entryId,
      label,
    },
  });
  return toLocalEntry(coreData(response));
};

/** Project timelines use Core's existing unfiltered metadata query. */
export async function listProjectLocalHistory(workspaceRoot: string): Promise<LocalHistoryEntry[]> {
  const response = await executeCore<{ entries: CoreHistoryEntry[] }>({
    id: crypto.randomUUID(),
    command: "history.entries",
    payload: { workspaceRoot, storageRoot: await workspaceHistoryStorage(workspaceRoot) },
  });
  return coreData(response).entries.map(toLocalEntry);
}
