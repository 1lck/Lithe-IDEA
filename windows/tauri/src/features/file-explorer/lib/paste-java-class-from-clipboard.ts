import { readClipboardText } from "@/utils/clipboard";
import { writeFile } from "@/features/file-system/controllers/platform";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBaseName, joinPath } from "@/utils/path-helpers";
import {
  nextJavaClassFileName,
  parseJavaTypeClipboard,
} from "./java-clipboard-class";

export type CreateFileInDirectory = (
  directoryPath: string,
  fileName: string,
) => void | string | Promise<string | undefined>;

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

async function resolveUniqueJavaFileName(
  targetDirectory: string,
  typeName: string,
): Promise<string> {
  const existing = new Set<string>();
  // Probe the common IDEA-style candidates until one is free.
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const candidate = nextJavaClassFileName(typeName, existing);
    const fullPath = joinPath(targetDirectory, candidate);
    if (!(await pathLooksOccupied(fullPath))) {
      return candidate;
    }
    existing.add(candidate.toLowerCase());
  }
  return `${typeName} copy ${Date.now()}.java`;
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

  const fileName = await resolveUniqueJavaFileName(options.targetDirectory, parsed.typeName);
  const createdPath =
    (await Promise.resolve(options.createFileInDirectory(options.targetDirectory, fileName))) ||
    joinPath(options.targetDirectory, fileName);

  await writeFile(createdPath, parsed.content);

  const bufferStore = useBufferStore.getState();
  const createdBuffer = bufferStore.buffers.find((buffer) => buffer.path === createdPath);
  if (createdBuffer) {
    bufferStore.actions.updateBufferContent(createdBuffer.id, parsed.content, false);
  }

  return { path: createdPath, fileName: getBaseName(createdPath) || fileName };
}
