import { getLspWorkspaceSessionSnapshot } from "@/platform/lsp-core-adapter";
import { useLspStore } from "@/features/editor/lsp/stores/lsp.store";
import { cancelCoreOperation } from "@/core/lithe-core-client";
import { exists } from "@tauri-apps/plugin-fs";
import { homeDir, join } from "@tauri-apps/api/path";
import { useEffect } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { pathStartsWithRoot } from "@/utils/path-helpers";
import { requestSpringIndex } from "../api/spring-index-api";
import { useSpringStore } from "../stores/spring.store";
import { EMPTY_SPRING_INDEX } from "../types/spring.types";
import { classifySpringIndexError } from "../utils/spring-index-error";
import {
  collectSpringIndexPaths,
  isSpringIndexPath,
  shouldScheduleSpringReloadForExternalChange,
  workspaceRelativeSpringPath,
} from "../utils/spring-index-paths";
import { isSupportedSpringRoot } from "../utils/spring-root";

const RELOAD_DELAY_MS = 300;

async function resolveMavenMetadataRepository(): Promise<string | undefined> {
  try {
    const repository = await join(await homeDir(), ".m2", "repository");
    if (await exists(repository)) return repository;
  } catch {
    return undefined;
  }
  return undefined;
}

export interface SpringIndexDependencies {
  requestIndex: typeof requestSpringIndex;
  resolveMetadataRepository: typeof resolveMavenMetadataRepository;
  scheduleReload: (reload: () => void) => () => void;
  subscribeDependencyReady?: (root: string, reload: () => void) => () => void;
  cancelRequest?: (requestId: string) => void;
}

function isDependencyReady(phase: string | undefined): boolean {
  // The Core adapter emits serviceReady; keep the legacy client alias too.
  return phase === "serviceReady" || phase === "fullyReady";
}

/** Observe the current workspace Java session, not readiness in another project. */
export const subscribeSpringDependencyReady: NonNullable<
  SpringIndexDependencies["subscribeDependencyReady"]
> = (root, reload) =>
  useLspStore.subscribe((state, previous) => {
    const session = getLspWorkspaceSessionSnapshot({ workspacePath: root, languageId: "java" });
    if (!session) return;
    const phase = state.lspStatus.lifecycleBySession[session.id];
    if (
      isDependencyReady(phase) &&
      !isDependencyReady(previous.lspStatus.lifecycleBySession[session.id])
    )
      reload();
  });

const defaultDependencies: SpringIndexDependencies = {
  subscribeDependencyReady: subscribeSpringDependencyReady,
  requestIndex: requestSpringIndex,
  resolveMetadataRepository: resolveMavenMetadataRepository,
  cancelRequest: (requestId) => {
    void cancelCoreOperation(requestId);
  },
  scheduleReload: (reload) => {
    const timer = setTimeout(reload, RELOAD_DELAY_MS);
    return () => clearTimeout(timer);
  },
};

