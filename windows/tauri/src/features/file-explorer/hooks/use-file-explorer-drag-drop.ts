import type React from "react";
import { useCallback, useEffect, useRef, useState } from "react";
import { moveFile, readDirectory } from "@/features/file-system/controllers/platform";
import {
  AGENT_DROP_TARGET_SELECTOR,
  dispatchAgentDropHover,
  dispatchDroppedPathsToAgent,
  dispatchTerminalPathInsert,
  isTerminalDropTarget,
} from "@/features/file-system/utils/file-system-drop-controller";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { clipboardEntryPaths } from "@/features/file-explorer/lib/clipboard-entry-paths";
import { dispatchSidebarResourceDropOnAI } from "@/features/sidebar/utils/sidebar-resource-drag";
import { getTreePathIdentity } from "@/features/sidebar/utils/tree-selection";
import {
  setInternalTabDragHover,
  setInternalTabDragHoverTarget,
} from "@/features/tabs/utils/internal-tab-drag";
import { getDirName, joinPath, pathStartsWithRoot } from "@/utils/path-helpers";

interface DragState {
  isDragging: boolean;
  draggedItem: { path: string; name: string; isDir: boolean } | null;
  draggedItems: FileEntry[];
  dragOverPath: string | null;
  dragOverIsDir: boolean;
  mousePosition: { x: number; y: number };
}

const initialDragState: DragState = {
  isDragging: false,
  draggedItem: null,
  draggedItems: [],
  dragOverPath: null,
  dragOverIsDir: false,
  mousePosition: { x: 0, y: 0 },
};

