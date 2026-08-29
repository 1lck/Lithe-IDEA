import { readClipboardText } from "@/utils/clipboard";
import { writeFile } from "@/features/file-system/controllers/platform";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { isRemotePath } from "@/features/remote/utils/remote-path";
import { getBaseName, joinPath } from "@/utils/path-helpers";
import { javaTypeFileName, parseJavaTypeClipboard } from "./java-clipboard-class";

export type CreateFileInDirectory = (
  directoryPath: string,
  fileName: string,
) => void | string | Promise<string | undefined>;

export type JavaClipboardPasteErrorCode = "exists" | "remote" | "create-failed";

export class JavaClipboardPasteError extends Error {
  readonly code: JavaClipboardPasteErrorCode;
  readonly fileName?: string;

  constructor(code: JavaClipboardPasteErrorCode, fileName?: string) {
    super(code);
    this.name = "JavaClipboardPasteError";
    this.code = code;
    this.fileName = fileName;
  }
}

export function assertLocalJavaPasteDirectory(directoryPath: string): void {
  if (isRemotePath(directoryPath)) {
    throw new JavaClipboardPasteError("remote");
  }
}

export function requireCreatedFilePath(
  createdPath: string | undefined,
  fileName: string,
): string {
  if (!createdPath) {
    throw new JavaClipboardPasteError("create-failed", fileName);
  }
  return createdPath;
}

async function pathLooksOccupied(path: string): Promise<boolean> {
  try {
    const { exists } = await import("@tauri-apps/plugin-fs");
    return await exists(path);
  } catch {
    try {
      const { readFile } = await import("@/features/file-system/controllers/platform");
      await readFile(path);
      return true;
    } catch {
      return false;
    }
  }
}

/**
 * When the in-app file clipboard is empty, paste system text that looks like a
 * Java type as `TypeName.java` into `targetDirectory` (IDEA package paste).
 */
export async function tryPasteJavaClassFromSystemClipboard(options: {
  targetDirectory: string;
  createFileInDirectory: CreateFileInDirectory;
}): Promise<{ path: string; fileName: string } | null> {
  let text: string;
  try {
    text = await readClipboardText();
  } catch {
    return null;
  }

  const parsed = parseJavaTypeClipboard(text);
  if (!parsed) return null;

  assertLocalJavaPasteDirectory(options.targetDirectory);

  const fileName = javaTypeFileName(parsed.typeName);
  const destination = joinPath(options.targetDirectory, fileName);
  if (await pathLooksOccupied(destination)) {
    throw new JavaClipboardPasteError("exists", fileName);
  }

  const createdPath = requireCreatedFilePath(
    await Promise.resolve(options.createFileInDirectory(options.targetDirectory, fileName)),
    fileName,
  );

  await writeFile(createdPath, parsed.content);

  const bufferStore = useBufferStore.getState();
  const createdBuffer = bufferStore.buffers.find((buffer) => buffer.path === createdPath);
  if (createdBuffer) {
    bufferStore.actions.updateBufferContent(createdBuffer.id, parsed.content, false);
  }

  return { path: createdPath, fileName: getBaseName(createdPath) || fileName };
}
