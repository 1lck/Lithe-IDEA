import { useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import {
  collectUnsavedIndexTextOverrides,
  didIndexedEditorTextChange,
} from "@/features/editor/utils/workspace-index-overrides";
import { requestMybatisIndex } from "../api/mybatis-index-api";
import { useMybatisStore } from "../stores/mybatis.store";
import { EMPTY_MYBATIS_INDEX } from "../types/mybatis.types";
import {
  collectMybatisIndexPaths,
  editAffectsMybatisIndex,
  hasMybatisMapperCandidate,
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

    const performLoad = async () => {
      const generation = store.actions.beginLoad(rootFolderPath);
      loadGeneration.current = generation;
      try {
        const files = await useFileSystemStore.getState().getAllProjectFiles();
        if (cancelled) return;
        const paths = collectMybatisIndexPaths(
          files.map((file) => file.path),
          rootFolderPath,
        );
        const textOverrides = collectUnsavedIndexTextOverrides(
          useBufferStore.getState().buffers,
          isMybatisIndexPath,
          (path) => workspaceRelativeMybatisPath(path, rootFolderPath),
        );
        // Statements come only from XML mappers; without one, skip parsing
        // every Java file in the workspace.
        const index = !hasMybatisMapperCandidate(paths, textOverrides)
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

    // A workspace scan can outlast the reload debounce. Keep one load in
    // flight and fold triggers that arrive meanwhile into a single follow-up.
    let inFlight = false;
    let pending = false;
    const load = async () => {
      pending = true;
      if (inFlight) return;
      inFlight = true;
      try {
        while (pending && !cancelled) {
          pending = false;
          await performLoad();
        }
      } finally {
        inFlight = false;
      }
    };

    const scheduleReload = () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current);
      reloadTimer.current = setTimeout(() => {
        void load();
      }, RELOAD_DELAY_MS);
    };

    void load();

    // Opening or saving a clean Java file leaves the indexed text unchanged;
    // only unsaved edits and discarded edits need a rescan.
    const unsubscribeBuffers = useBufferStore.subscribe((state, previous) => {
      if (didIndexedEditorTextChange(state.buffers, previous.buffers, editAffectsMybatisIndex)) {
        scheduleReload();
      }
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
