import { appDataDir, join } from "@tauri-apps/api/path";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { useProjectStore } from "@/features/window/stores/project.store";
import { getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";

export interface LocalHistoryEntry {
  id: string;
  file_path: string;
  file_name: string;
  created_at: number;
  size: number;
  content_hash: string;
  reason: string;
  label?: string | null;
}

interface CoreHistoryEntry {
  id: string;
  timestamp: number;
  relativePath: string;
  reason: string;
  contentPath: string;
  byteCount: number;
  label?: string;
}

const coreData = <T>(response: CoreResponse<T>): T => {
  if (response.ok) return response.data;
  throw new Error(`${response.error.code}: ${response.error.message}`);
};

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
    storageRoot: await join(await appDataDir(), "local-history"),
  };
};

const toLocalEntry = (entry: CoreHistoryEntry): LocalHistoryEntry => ({
  id: entry.id,
  file_path: entry.relativePath,
  file_name: entry.relativePath.split("/").pop() ?? entry.relativePath,
  created_at: entry.timestamp,
  size: entry.byteCount,
  content_hash: "",
  reason: entry.reason,
  label: entry.label ?? null,
});

const listCoreEntries = async (path: string): Promise<CoreHistoryEntry[]> => {
  const context = await historyContext(path);
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
  return renameLocalHistoryEntry(path, recorded.id, label);
};

export const listLocalHistoryFile = async (path: string): Promise<LocalHistoryEntry[]> =>
  (await listCoreEntries(path)).map(toLocalEntry);

export const readLocalHistoryEntry = async (path: string, entryId: string): Promise<string> => {
  const context = await historyContext(path);
  const entry = (await listCoreEntries(path)).find((candidate) => candidate.id === entryId);
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
