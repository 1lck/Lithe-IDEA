import { exists } from "@tauri-apps/plugin-fs";
import { homeDir, join } from "@tauri-apps/api/path";
import { useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { requestSpringIndex } from "../api/spring-index-api";
import { useSpringStore } from "../stores/spring.store";
import { EMPTY_SPRING_INDEX } from "../types/spring.types";
import {
  collectSpringIndexPaths,
  isSpringIndexPath,
  workspaceRelativeSpringPath,
} from "../utils/spring-index-paths";

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
        if (!cancelled) useSpringStore.getState().actions.failLoad(generation);
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
      const path = (event as CustomEvent<{ path?: string }>).detail?.path;
      if (path && isSpringIndexPath(path)) scheduleReload();
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
