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
  /** True while this controller still owns the workspace restore session. */
  isSessionCurrent: () => boolean;
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
  const completionByBufferId = new Map<string, { promise: Promise<void>; resolve: () => void }>();
  let inFlight = 0;
  let disposed = false;

  const completionFor = (bufferId: string) => {
    const existing = completionByBufferId.get(bufferId);
    if (existing) return existing;

    let resolve!: () => void;
    const completion = {
      promise: new Promise<void>((nextResolve) => {
        resolve = nextResolve;
      }),
      resolve: () => resolve(),
    };
    completionByBufferId.set(bufferId, completion);
    return completion;
  };

  const complete = (bufferId: string) => {
    const completion = completionByBufferId.get(bufferId);
    if (!completion) return;
    completionByBufferId.delete(bufferId);
    completion.resolve();
  };

  const runJob = async (job: RestoreJob) => {
    callbacks.markLoading(job.bufferId);
    try {
      const loaded = await loadFileContent(job.path);
      if (disposed) return;
      if (!callbacks.isSessionCurrent()) return; // a newer restore replaced this session
      if (!callbacks.isBufferValid(job.bufferId, job.path)) return; // tab closed / path moved
      callbacks.applyLoaded(job.bufferId, loaded, job.editorState);
    } catch (error) {
      if (disposed) return;
      if (!callbacks.isSessionCurrent()) return;
      if (!callbacks.isBufferValid(job.bufferId, job.path)) return;
      callbacks.markFailed(job.bufferId, error instanceof Error ? error.message : String(error));
    } finally {
      activeByBufferId.delete(job.bufferId);
      inFlight -= 1;
      complete(job.bufferId);
      pump();
    }
  };

  const startJob = (job: RestoreJob) => {
    inFlight += 1;
    activeByBufferId.set(job.bufferId, job);
    void runJob(job);
  };

  const pump = () => {
    if (disposed) return;
    while (inFlight < SESSION_RESTORE_CONCURRENCY && queue.length > 0) {
      const job = queue.shift()!;
      startJob(job);
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
        queue.unshift(job);
        pump();
      }
    },

    loadNow(job) {
      if (disposed) return Promise.resolve();
      const activeCompletion = completionByBufferId.get(job.bufferId);
      if (activeByBufferId.has(job.bufferId)) return activeCompletion?.promise ?? Promise.resolve();

      const index = queue.findIndex((queued) => queued.bufferId === job.bufferId);
      // Prefer the queued job so promotion preserves its persisted editor view
      // state instead of replacing it with the caller's minimal buffer identity.
      const queuedJob = index >= 0 ? queue.splice(index, 1)[0] : undefined;
      const jobToLoad = queuedJob?.path === job.path ? queuedJob : job;
      const completion = completionFor(jobToLoad.bufferId);

      if (inFlight < SESSION_RESTORE_CONCURRENCY) {
        startJob(jobToLoad);
      } else {
        // User-selected tabs take precedence, but never create unbounded I/O.
        queue.unshift(jobToLoad);
      }

      return completion.promise;
    },

    dispose() {
      disposed = true;
      queue.length = 0;
      activeByBufferId.clear();
      for (const completion of completionByBufferId.values()) completion.resolve();
      completionByBufferId.clear();
    },

    pendingCount: () => queue.length,
  };
}
