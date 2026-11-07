import {
  historyWorkspaceIdentity,
  toLocalEntry,
  type CoreHistoryEntry,
  type LocalHistoryEntry,
} from "../utils/history-metadata";
export type { LocalHistoryEntry } from "../utils/history-metadata";
import { appDataDir, join } from "@tauri-apps/api/path";
import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { hiddenPathRules } from "@/features/settings/lib/hidden-path-rules";
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
      ...hiddenPathRules(),
    },
  });
  return coreData(response).entries;
};

/** Editing events that record snapshots; Core's `history.planEvent` owns what each records. */
export type LocalHistoryEvent = "save" | "autoSave" | "restore" | "manual";
/** Whether a snapshot holds the text before the event changed the file or after it did. */
export type LocalHistoryPhase = "beforeChange" | "afterChange";

interface PlannedSnapshot {
  source: "beforeChange" | "afterChange" | "editorBuffer";
  reason: string;
}

/**
 * Records the snapshots Core plans for `event` in `phase`, reading the file from disk.
 * Returns the last entry created; a label is applied to it.
 */
export const recordLocalHistoryFile = async (
  path: string,
  event: LocalHistoryEvent,
  phase: LocalHistoryPhase,
  label?: string,
): Promise<LocalHistoryEntry | null> => {
  const context = await historyContext(path);
  const { snapshots } = coreData(
    await executeCore<{ snapshots: PlannedSnapshot[] }>({
      id: crypto.randomUUID(),
      command: "history.planEvent",
      payload: { event },
    }),
  );
  let recorded: CoreHistoryEntry | null = null;
  for (const snapshot of snapshots.filter((planned) => planned.source === phase)) {
    const entry = coreData(
      await executeCore<CoreHistoryEntry | null>({
        id: crypto.randomUUID(),
        command: "history.record",
        payload: {
          workspaceRoot: context.workspaceRoot,
          storageRoot: context.storageRoot,
          path: context.relativePath,
          reason: snapshot.reason,
          ...hiddenPathRules(),
        },
      }),
    );
    recorded = entry ?? recorded;
  }
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

/**
 * Moves retained history to a renamed or moved file or directory. Paths outside the
 * active workspace have no history to move.
 */
export const relocateLocalHistory = async (
  sourcePath: string,
  destinationPath: string,
): Promise<void> => {
  const workspaceRoot = useProjectStore.getState().rootFolderPath;
  if (
    !workspaceRoot ||
    !pathStartsWithRoot(sourcePath, workspaceRoot) ||
    !pathStartsWithRoot(destinationPath, workspaceRoot)
  ) {
    return;
  }
  const relative = (path: string) => getRelativePath(path, workspaceRoot).replace(/\\/g, "/");
  const sourceRelative = relative(sourcePath);
  const destinationRelative = relative(destinationPath);
  if (!sourceRelative || !destinationRelative) return;
  coreData(
    await executeCore<{ relocated: boolean }>({
      id: crypto.randomUUID(),
      command: "history.relocate",
      payload: {
        storageRoot: await workspaceHistoryStorage(workspaceRoot),
        sourcePath: sourceRelative,
        destinationPath: destinationRelative,
      },
    }),
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
    payload: {
      workspaceRoot,
      storageRoot: await workspaceHistoryStorage(workspaceRoot),
      ...hiddenPathRules(),
    },
  });
  return coreData(response).entries.map(toLocalEntry);
}