export function useSpringIndex(dependencies: SpringIndexDependencies = defaultDependencies) {
  const workspaceId = useActiveWorkspaceId();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);

  useEffect(() => {
    // Capture the owning stores before awaiting; active-workspace accessors can
    // point at a different project by the time a scan or native request returns.
    const store = useSpringStore.getStore(workspaceId).getState();
    const fileSystemStore = useFileSystemStore.getStore(workspaceId);
    const bufferStore = useBufferStore.getStore(workspaceId);
    if (!rootFolderPath) {
      store.actions.reset();
      return;
    }

    let cancelled = false;
    let cancelReload: (() => void) | undefined;
    let metadataRepository: Promise<string | undefined> | undefined;
    let refreshDependencies = false;
    let pendingLoad: { refreshDependencyMetadata: boolean } | null = null;
    let inFlight = false;
    let activeRequestId: string | undefined;

    const performLoad = async (refreshDependencyMetadata: boolean) => {
      const generation = store.actions.beginLoad(rootFolderPath);
      if (!isSupportedSpringRoot(rootFolderPath)) {
        store.actions.failLoad(
          generation,
          classifySpringIndexError(
            new Error("Spring indexing is unavailable for this workspace root"),
            rootFolderPath,
          ),
        );
        return;
      }
      try {
        const files = await fileSystemStore.getState().getAllProjectFiles();
        if (cancelled) return;
        const paths = collectSpringIndexPaths(
          files.map((file) => file.path),
          rootFolderPath,
        );
        const textOverrides: Record<string, string> = {};
        for (const buffer of bufferStore.getState().buffers) {
          if (!buffer.path || !hasTextContent(buffer) || !isSpringIndexPath(buffer.path)) continue;
          const relative = workspaceRelativeSpringPath(buffer.path, rootFolderPath);
          if (relative) textOverrides[relative] = buffer.content;
        }
        // Keep the repository on every request: Core's cache is keyed by the
        // supplied roots, so omitting it would drop dependency completions as
        // soon as the user types. Resolve again when JDT finishes importing.
        if (!metadataRepository || refreshDependencyMetadata) {
          metadataRepository = dependencies.resolveMetadataRepository();
        }
        const repository = await metadataRepository;
        if (cancelled) return;
        let index = EMPTY_SPRING_INDEX;
        if (paths.length !== 0) {
          const requestId = crypto.randomUUID();
          activeRequestId = requestId;
          try {
            index = await dependencies.requestIndex({
              requestId,
              root: rootFolderPath,
              paths,
              metadataRepositories: repository ? [repository] : [],
              textOverrides,
              refreshDependencyMetadata,
            });
          } finally {
            if (activeRequestId === requestId) activeRequestId = undefined;
          }
        }
        if (cancelled) return;
        store.actions.completeLoad(generation, rootFolderPath, index);
      } catch (error) {
        // Cleanup sets `cancelled` before it cancels the native request, so the
        // owner's own cancellation stops here. Any other cancellation is a
        // failure; returning would leave the phase stuck at `loading`.
        if (cancelled) return;
        const failure = classifySpringIndexError(error, rootFolderPath);
        console.warn("Spring index failed:", failure.category);
        store.actions.failLoad(generation, failure);
      }
    };

    // A full workspace scan can outlast the edit debounce. Keep at most one
    // request in flight and fold every trigger that arrives meanwhile into a
    // single follow-up, so a typing burst cannot start parallel full scans.
    const drainLoads = async () => {
      inFlight = true;
      try {
        while (!cancelled && pendingLoad) {
          const next = pendingLoad;
          pendingLoad = null;
          await performLoad(next.refreshDependencyMetadata);
        }
      } finally {
        inFlight = false;
      }
    };

    const load = (refreshDependencyMetadata: boolean) => {
      pendingLoad = {
        refreshDependencyMetadata:
          (pendingLoad?.refreshDependencyMetadata ?? false) || refreshDependencyMetadata,
      };
      if (!inFlight && !cancelled) void drainLoads();
    };

    const scheduleReload = () => {
      cancelReload?.();
      cancelReload = dependencies.scheduleReload(() => {
        cancelReload = undefined;
        const refresh = refreshDependencies;
        refreshDependencies = false;
        load(refresh);
      });
    };

    const unsubscribeDependencies = dependencies.subscribeDependencyReady?.(rootFolderPath, () => {
      if (cancelled) return;
      refreshDependencies = true;
      scheduleReload();
    });
    void load(true);

    const unsubscribeBuffers = bufferStore.subscribe((state, previous) => {
      const changed = state.buffers.some((buffer) => {
        if (!buffer.path || !isSpringIndexPath(buffer.path) || !hasTextContent(buffer))
          return false;
        const previousBuffer = previous.buffers.find((candidate) => candidate.id === buffer.id);
        return (
          !previousBuffer ||
          !hasTextContent(previousBuffer) ||
          previousBuffer.content !== buffer.content
        );
      });
      if (changed) scheduleReload();
    });

    const handleExternalChange = (event: Event) => {
      const detail = (event as CustomEvent<{ path?: string; event_type?: string }>).detail;
      if (!detail?.path || !detail.event_type) return;
      if (!pathStartsWithRoot(detail.path, rootFolderPath)) return;
      if (shouldScheduleSpringReloadForExternalChange(detail.event_type, detail.path)) {
        scheduleReload();
      }
    };
    window.addEventListener("file-external-change", handleExternalChange);

    return () => {
      cancelled = true;
      pendingLoad = null;
      if (activeRequestId) {
        dependencies.cancelRequest?.(activeRequestId);
        activeRequestId = undefined;
      }
      unsubscribeBuffers();
      unsubscribeDependencies?.();
      window.removeEventListener("file-external-change", handleExternalChange);
      cancelReload?.();
    };
  }, [workspaceId, rootFolderPath, dependencies]);
}
