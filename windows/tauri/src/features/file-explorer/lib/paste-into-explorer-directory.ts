import { useFileClipboardStore } from "@/features/file-explorer/stores/file-explorer-clipboard.store";
import { migrateWorkspaceDirectoryMarks } from "@/features/file-explorer/stores/directory-marks";
import { relocateLocalHistory } from "@/features/local-history/api/local-history-api";
import {
  tryPasteJavaClassFromSystemClipboard,
  type CreateFileInDirectory,
} from "./paste-java-class-from-clipboard";

/**
 * Pastes in-app copied/cut files when present; otherwise tries IDEA-style Java
 * class paste from the system clipboard into `targetDirectory`.
 */
export async function pasteIntoExplorerDirectory(options: {
  targetDirectory: string;
  createFileInDirectory?: CreateFileInDirectory;
  /** Workspace roots whose directory rules follow moved directories (cut and paste). */
  workspaceRoots?: readonly string[];
  refreshDirectory?: (path: string, options?: { force?: boolean }) => void;
  onJavaClassCreated?: (fileName: string) => void;
  onJavaClassFailed?: (error: unknown) => void;
  onNothingToPaste?: () => void;
}): Promise<"files" | "java-class" | "nothing"> {
  const { targetDirectory, createFileInDirectory, refreshDirectory } = options;
  const clipboard = useFileClipboardStore.getState().clipboard;
  const clipboardActions = useFileClipboardStore.getState().actions;

  if (clipboard) {
    const pasted = await clipboardActions.paste(targetDirectory);
    if (clipboard.operation === "cut") {
      // A cut moves the files, so their retained history and directory rules move with them.
      for (const entry of pasted) {
        try {
          await relocateLocalHistory(entry.source_path, entry.destination_path);
          await migrateWorkspaceDirectoryMarks(
            options.workspaceRoots ?? [],
            entry.source_path,
            entry.destination_path,
          );
        } catch (error) {
          console.warn("Failed to carry history and directory rules to the pasted path:", error);
        }
      }
    }
    refreshDirectory?.(targetDirectory, { force: true });
    return "files";
  }

  if (!createFileInDirectory) {
    options.onNothingToPaste?.();
    return "nothing";
  }

  try {
    const created = await tryPasteJavaClassFromSystemClipboard({
      targetDirectory,
      createFileInDirectory,
    });
    if (!created) {
      options.onNothingToPaste?.();
      return "nothing";
    }
    refreshDirectory?.(targetDirectory, { force: true });
    options.onJavaClassCreated?.(created.fileName);
    return "java-class";
  } catch (error) {
    options.onJavaClassFailed?.(error);
    return "nothing";
  }
}
