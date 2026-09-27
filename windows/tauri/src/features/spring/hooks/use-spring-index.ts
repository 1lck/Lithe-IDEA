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
}

const defaultDependencies: SpringIndexDependencies = {
  requestIndex: requestSpringIndex,
  resolveMetadataRepository: resolveMavenMetadataRepository,
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

    const load = async (refreshDependencyMetadata: boolean) => {
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
        const metadataRepository = refreshDependencyMetadata
          ? await dependencies.resolveMetadataRepository()
          : undefined;
        if (cancelled) return;
        const index =
          paths.length === 0
            ? EMPTY_SPRING_INDEX
            : await dependencies.requestIndex({
                root: rootFolderPath,
                paths,
                metadataRepositories: metadataRepository ? [metadataRepository] : [],
                textOverrides,
                refreshDependencyMetadata,
              });
        if (cancelled) return;
        store.actions.completeLoad(generation, rootFolderPath, index);
      } catch (error) {
        if (!cancelled) {
          const failure = classifySpringIndexError(error, rootFolderPath);
          console.warn("Spring index failed:", failure.category);
          store.actions.failLoad(generation, failure);
        }
      }
    };

    const scheduleReload = () => {
      cancelReload?.();
      cancelReload = dependencies.scheduleReload(() => {
        cancelReload = undefined;
        void load(false);
      });
    };

    void load(true);

    const unsubscribeBuffers = bufferStore.subscribe((state, previous) => {
      const changed = state.buffers.some((buffer) => {
        if (!buffer.path || !isSpringIndexPath(buffer.path) || !hasTextContent(buffer)) return false;
        const previousBuffer = previous.buffers.find((candidate) => candidate.id === buffer.id);
        return !previousBuffer || !hasTextContent(previousBuffer) || previousBuffer.content !== buffer.content;
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
      unsubscribeBuffers();
      window.removeEventListener("file-external-change", handleExternalChange);
      cancelReload?.();
    };
  }, [workspaceId, rootFolderPath, dependencies]);
}
