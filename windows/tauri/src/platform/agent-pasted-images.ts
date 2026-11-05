import { appCacheDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, readDir, readTextFile, remove, stat, writeFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { invoke } from "./tauri-core";

const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_BATCH_BYTES = 32 * 1024 * 1024;
const EXTENSIONS: Record<string, string> = {
  "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
  "image/gif": "gif", "image/bmp": "bmp",
};
let prepare: Promise<string> | undefined;

interface RetentionEntry { path: string; modifiedMs?: number; abandoned: boolean }
interface RetentionPlan { delete: { path: string; reason: string }[]; keep: { path: string; reason: string }[] }

/** Core decides what may be deleted; this adapter lists the cache and removes the files. */
async function retentionPlan(entries: RetentionEntry[]): Promise<RetentionPlan> {
  return invoke<RetentionPlan>("agent.attachments.retentionPlan", {
    nowMs: Date.now(),
    entries,
    acceptedReferences: await acceptedReferences(),
    caseInsensitive: true,
  });
}

/** Ledger of images a conversation accepted; it sits beside the cache, never in the install directory. */
async function ledgerPath(): Promise<string> {
  return join(await appCacheDir(), "agent", "pasted-images-accepted.json");
}

async function acceptedReferences(): Promise<string[]> {
  const path = await ledgerPath();
  if (!(await exists(path))) return [];
  const parsed: unknown = JSON.parse(await readTextFile(path));
  if (!Array.isArray(parsed) || !parsed.every((item) => typeof item === "string")) {
    throw new Error("agent.composer.imageCleanupFailed");
  }
  return parsed;
}

function filePath(uri: string): string | null {
  const match = /^file:\/\/\/(.+)$/.exec(uri);
  return match ? decodeURIComponent(match[1]) : null;
}

/** Remembers the cached images an accepted prompt refers to, so retention never deletes them. */
export async function recordAcceptedPastedImages(uris: string[]): Promise<void> {
  const root = (await directory()).replace(/\\/g, "/").toLowerCase() + "/";
  const accepted = uris.map(filePath).filter((path): path is string =>
    path !== null && path.replace(/\\/g, "/").toLowerCase().startsWith(root));
  if (accepted.length === 0) return;
  const known = new Set<string>();
  const kept: string[] = [];
  for (const path of [...(await acceptedReferences()), ...accepted]) {
    if (known.has(path.toLowerCase()) || !(await exists(path))) continue;
    known.add(path.toLowerCase());
    kept.push(path);
  }
  await writeTextFile(await ledgerPath(), JSON.stringify(kept));
}

async function removePlanned(plan: RetentionPlan): Promise<void> {
  const results = await Promise.allSettled(plan.delete.map((item) => remove(item.path)));
  if (results.some((result) => result.status === "rejected")) throw new Error("agent.composer.imageCleanupFailed");
}

/** User cache owned by the Agent attachment adapter; never a packaged resource. */
async function directory(): Promise<string> {
  prepare ??= (async () => {
    const root = await join(await appCacheDir(), "agent", "pasted-images");
    await mkdir(root, { recursive: true });
    const entries: RetentionEntry[] = [];
    for (const item of await readDir(root)) {
      if (!item.isFile) continue;
      const path = await join(root, item.name);
      entries.push({ path, modifiedMs: (await stat(path)).mtime?.getTime(), abandoned: false });
    }
    try { await removePlanned(await retentionPlan(entries)); } catch (cleanup) { console.warn("Agent paste retention failed", cleanup); }
    return root;
  })().catch((error) => { prepare = undefined; throw error; });
  return prepare;
}

export function validatePastedImage(file: Blob): void {
  if (!EXTENSIONS[file.type] || file.size === 0 || file.size > MAX_IMAGE_BYTES) {
    throw new Error("agent.composer.invalidImage");
  }
}

/** Failed batches and stale paste operations are reported to Core as abandoned and removed at once. */
export async function savePastedImages(files: File[]): Promise<{ paths: string[]; discard: () => Promise<void> }> {
  if (files.length > 32) throw new Error("agent.composer.tooManyImages");
  files.forEach(validatePastedImage);
  if (files.reduce((total, file) => total + file.size, 0) > MAX_BATCH_BYTES) throw new Error("agent.composer.invalidImage");
  const root = await directory();
  const paths: string[] = [];
  const discard = async () => {
    await removePlanned(await retentionPlan(paths.map((path) => ({ path, abandoned: true }))));
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
