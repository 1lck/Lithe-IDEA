import { appCacheDir, join } from "@tauri-apps/api/path";
import { mkdir, remove, writeFile } from "@tauri-apps/plugin-fs";

const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_BATCH_BYTES = 32 * 1024 * 1024;
const EXTENSIONS: Record<string, string> = {
  "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
  "image/gif": "gif", "image/bmp": "bmp",
};
let prepare: Promise<string> | undefined;

/** User cache owned by the Agent attachment adapter; never a packaged resource. */
async function directory(): Promise<string> {
  prepare ??= (async () => {
    const root = await join(await appCacheDir(), "agent", "pasted-images");
    await mkdir(root, { recursive: true });
    // Accepted attachments remain available to historical conversations. Only an
    // abandoned paste owns deletion; age alone does not establish ownership.
    return root;
  })().catch((error) => { prepare = undefined; throw error; });
  return prepare;
}

export function validatePastedImage(file: Blob): void {
  if (!EXTENSIONS[file.type] || file.size === 0 || file.size > MAX_IMAGE_BYTES) {
    throw new Error("agent.composer.invalidImage");
  }
}

/** Failed batches and stale paste operations remove their own files immediately. */
export async function savePastedImages(files: File[]): Promise<{ paths: string[]; discard: () => Promise<void> }> {
  if (files.length > 32) throw new Error("agent.composer.tooManyImages");
  files.forEach(validatePastedImage);
  if (files.reduce((total, file) => total + file.size, 0) > MAX_BATCH_BYTES) throw new Error("agent.composer.invalidImage");
  const root = await directory();
  const paths: string[] = [];
  const discard = async () => {
    const results = await Promise.allSettled(paths.map((path) => remove(path)));
    const failures = results.filter((result) => result.status === "rejected");
    if (failures.length) throw new Error("agent.composer.imageCleanupFailed");
  };
  try {
    for (const file of files) {
      const path = await join(root, `pasted-${crypto.randomUUID()}.${EXTENSIONS[file.type]}`);
      paths.push(path);
      await writeFile(path, new Uint8Array(await file.arrayBuffer()));
    }
    return { paths, discard };
  } catch (error) {
    try { await discard(); } catch (cleanup) { console.warn("Agent paste cleanup failed", cleanup); }
    throw error;
  }
}
