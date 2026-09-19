import { invoke } from "@/platform/tauri-core";
import type { PersistedEditorViewState } from "@/features/editor/types/editor-session.types";
import { detectLanguageFromFileName } from "@/features/editor/utils/language-detection";
import { parseWslPath } from "@/features/wsl/utils/wsl-path";
import { readFileContent } from "./file-operations";
import {
  getDatabaseTypeFromPath,
  getFilenameFromPath,
  isBinaryFile,
  isImageFile,
  isPdfFile,
} from "./file-utils";

/**
 * Bounded background restore for workspace-session buffers.
 *
 * On startup `restoreSession` creates metadata-only placeholder tabs for every
 * saved editor buffer, restores the pane layout, and awaits only the active
 * buffer. This controller then drains the remaining buffers in the background
 * with a small concurrency cap, while still allowing an explicit user click to
 * promote a specific buffer to load immediately.
 */

/** Maximum number of files restored concurrently in the background. */
export const SESSION_RESTORE_CONCURRENCY = 2;

export type LoadedFileKind = "text" | "image" | "pdf" | "binary" | "database";

export interface LoadedFileContent {
  kind: LoadedFileKind;
  content?: string;
  language?: string;
}

/**
 * Read a file's content and type in a store-independent way, shared by the
 * session-restore path. This intentionally does not consult the global
 * `latestFileOpenRequestId` used by `handleFileSelect`, so concurrent restores
 * are never misclassified as stale.
 */
export async function loadFileContent(path: string): Promise<LoadedFileContent> {
  if (getDatabaseTypeFromPath(path)) return { kind: "database" };
  if (isImageFile(path)) return { kind: "image" };
  if (isPdfFile(path)) return { kind: "pdf" };
  if (isBinaryFile(path)) return { kind: "binary" };

  const language = detectLanguageFromFileName(getFilenameFromPath(path));

  if (path.startsWith("remote://")) {
    const match = path.match(/^remote:\/\/([^/]+)(\/.*)?$/);
    if (!match) throw new Error(`Invalid remote path: ${path}`);
    const content = await invoke<string>("ssh_read_file", {
      connectionId: match[1],
      filePath: match[2] || "/",
    });
    return { kind: "text", content, language };
  }

  const wslInfo = parseWslPath(path);
  if (wslInfo) {
    const content = await invoke<string>("wsl_read_file", {
      distro: wslInfo.distro,
      filePath: wslInfo.linuxPath,
    });
    return { kind: "text", content, language };
  }

  const content = await readFileContent(path);
  return { kind: "text", content, language };
}

export interface RestoreJob {
  bufferId: string;
  path: string;
  editorState?: PersistedEditorViewState;
}

/** Callbacks let the controller stay store-agnostic and unit-testable. */
export interface SessionRestoreCallbacks {
  markLoading: (bufferId: string) => void;
  applyLoaded: (
    bufferId: string,
    loaded: LoadedFileContent,
    editorState?: PersistedEditorViewState,
  ) => void;
  markFailed: (bufferId: string, error: string) => void;
  /** True while the owning workspace is still the active one. */
  isCurrent: () => boolean;
  /** True while the buffer still exists and still points at `path`. */
  isBufferValid: (bufferId: string, path: string) => boolean;
}

export interface SessionRestoreController {
  /** Queue jobs for bounded background loading (dedupes by path/buffer). */
  enqueue: (jobs: RestoreJob[]) => void;
  /** Promote a queued buffer and load it immediately (used on tab activation). */
  promote: (bufferId: string) => void;
  /** Load a single job immediately, bypassing the background concurrency cap. */
  loadNow: (job: RestoreJob) => Promise<void>;
  /** Drop all pending work and ignore any in-flight completion. */
  dispose: () => void;
  pendingCount: () => number;
}

export function createSessionRestoreController(
  callbacks: SessionRestoreCallbacks,
): SessionRestoreController {
  const queue: RestoreJob[] = [];
  const activeByBufferId = new Map<string, RestoreJob>();
  let inFlight = 0;
  let disposed = false;

  const runJob = async (job: RestoreJob) => {
    callbacks.markLoading(job.bufferId);
    try {
      const loaded = await loadFileContent(job.path);
      if (disposed) return;
      if (!callbacks.isCurrent()) return; // workspace switched away
      if (!callbacks.isBufferValid(job.bufferId, job.path)) return; // tab closed / path moved
      callbacks.applyLoaded(job.bufferId, loaded, job.editorState);
    } catch (error) {
      if (disposed) return;
      if (!callbacks.isCurrent()) return;
      if (!callbacks.isBufferValid(job.bufferId, job.path)) return;
      callbacks.markFailed(job.bufferId, error instanceof Error ? error.message : String(error));
    } finally {
      activeByBufferId.delete(job.bufferId);
      inFlight -= 1;
      pump();
    }
  };

  const pump = () => {
    if (disposed) return;
    while (inFlight < SESSION_RESTORE_CONCURRENCY && queue.length > 0) {
      const job = queue.shift()!;
      inFlight += 1;
      activeByBufferId.set(job.bufferId, job);
      void runJob(job);
    }
  };

  return {
    enqueue(jobs) {
      if (disposed) return;
      for (const job of jobs) {
        if (activeByBufferId.has(job.bufferId)) continue;
        if (queue.some((queued) => queued.path === job.path)) continue;
        queue.push(job);
      }
      pump();
    },

    promote(bufferId) {
      if (disposed) return;
      const index = queue.findIndex((job) => job.bufferId === bufferId);
      if (index < 0) return; // already in flight or unknown
      const [job] = queue.splice(index, 1);
      if (job) {
        inFlight += 1;
        activeByBufferId.set(job.bufferId, job);
        void runJob(job);
      }
    },

    async loadNow(job) {
      if (disposed || activeByBufferId.has(job.bufferId)) return;
      const index = queue.findIndex(
        (queued) => queued.bufferId === job.bufferId || queued.path === job.path,
      );
      // Prefer the queued job so promotion preserves its persisted editor view
      // state instead of replacing it with the caller's minimal buffer identity.
      const queuedJob = index >= 0 ? queue.splice(index, 1)[0] : undefined;
      const jobToLoad = queuedJob ?? job;
      inFlight += 1;
      activeByBufferId.set(jobToLoad.bufferId, jobToLoad);
      await runJob(jobToLoad);
    },

    dispose() {
      disposed = true;
      queue.length = 0;
      activeByBufferId.clear();
    },

    pendingCount: () => queue.length,
  };
}
