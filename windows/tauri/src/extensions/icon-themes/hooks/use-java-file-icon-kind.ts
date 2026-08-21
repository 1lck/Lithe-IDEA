import { useCallback, useEffect, useMemo, useSyncExternalStore } from "react";
import { IDEA_ICON_THEME_ID } from "@/extensions/icon-themes/file-icon-semantics";
import {
  detectJavaFileIconSemanticKind,
  type JavaFileIconSemanticKind,
} from "@/extensions/icon-themes/java-file-kind";
import { isUtf8WithinByteLimit } from "@/extensions/icon-themes/utf8-byte-limit";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getSourceEditorBufferByPath } from "@/features/editor/utils/buffer-index";
import { readFileWithinByteLimit } from "@/features/file-system/controllers/bounded-file-read";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { frontendTrace } from "@/utils/frontend-trace";

interface FileExternalChangeDetail {
  path?: string;
}

interface PendingJavaFileRead {
  fileName: string;
  generation: number;
  path: string;
  taskKey: string;
  epoch: number;
}

const MAX_CONCURRENT_JAVA_ICON_READS = 4;
const MAX_JAVA_ICON_SOURCE_BYTES = 256 * 1024;
const MAX_JAVA_ICON_CACHE_ENTRIES = 512;
const JAVA_ICON_READ_TIMEOUT_MS = 5_000;
const JAVA_ICON_RETRY_DELAY_MS = 1_000;
const javaFileKindCache = new Map<string, JavaFileIconSemanticKind | null>();
const javaFileReadEpochs = new Map<string, number>();
const javaFileReadFailureCounts = new Map<string, number>();
const javaFileRetryAfter = new Map<string, number>();
const queuedJavaFileTasks = new Set<string>();
const pendingJavaFileReads: PendingJavaFileRead[] = [];
const pathSubscribers = new Map<string, Set<() => void>>();
let activeJavaFileReads = 0;
let workspaceGeneration = 0;
let firstReadFailureLogged = false;
let cacheLifecycleRefCount = 0;
let lifecycleWorkspaceUnsubscribe: (() => void) | null = null;

function notifyPath(path: string) {
  for (const callback of pathSubscribers.get(path) ?? []) callback();
}

function notifyAllPaths() {
  for (const path of pathSubscribers.keys()) notifyPath(path);
}

function rememberJavaFileKind(path: string, kind: JavaFileIconSemanticKind | null) {
  javaFileKindCache.delete(path);
  javaFileKindCache.set(path, kind);

  while (javaFileKindCache.size > MAX_JAVA_ICON_CACHE_ENTRIES) {
    const oldestPath = javaFileKindCache.keys().next().value;
    if (typeof oldestPath !== "string") break;
    javaFileKindCache.delete(oldestPath);
  }
}

function invalidateJavaFilePath(path: string) {
  javaFileKindCache.delete(path);
  javaFileReadFailureCounts.delete(path);
  javaFileRetryAfter.delete(path);
  javaFileReadEpochs.set(path, (javaFileReadEpochs.get(path) ?? 0) + 1);
  notifyPath(path);
}

function handleExternalFileChange(event: Event) {
  const path = (event as CustomEvent<FileExternalChangeDetail>).detail?.path;
  if (!path || !path.toLowerCase().endsWith(".java")) return;
  invalidateJavaFilePath(path);
}

function handleWorkspaceChange() {
  workspaceGeneration += 1;
  javaFileKindCache.clear();
  javaFileReadEpochs.clear();
  javaFileReadFailureCounts.clear();
  javaFileRetryAfter.clear();
  pendingJavaFileReads.length = 0;
  queuedJavaFileTasks.clear();
  notifyAllPaths();
}

function subscribeToPath(path: string, callback: () => void) {
  const subscribers = pathSubscribers.get(path) ?? new Set<() => void>();
  subscribers.add(callback);
  pathSubscribers.set(path, subscribers);

  return () => {
    const currentSubscribers = pathSubscribers.get(path);
    currentSubscribers?.delete(callback);
    if (currentSubscribers?.size === 0) pathSubscribers.delete(path);
  };
}

export function useJavaFileIconCacheLifecycle() {
  useEffect(() => {
    cacheLifecycleRefCount += 1;
    if (cacheLifecycleRefCount === 1) {
      window.addEventListener("file-external-change", handleExternalFileChange);
      lifecycleWorkspaceUnsubscribe = workspaceRuntimeRegistry.subscribe(handleWorkspaceChange);
    }

    return () => {
      cacheLifecycleRefCount = Math.max(0, cacheLifecycleRefCount - 1);
      if (cacheLifecycleRefCount === 0) {
        window.removeEventListener("file-external-change", handleExternalFileChange);
        lifecycleWorkspaceUnsubscribe?.();
        lifecycleWorkspaceUnsubscribe = null;
        handleWorkspaceChange();
      }
    };
  }, []);
}

function isEligibleLocalJavaIconPath(path: string): boolean {
  if (!/^[A-Za-z]:[\\/]/.test(path) || path.startsWith("\\\\")) return false;
  const segments = path.replace(/\\/g, "/").toLowerCase().split("/");
  return !segments.some((segment) =>
    ["target", "build", "out", "generated", "generated-sources"].includes(segment),
  );
}

async function readJavaSourceWithinLimit(path: string): Promise<string | null> {
  return readFileWithinByteLimit(path, MAX_JAVA_ICON_SOURCE_BYTES);
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timeoutId = window.setTimeout(
      () => reject(new Error("Java icon source read timed out")),
      timeoutMs,
    );
    promise.then(
      (value) => {
        window.clearTimeout(timeoutId);
        resolve(value);
      },
      (error) => {
        window.clearTimeout(timeoutId);
        reject(error);
      },
    );
  });
}

