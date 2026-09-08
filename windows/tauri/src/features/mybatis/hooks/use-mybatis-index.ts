import { useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { requestMybatisIndex } from "../api/mybatis-index-api";
import { useMybatisStore } from "../stores/mybatis.store";
import { EMPTY_MYBATIS_INDEX } from "../types/mybatis.types";
import {
  collectMybatisIndexPaths,
  isMybatisIndexPath,
  workspaceRelativeMybatisPath,
} from "../utils/mybatis-index-paths";

const RELOAD_DELAY_MS = 300;

export function useMybatisIndex() {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const loadGeneration = useRef(0);
  const reloadTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    const store = useMybatisStore.getState();
    if (!rootFolderPath) {
      store.actions.reset();
      return;
    }

    let cancelled = false;

    const load = async () => {
      const generation = store.actions.beginLoad(rootFolderPath);
      loadGeneration.current = generation;
      try {
        const files = await useFileSystemStore.getState().getAllProjectFiles();
        const paths = collectMybatisIndexPaths(
          files.map((file) => file.path),
          rootFolderPath,
        );
        const textOverrides: Record<string, string> = {};
        for (const buffer of useBufferStore.getState().buffers) {
          if (!buffer.path || !hasTextContent(buffer) || !isMybatisIndexPath(buffer.path)) continue;
          const relative = workspaceRelativeMybatisPath(buffer.path, rootFolderPath);
          if (relative) textOverrides[relative] = buffer.content;
        }
        const index =
          paths.length === 0
            ? EMPTY_MYBATIS_INDEX
            : await requestMybatisIndex({
                root: rootFolderPath,
                paths,
                textOverrides,
              });
        if (cancelled) return;
        useMybatisStore.getState().actions.completeLoad(generation, rootFolderPath, index);
      } catch (error) {
        console.warn("MyBatis index failed:", error);
        if (!cancelled) useMybatisStore.getState().actions.failLoad(generation);
      }
    };

    const scheduleReload = () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current);
      reloadTimer.current = setTimeout(() => {
        void load();
      }, RELOAD_DELAY_MS);
    };

    void load();

    const unsubscribeBuffers = useBufferStore.subscribe((state, previous) => {
      const changed = state.buffers.some((buffer) => {
        if (!buffer.path || !isMybatisIndexPath(buffer.path) || !hasTextContent(buffer)) return false;
        const previousBuffer = previous.buffers.find((candidate) => candidate.id === buffer.id);
        return !previousBuffer || !hasTextContent(previousBuffer) || previousBuffer.content !== buffer.content;
      });
      if (changed) scheduleReload();
    });

    const handleExternalChange = (event: Event) => {
      const path = (event as CustomEvent<{ path?: string }>).detail?.path;
      if (path && isMybatisIndexPath(path)) scheduleReload();
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
