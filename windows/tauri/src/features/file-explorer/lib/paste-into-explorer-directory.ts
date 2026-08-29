import { useFileClipboardStore } from "@/features/file-explorer/stores/file-explorer-clipboard.store";
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
  refreshDirectory?: (path: string, options?: { force?: boolean }) => void;
  onJavaClassCreated?: (fileName: string) => void;
  onJavaClassFailed?: (fileName: string, error: unknown) => void;
  onNothingToPaste?: () => void;
}): Promise<"files" | "java-class" | "nothing"> {
  const { targetDirectory, createFileInDirectory, refreshDirectory } = options;
  const clipboard = useFileClipboardStore.getState().clipboard;
  const clipboardActions = useFileClipboardStore.getState().actions;

  if (clipboard) {
    await clipboardActions.paste(targetDirectory);
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
    const fallbackName = "Java class";
    options.onJavaClassFailed?.(fallbackName, error);
    return "nothing";
  }
}