export function useFileExplorerDragDrop(
  rootFolderPath: string | undefined,
  onFileMove?: (oldPath: string, newPath: string) => void | Promise<void>,
  onAutoExpandDirectory?: (path: string) => void,
  onMoveError?: (message: string) => void,
) {
  const [dragState, setDragState] = useState<DragState>(initialDragState);
  const currentSession = useRef({ rootFolderPath });
  if (currentSession.current.rootFolderPath !== rootFolderPath) {
    // Returning to the same path must not revive an earlier visit's pending batch.
    currentSession.current = { rootFolderPath };
  }
  const session = currentSession.current;
  const live = useRef(true);
  const dropping = useRef(false);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  useEffect(() => {
    setDragState(initialDragState);
  }, [rootFolderPath]);
  const dragPreviewRef = useRef<HTMLDivElement | null>(null);
  const autoExpandRef = useRef<{
    path: string;
    timeoutId: number;
  } | null>(null);

  const clearAutoExpand = useCallback(() => {
    if (!autoExpandRef.current) return;
    window.clearTimeout(autoExpandRef.current.timeoutId);
    autoExpandRef.current = null;
  }, []);

  const clearEditorDropHover = useCallback(() => {
    setInternalTabDragHoverTarget({ paneId: null, zone: null });
  }, []);

  const agentDropHoverTargetRef = useRef<Element | null>(null);
  const clearAgentDropHover = useCallback(() => {
    const previous = agentDropHoverTargetRef.current;
    if (previous === null) return;
    agentDropHoverTargetRef.current = null;
    dispatchAgentDropHover(previous, false);
  }, []);

  const scheduleAutoExpand = useCallback(
    (path: string, isDir: boolean) => {
      if (!isDir || path === "__ROOT__" || !onAutoExpandDirectory) {
        clearAutoExpand();
        return;
      }

      if (autoExpandRef.current?.path === path) {
        return;
      }

      clearAutoExpand();
      autoExpandRef.current = {
        path,
        timeoutId: window.setTimeout(() => {
          onAutoExpandDirectory(path);
          autoExpandRef.current = null;
        }, 550),
      };
    },
    [clearAutoExpand, onAutoExpandDirectory],
  );

  useEffect(() => {
    if (dragState.isDragging && !dragPreviewRef.current) {
      const preview = document.createElement("div");
      preview.style.cssText = `
        position: fixed;
        pointer-events: none;
        z-index: 9999;
        opacity: 0.95;
        padding: 6px 12px;
        background-color: var(--background);
        border: 2px solid var(--primary);
        border-radius: var(--radius-lg);
        font-size: var(--ui-text-sm);
        font-family: var(--app-font-family);
        color: var(--foreground);
        box-shadow: var(--shadow-popover);
      `;
      preview.textContent =
        dragState.draggedItems.length > 1
          ? `${dragState.draggedItem?.name} (+${dragState.draggedItems.length - 1})`
          : dragState.draggedItem?.name || "";
      document.body.appendChild(preview);
      dragPreviewRef.current = preview;
    }

    return () => {
      if (dragPreviewRef.current) {
        document.body.removeChild(dragPreviewRef.current);
        dragPreviewRef.current = null;
      }
    };
  }, [dragState.isDragging, dragState.draggedItem?.name]);

  useEffect(() => {
    if (dragPreviewRef.current) {
      dragPreviewRef.current.style.left = `${dragState.mousePosition.x + 10}px`;
      dragPreviewRef.current.style.top = `${dragState.mousePosition.y - 10}px`;
    }
  }, [dragState.mousePosition]);

  useEffect(() => {
    if (!dragState.isDragging) return;
    const isCurrentSession = () => live.current && currentSession.current === session;

    const handleMouseMove = (e: MouseEvent) => {
      if (dragPreviewRef.current) {
        dragPreviewRef.current.style.left = `${e.clientX + 10}px`;
        dragPreviewRef.current.style.top = `${e.clientY - 10}px`;
      }

      const elementUnder = document.elementFromPoint(e.clientX, e.clientY);

      // The tree drag is mouse-driven, so the Agent composer only learns that it
      // is the drop point from here.
      const agentDropTarget = elementUnder?.closest(AGENT_DROP_TARGET_SELECTOR) ?? null;
      if (agentDropTarget !== agentDropHoverTargetRef.current) {
        agentDropHoverTargetRef.current = agentDropTarget;
        dispatchAgentDropHover(agentDropTarget, agentDropTarget !== null);
      }

      const fileTreeItem = elementUnder?.closest("[data-file-path]");
      const fileTreeContainer = elementUnder?.closest(".file-tree-container");
      const aiContextDropTarget = elementUnder?.closest("[data-ai-context-drop-target]");
      const editorDropTarget =
        elementUnder?.closest("[data-pane-container]") ||
        elementUnder?.closest("[data-tab-bar-pane-id]");

      if (fileTreeItem) {
        clearEditorDropHover();
        const path = fileTreeItem.getAttribute("data-file-path");
        const isDir = fileTreeItem.getAttribute("data-is-dir") === "true";
        const draggedItem = dragState.draggedItem;

        if (path && draggedItem && path !== draggedItem.path) {
          const isDropIntoSelf = dragState.draggedItems.some(
            (item) => item.path === path || (item.isDir && pathStartsWithRoot(path, item.path)),
          );
          const nextDragOverPath = isDropIntoSelf ? null : path;
          const nextDragOverIsDir = isDropIntoSelf ? false : isDir;

          setDragState((prev) =>
            prev.dragOverPath === nextDragOverPath && prev.dragOverIsDir === nextDragOverIsDir
              ? prev
              : { ...prev, dragOverPath: nextDragOverPath, dragOverIsDir: nextDragOverIsDir },
          );
          if (nextDragOverPath) {
            scheduleAutoExpand(nextDragOverPath, nextDragOverIsDir);
          } else {
            clearAutoExpand();
          }
        } else {
          setDragState((prev) =>
            prev.dragOverPath === null
              ? prev
              : {
                  ...prev,
                  dragOverPath: null,
                  dragOverIsDir: false,
                },
          );
          clearAutoExpand();
        }
      } else if (fileTreeContainer) {
        clearEditorDropHover();
        setDragState((prev) =>
          prev.dragOverPath === "__ROOT__"
            ? prev
            : {
                ...prev,
                dragOverPath: "__ROOT__",
                dragOverIsDir: true,
              },
        );
        clearAutoExpand();
      } else if (aiContextDropTarget && dragState.draggedItem) {
        clearEditorDropHover();
        setDragState((prev) =>
          prev.dragOverPath === null
            ? prev
            : {
                ...prev,
                dragOverPath: null,
                dragOverIsDir: false,
              },
        );
        clearAutoExpand();
      } else if (editorDropTarget && dragState.draggedItem && !dragState.draggedItem.isDir) {
        setInternalTabDragHover({ x: e.clientX, y: e.clientY });
        setDragState((prev) =>
          prev.dragOverPath === null
            ? prev
            : {
                ...prev,
                dragOverPath: null,
                dragOverIsDir: false,
              },
        );
        clearAutoExpand();
      } else {
        clearEditorDropHover();
        setDragState((prev) =>
          prev.dragOverPath === null
            ? prev
            : {
                ...prev,
                dragOverPath: null,
                dragOverIsDir: false,
              },
        );
        clearAutoExpand();
      }
    };

    const handleMouseUp = async (e: MouseEvent) => {
      if (dropping.current || !isCurrentSession()) return;
      dropping.current = true;
      clearAgentDropHover();
      setDragState(initialDragState);
      clearAutoExpand();
      clearEditorDropHover();
      try {
        // Check if dropping on a pane container (outside file tree)
        const elementUnder = document.elementFromPoint(e.clientX, e.clientY);
        const isOverPane = Boolean(elementUnder?.closest("[data-pane-container]"));
        const isOverFileTree = Boolean(elementUnder?.closest(".file-tree-container"));
        const isOverAIContextDropTarget = Boolean(
          elementUnder?.closest("[data-ai-context-drop-target]"),
        );

        // A file released over the Agent composer becomes a file reference; it
        // never falls through to a move inside the tree.
        if (
          elementUnder?.closest(AGENT_DROP_TARGET_SELECTOR) &&
          dragState.draggedItems.length > 0
        ) {
          // A folder is referenced like any other dropped path, the same way the
          // macOS composer and an OS drop treat it.
          dispatchDroppedPathsToAgent(
            elementUnder,
            dragState.draggedItems.map((item) => item.path),
          );
          return;
        }

        // A terminal lives inside a pane container, so it must be resolved before
        // the pane branch below or the drop would just open the file. The terminal
        // receives raw paths because only it knows its shell, and quoting depends
        // on the shell.
        if (isTerminalDropTarget(elementUnder) && dragState.draggedItems.length > 0) {
          // Every dragged entry goes to the terminal, not just the primary one, so
          // a multi-selection inserts all of its paths.
          const paths = clipboardEntryPaths(dragState.draggedItems);
          if (dispatchTerminalPathInsert(elementUnder, paths)) {
            return;
          }
        }

        if (
          isOverAIContextDropTarget &&
          dragState.draggedItem &&
          dragState.draggedItems.length === 1
        ) {
          dispatchSidebarResourceDropOnAI({
            type: "file",
            path: dragState.draggedItem.path,
            name: dragState.draggedItem.name,
            isDir: dragState.draggedItem.isDir,
          });
          setDragState(initialDragState);
          clearAutoExpand();
          clearEditorDropHover();
          return;
        }

        // If dropping on a pane (not in file tree), dispatch event for pane to handle
        if (
          isOverPane &&
          !isOverFileTree &&
          dragState.draggedItem &&
          !dragState.draggedItem.isDir &&
          dragState.draggedItems.length === 1
        ) {
          window.dispatchEvent(
            new CustomEvent("file-tree-drop-on-pane", {
              detail: {
                path: dragState.draggedItem.path,
                name: dragState.draggedItem.name,
                isDir: dragState.draggedItem.isDir,
                x: e.clientX,
                y: e.clientY,
              },
            }),
          );
          setDragState(initialDragState);
          clearAutoExpand();
          clearEditorDropHover();
          return;
        }

        if (dragState.dragOverPath && dragState.draggedItem) {
          let targetPath = dragState.dragOverPath;

          if (targetPath === "__ROOT__") {
            targetPath = rootFolderPath || "";
            if (!targetPath) {
              setDragState(initialDragState);
              clearEditorDropHover();
              return;
            }
          }

          if (!dragState.dragOverIsDir && targetPath !== "__ROOT__") {
            targetPath = getDirName(targetPath) || rootFolderPath || "";
          }

          try {
            const entries = dragState.draggedItems.filter(
              (item) =>
                getTreePathIdentity(getDirName(item.path)) !== getTreePathIdentity(targetPath),
            );
            const names = new Set<string>();
            const existing = await readDirectory(targetPath);
            if (!isCurrentSession()) return;
            const existingPaths = new Set(
              existing.map((entry) => getTreePathIdentity(joinPath(targetPath, entry.name))),
            );
            for (const item of entries) {
              const destination = joinPath(targetPath, item.name);
              const identity = getTreePathIdentity(destination);
              if (
                identity === getTreePathIdentity(item.path) ||
                (item.isDir &&
                  pathStartsWithRoot(getTreePathIdentity(targetPath), getTreePathIdentity(item.path)))
              )
                throw new Error("Cannot move a directory into itself");
              if (names.has(identity) || existingPaths.has(identity))
                throw new Error(`Destination already contains ${item.name}`);
              names.add(identity);
            }
            for (const item of entries) {
              if (!isCurrentSession()) return;
              const destination = joinPath(targetPath, item.name);
              await moveFile(item.path, destination);
              // A successful disk move must reconcile its captured workspace owner even after unmount.
              await onFileMove?.(item.path, destination);
              if (!isCurrentSession()) return;
            }
          } catch (error) {
            console.error("Failed to move files:", error);
            if (isCurrentSession())
              onMoveError?.(error instanceof Error ? error.message : String(error));
          }
        }

        if (!isCurrentSession()) return;
        setDragState(initialDragState);
        clearAutoExpand();
        clearEditorDropHover();
      } finally {
        dropping.current = false;
      }
    };

    const cancelDrag = () => {
      setDragState(initialDragState);
      clearAutoExpand();
      clearEditorDropHover();
      clearAgentDropHover();
    };
    document.addEventListener("mousemove", handleMouseMove);
    document.addEventListener("mouseup", handleMouseUp);
    document.addEventListener("mouseleave", cancelDrag);

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
      document.removeEventListener("mouseleave", cancelDrag);
      clearAutoExpand();
      clearEditorDropHover();
      clearAgentDropHover();
    };
  }, [
    clearAgentDropHover,
    clearAutoExpand,
    clearEditorDropHover,
    dragState,
    onFileMove,
    onMoveError,
    rootFolderPath,
    scheduleAutoExpand,
    session,
  ]);

  const startDrag = useCallback(
    (e: React.MouseEvent, file: FileEntry, files: FileEntry[] = [file]) => {
      e.preventDefault();
      e.stopPropagation();

      setDragState({
        isDragging: true,
        draggedItem: { path: file.path, name: file.name, isDir: file.isDir },
        draggedItems: files,
        dragOverPath: null,
        dragOverIsDir: false,
        mousePosition: { x: e.clientX, y: e.clientY },
      });

      // Store drag data globally for pane containers to access
      window.__fileDragData = {
        path: file.path,
        name: file.name,
        isDir: file.isDir,
      };
    },
    [],
  );

  // Clean up global drag data on drag end
  useEffect(() => {
    if (!dragState.isDragging) delete window.__fileDragData;
    return () => {
      delete window.__fileDragData;
    };
  }, [dragState.isDragging]);

  return { dragState, startDrag };
}
