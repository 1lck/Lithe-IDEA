import { exists } from "@tauri-apps/plugin-fs";
import { homeDir, join } from "@tauri-apps/api/path";
import { useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
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

export function useSpringIndex() {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const loadGeneration = useRef(0);
  const reloadTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    const store = useSpringStore.getState();
    if (!rootFolderPath) {
      store.actions.reset();
      return;
    }

    let cancelled = false;

    const load = async (refreshDependencyMetadata: boolean) => {
      const generation = store.actions.beginLoad(rootFolderPath);
      loadGeneration.current = generation;
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
        const files = await useFileSystemStore.getState().getAllProjectFiles();
        const paths = collectSpringIndexPaths(
          files.map((file) => file.path),
          rootFolderPath,
        );
        const textOverrides: Record<string, string> = {};
        for (const buffer of useBufferStore.getState().buffers) {
          if (!buffer.path || !hasTextContent(buffer) || !isSpringIndexPath(buffer.path)) continue;
          const relative = workspaceRelativeSpringPath(buffer.path, rootFolderPath);
          if (relative) textOverrides[relative] = buffer.content;
        }
        const metadataRepository = refreshDependencyMetadata
          ? await resolveMavenMetadataRepository()
          : undefined;
        const index =
          paths.length === 0
            ? EMPTY_SPRING_INDEX
            : await requestSpringIndex({
                root: rootFolderPath,
                paths,
                metadataRepositories: metadataRepository ? [metadataRepository] : [],
                textOverrides,
                refreshDependencyMetadata,
              });
        if (cancelled) return;
        useSpringStore.getState().actions.completeLoad(generation, rootFolderPath, index);
      } catch (error) {
        console.warn("Spring index failed:", error);
        if (!cancelled) {
          useSpringStore
            .getState()
            .actions.failLoad(generation, classifySpringIndexError(error, rootFolderPath));
        }
      }
    };

    const scheduleReload = () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current);
      reloadTimer.current = setTimeout(() => {
        void load(false);
      }, RELOAD_DELAY_MS);
    };

    void load(true);

    const unsubscribeBuffers = useBufferStore.subscribe((state, previous) => {
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
      if (shouldScheduleSpringReloadForExternalChange(detail.event_type, detail.path)) {
        scheduleReload();
      }
    };
    window.addEventListener("file-external-change", handleExternalChange);

    return () => {
      cancelled = true;
      unsubscribeBuffers();
      window.removeEventListener("file-external-change", handleExternalChange);
      if (reloadTimer.current) clearTimeout(reloadTimer.current);
    };
  }, [rootFolderPath]);
}