function scheduleRetry(path: string, fileName: string, generation: number) {
  const retryAt = Date.now() + JAVA_ICON_RETRY_DELAY_MS;
  javaFileRetryAfter.set(path, retryAt);
  window.setTimeout(() => {
    if (generation !== workspaceGeneration || javaFileRetryAfter.get(path) !== retryAt) return;
    javaFileRetryAfter.delete(path);
    queueJavaFileRead(path, fileName);
  }, JAVA_ICON_RETRY_DELAY_MS);
}

function recordReadFailure(pendingRead: PendingJavaFileRead, error: unknown) {
  if (pendingRead.generation !== workspaceGeneration) return;

  const failureCount = (javaFileReadFailureCounts.get(pendingRead.path) ?? 0) + 1;
  javaFileReadFailureCounts.set(pendingRead.path, failureCount);
  if (failureCount >= 2) {
    rememberJavaFileKind(pendingRead.path, null);
  } else {
    scheduleRetry(pendingRead.path, pendingRead.fileName, pendingRead.generation);
  }

  if (!firstReadFailureLogged) {
    firstReadFailureLogged = true;
    frontendTrace("warn", "file-icons", "javaIconSemanticRead:error", {
      path: pendingRead.path,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

function runPendingJavaFileReads() {
  while (activeJavaFileReads < MAX_CONCURRENT_JAVA_ICON_READS && pendingJavaFileReads.length > 0) {
    const pendingRead = pendingJavaFileReads.shift();
    if (!pendingRead) return;

    if (pendingRead.generation !== workspaceGeneration) {
      queuedJavaFileTasks.delete(pendingRead.taskKey);
      continue;
    }

    activeJavaFileReads += 1;
    void withTimeout(readJavaSourceWithinLimit(pendingRead.path), JAVA_ICON_READ_TIMEOUT_MS)
      .then((source) => {
        if (pendingRead.generation !== workspaceGeneration) return;
        if ((javaFileReadEpochs.get(pendingRead.path) ?? 0) !== pendingRead.epoch) return;
        const kind =
          source === null ? null : detectJavaFileIconSemanticKind(pendingRead.fileName, source);
        rememberJavaFileKind(pendingRead.path, kind);
        javaFileReadFailureCounts.delete(pendingRead.path);
        javaFileRetryAfter.delete(pendingRead.path);
      })
      .catch((error) => recordReadFailure(pendingRead, error))
      .finally(() => {
        activeJavaFileReads -= 1;
        queuedJavaFileTasks.delete(pendingRead.taskKey);
        notifyPath(pendingRead.path);

        const currentEpoch = javaFileReadEpochs.get(pendingRead.path) ?? 0;
        if (
          pendingRead.generation === workspaceGeneration &&
          currentEpoch !== pendingRead.epoch &&
          !javaFileKindCache.has(pendingRead.path)
        ) {
          queueJavaFileRead(pendingRead.path, pendingRead.fileName);
        }
        runPendingJavaFileReads();
      });
  }
}

function queueJavaFileRead(path: string, fileName: string) {
  const epoch = javaFileReadEpochs.get(path) ?? 0;
  const taskKey = `${workspaceGeneration}\0${path}`;
  if (
    !isEligibleLocalJavaIconPath(path) ||
    javaFileKindCache.has(path) ||
    queuedJavaFileTasks.has(taskKey) ||
    (javaFileRetryAfter.get(path) ?? 0) > Date.now()
  ) {
    return;
  }

  queuedJavaFileTasks.add(taskKey);
  pendingJavaFileReads.push({
    path,
    fileName,
    epoch,
    generation: workspaceGeneration,
    taskKey,
  });
  runPendingJavaFileReads();
}

export function useJavaFileIconKind(
  path: string,
  fileName: string,
  isDirectory: boolean,
  enabled: boolean,
): JavaFileIconSemanticKind | null {
  const iconThemeId = useSettingsStore((state) => state.settings.iconTheme);
  const isJavaFile = !isDirectory && fileName.toLowerCase().endsWith(".java");
  const semanticIconsEnabled =
    enabled &&
    iconThemeId === IDEA_ICON_THEME_ID &&
    isJavaFile &&
    isEligibleLocalJavaIconPath(path);
  const sourceBufferContent = useBufferStore((state) => {
    if (!semanticIconsEnabled) return null;
    return getSourceEditorBufferByPath(state.buffers, path)?.content ?? null;
  });
  const subscribe = useCallback(
    (callback: () => void) =>
      semanticIconsEnabled ? subscribeToPath(path, callback) : () => undefined,
    [path, semanticIconsEnabled],
  );
  const diskKind = useSyncExternalStore(
    subscribe,
    () => (semanticIconsEnabled ? javaFileKindCache.get(path) : undefined),
    () => undefined,
  );
  const bufferKind = useMemo(
    () =>
      sourceBufferContent === null ||
      !isUtf8WithinByteLimit(sourceBufferContent, MAX_JAVA_ICON_SOURCE_BYTES)
        ? null
        : detectJavaFileIconSemanticKind(fileName, sourceBufferContent),
    [fileName, sourceBufferContent],
  );

  useEffect(() => {
    if (!semanticIconsEnabled || sourceBufferContent !== null) return;
    queueJavaFileRead(path, fileName);
  }, [diskKind, fileName, path, semanticIconsEnabled, sourceBufferContent]);

  if (!semanticIconsEnabled) return null;
  return sourceBufferContent === null ? (diskKind ?? null) : bufferKind;
}
