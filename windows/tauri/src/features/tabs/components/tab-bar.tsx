import { type DragEndEvent, type DragMoveEvent, type DragStartEvent } from "@dnd-kit/core";
import { SortableContext } from "@dnd-kit/sortable";
import {
  ArrowsOutIcon as Maximize2,
  ArrowsInIcon as Minimize2,
  PlusIcon as Plus,
  SidebarSimpleIcon as PanelLeftClose,
} from "@/ui/icons";
import { memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useJavaFileIconCacheLifecycle } from "@/extensions/icon-themes/hooks/use-java-file-icon-kind";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { MarkdownModePicker } from "@/features/editor/components/toolbar/markdown-mode-picker";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { formatDiffBufferLabel } from "@/features/git/utils/diff-buffer-label";
import { writeClipboardText } from "@/utils/clipboard";
import { BOTTOM_PANE_ID } from "@/features/panes/constants/pane";
import { getSingletonToolBufferTitleKey } from "@/features/panes/constants/tool-buffers";
import { usePaneStore } from "@/features/panes/stores/pane.store";
import { activateBufferInPaneAndSync } from "@/features/panes/utils/pane-activation";
import { splitEditorGroup } from "@/features/panes/utils/pane-command-actions";
import { moveBufferToPaneDropTarget } from "@/features/panes/utils/pane-drop-actions";
import { findPaneGroup } from "@/features/panes/utils/pane-tree";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { getChromeNavigationIndex } from "@/features/layout/utils/chrome-keyboard";
import { useSidebarStore } from "@/features/layout/stores/sidebar.store";
import { useTerminalStore } from "@/features/terminal/stores/terminal.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { Button } from "@/ui/button";
import { ContextMenu, ContextMenuTrigger } from "@/ui/context-menu";
import { SortableTab, TabBarSurface, TabDndContext, useTabDragClickGuard } from "@/ui/tab-bar";
import { cn } from "@/utils/cn";
import { getRelativePath } from "@/utils/path-helpers";
import { useTabWheelScroll } from "../hooks/use-tab-wheel-scroll";
import { getTabStripLayout } from "../utils/tab-strip-layout";
import { calculateDisplayNames } from "../utils/path-shortener";
import {
  clearInternalTabDragData,
  resolveDropTarget,
  setInternalTabDragHover,
  setInternalTabDragData,
} from "../utils/internal-tab-drag";
import TabBarItem from "./tab-bar-item";
import TabContextMenu from "./tab-context-menu";
import { tabChromeBuffersEqual, toTabChromeBuffer } from "../utils/tab-chrome-buffer";
import { markTabActivated, orderTabsForClosing } from "../utils/tab-recency";

interface TabBarProps {
  paneId?: string;
  /** Whether focus is inside this tab group; an unfocused group greys its selected tab. */
  isGroupActive?: boolean;
  onTabClick?: (bufferId: string) => void;
  disablePaneActions?: boolean;
}

const TabBar = ({
  paneId,
  isGroupActive = true,
  onTabClick: externalTabClick,
  disablePaneActions = false,
}: TabBarProps) => {
  useJavaFileIconCacheLifecycle();
  const { t } = useTranslation();
  // Get everything from stores
  const paneRoot = usePaneStore.use.root();
  const bottomRoot = usePaneStore.use.bottomRoot();
  const fullscreenPaneId = usePaneStore.use.fullscreenPaneId();
  const { closePane, setActivePane, togglePaneFullscreen, setPaneLocked } =
    usePaneStore.use.actions();

  const pane = useMemo(() => {
    if (!paneId) return null;
    return paneId === BOTTOM_PANE_ID
      ? findPaneGroup(bottomRoot, BOTTOM_PANE_ID)
      : findPaneGroup(paneRoot, paneId);
  }, [bottomRoot, paneId, paneRoot]);
  const paneBufferIdSet = useMemo(() => {
    return pane ? new Set(pane.bufferIds) : null;
  }, [pane?.bufferIds]);
  const buffers = useBufferStore(
    (state) => {
      const visibleBuffers = paneBufferIdSet
        ? state.buffers.filter((buffer) => paneBufferIdSet.has(buffer.id))
        : state.buffers;
      return visibleBuffers.map(toTabChromeBuffer);
    },
    tabChromeBuffersEqual,
  );
  const globalActiveBufferId = useBufferStore((state) => (pane ? null : state.activeBufferId));
  const activeBufferCandidate = pane ? pane.activeBufferId : globalActiveBufferId;
  const {
    handleTabClick,
    handleTabClose,
    handleTabPin,
    handleCloseOtherTabs,
    handleCloseSavedTabs,
    handleCloseAllTabs,
    handleCloseTabsToRight,
    reorderBuffers,
    convertPreviewToDefinite,
    showNewTabView,
  } = useBufferStore.use.actions();
  const maxOpenTabs = useSettingsStore((state) => state.settings.maxOpenTabs);
  const tabLimitPolicy = useSettingsStore((state) => state.settings.tabLimitPolicy);
  const tabStripLayout = getTabStripLayout(
    useSettingsStore((state) => state.settings.editorTabLayoutMode),
  );
  const updateActivePath = useSidebarStore.use.actions().updateActivePath;
  const rootFolderPath = useFileSystemStore.use.rootFolderPath?.() || undefined;
  const bufferById = useMemo(() => {
    const nextBufferById = new Map<string, PaneContent>();
    for (const buffer of buffers) {
      nextBufferById.set(buffer.id, buffer);
    }
    return nextBufferById;
  }, [buffers]);
  const activeBufferId =
    activeBufferCandidate && bufferById.has(activeBufferCandidate) ? activeBufferCandidate : null;
  const activeBuffer = activeBufferId ? (bufferById.get(activeBufferId) ?? null) : null;
  const isPaneFullscreen = paneId ? fullscreenPaneId === paneId : false;
  const isPaneLocked = Boolean(pane?.locked);
  const isInSplit = paneRoot.type === "split";
  const isBottomPane = paneId === BOTTOM_PANE_ID;

  const [draggedBufferId, setDraggedBufferId] = useState<string | null>(null);
  const [editingBufferId, setEditingBufferId] = useState<string | null>(null);
  const [contextMenuBufferId, setContextMenuBufferId] = useState<string | null>(null);
  const [editingName, setEditingName] = useState("");

  const [srAnnouncement, setSrAnnouncement] = useState<string>("");

  const tabBarRef = useRef<HTMLDivElement>(null);
  const tabScrollRef = useRef<HTMLDivElement>(null);
  const tabRefs = useRef<(HTMLDivElement | null)[]>([]);
  const dragPointRef = useRef<{ x: number; y: number } | null>(null);
  const pointerPointRef = useRef<{ x: number; y: number } | null>(null);
  const { getClickCapture, releaseClickSuppression, suppressNextClick } = useTabDragClickGuard();
  const handleRevealInFolder = useFileSystemStore.use.handleRevealInFolder?.();
  const { clearPositionCache } = useEditorStateStore.getState().actions;
  const terminalSessions = useTerminalStore((state) => state.sessions);
  const getDirectoryLabel = useCallback((directory?: string) => {
    if (!directory) return "";
    const normalized = directory.replace(/[\\/]+$/, "");
    return normalized.split(/[\\/]/).pop() || directory;
  }, []);

  const getCommandLabel = useCallback((command?: string) => {
    if (!command) return "";
    const firstSegment = command.trim().split(/\s+/)[0];
    return firstSegment?.split(/[\\/]/).pop() || "";
  }, []);

  const isUsefulTerminalTitle = useCallback((title?: string) => {
    if (!title) return false;
    const trimmed = title.trim();
    if (!trimmed || trimmed === "Default Terminal") return false;
    if (trimmed.length > 28) return false;
    if (trimmed.includes("@")) return false;
    if (trimmed.includes("/") || trimmed.includes("\\")) return false;

    for (const char of trimmed) {
      const code = char.charCodeAt(0);
      if ((code >= 0 && code <= 31) || code === 127 || code === 155) {
        return false;
      }
    }

    return true;
  }, []);

  const handleShowNewTab = useCallback(() => {
    if (!paneId) return;
    setActivePane(paneId);
    showNewTabView();
  }, [paneId, setActivePane, showNewTabView]);

  const handleTogglePaneFullscreen = useCallback(() => {
    if (!paneId) return;
    togglePaneFullscreen(paneId);
  }, [paneId, togglePaneFullscreen]);

  const handleTogglePaneLocked = useCallback(() => {
    if (!paneId) return;
    setPaneLocked(paneId, !isPaneLocked);
  }, [isPaneLocked, paneId, setPaneLocked]);

  useTabWheelScroll(tabScrollRef, tabStripLayout.scrollsHorizontally && !draggedBufferId);

  const sortedBuffers = useMemo(() => {
    const pinnedBuffers: PaneContent[] = [];
    const unpinnedBuffers: PaneContent[] = [];

    for (const buffer of buffers) {
      if (buffer.isPinned) {
        pinnedBuffers.push(buffer);
      } else {
        unpinnedBuffers.push(buffer);
      }
    }

    if (pinnedBuffers.length === 0) return unpinnedBuffers;
    if (unpinnedBuffers.length === 0) return pinnedBuffers;
    return [...pinnedBuffers, ...unpinnedBuffers];
  }, [buffers]);
  const { sortedBufferIds, sortedBufferIndexById } = useMemo(() => {
    const ids: string[] = [];
    const indexById = new Map<string, number>();

    for (let index = 0; index < sortedBuffers.length; index++) {
      const buffer = sortedBuffers[index];
      ids.push(buffer.id);
      indexById.set(buffer.id, index);
    }

    return { sortedBufferIds: ids, sortedBufferIndexById: indexById };
  }, [sortedBuffers]);
  // Calculate display names for tabs with minimal distinguishing paths
  const displayNames = useMemo(() => {
    return calculateDisplayNames(buffers, rootFolderPath);
  }, [buffers, rootFolderPath]);

  const getBufferDisplayName = useCallback(
    (buffer: PaneContent) => {
      if (buffer.type === "terminal") {
        const session = terminalSessions.get(buffer.sessionId);
        if (session?.customName) {
          return session.name?.trim() || buffer.name;
        }

        const title = session?.title?.trim();
        if (isUsefulTerminalTitle(title)) return title!;

        const commandLabel = getCommandLabel(buffer.initialCommand);
        if (commandLabel) return commandLabel;

        const dirLabel = getDirectoryLabel(session?.currentDirectory || buffer.workingDirectory);
        if (dirLabel) return dirLabel;
      }

      const singletonTitleKey = getSingletonToolBufferTitleKey(buffer.type);
      if (singletonTitleKey) return t(singletonTitleKey);

      if (buffer.type === "diff") {
        return formatDiffBufferLabel(
          displayNames.get(buffer.id) || buffer.name,
          buffer.path,
          t,
          buffer.diffData,
        );
      }

      return displayNames.get(buffer.id) ?? buffer.name;
    },
    [displayNames, getCommandLabel, getDirectoryLabel, isUsefulTerminalTitle, t, terminalSessions],
  );

  useEffect(() => {
    if (activeBufferId) markTabActivated(activeBufferId);
  }, [activeBufferId]);

  useEffect(() => {
    if (maxOpenTabs > 0 && buffers.length > maxOpenTabs && handleTabClose) {
      const closableBuffers = orderTabsForClosing(
        buffers.filter(
          (b) => !b.isPinned && b.id !== activeBufferId && !(b.type === "editor" && b.isDirty),
        ),
        tabLimitPolicy,
      );

      let tabsToClose = buffers.length - maxOpenTabs;
      for (let i = 0; i < closableBuffers.length && tabsToClose > 0; i++) {
        handleTabClose(closableBuffers[i].id);
        tabsToClose--;
      }
    }
  }, [buffers, maxOpenTabs, tabLimitPolicy, activeBufferId, handleTabClose]);

  // Auto-scroll active tab into view
  useEffect(() => {
    if (!tabStripLayout.scrollsHorizontally) return;
    const activeIndex = activeBufferId ? (sortedBufferIndexById.get(activeBufferId) ?? -1) : -1;
    if (activeIndex !== -1 && tabRefs.current[activeIndex] && tabScrollRef.current) {
      const activeTab = tabRefs.current[activeIndex];
      const container = tabScrollRef.current;

      if (activeTab) {
        const tabRect = activeTab.getBoundingClientRect();
        const containerRect = container.getBoundingClientRect();

        // Check if tab is out of view
        if (tabRect.left < containerRect.left || tabRect.right > containerRect.right) {
          activeTab.scrollIntoView({
            behavior: "smooth",
            block: "nearest",
            inline: "center",
          });
        }
      }
    }
  }, [activeBufferId, sortedBufferIndexById, tabStripLayout.scrollsHorizontally]);

  const handleDoubleClick = useCallback(
    (e: React.MouseEvent, index: number) => {
      e.preventDefault();
      e.stopPropagation();
      const buffer = sortedBuffers[index];
      // Convert preview tab to definite on double-click
      if (buffer.isPreview) {
        convertPreviewToDefinite(buffer.id);
      }
    },
    [sortedBuffers, convertPreviewToDefinite],
  );

  const handleCopyPath = useCallback(async (path: string) => {
    await writeClipboardText(path);
  }, []);

  const handleCopyRelativePath = useCallback(
    async (path: string) => {
      if (!rootFolderPath) {
        // If no project is open, copy the full path
        await writeClipboardText(path);
        return;
      }

      await writeClipboardText(getRelativePath(path, rootFolderPath));
    },
    [rootFolderPath],
  );

  const closeTab = useCallback(
    (bufferId: string) => {
      handleTabClose(bufferId);
      clearPositionCache(bufferId);
    },
    [clearPositionCache, handleTabClose],
  );

  const cancelRename = useCallback(() => {
    setEditingBufferId(null);
    setEditingName("");
  }, []);

  const commitRename = useCallback(
    (nextName: string) => {
      if (!editingBufferId) return;
      const buffer = bufferById.get(editingBufferId);
      if (!buffer || buffer.type !== "terminal") {
        cancelRename();
        return;
      }

      useTerminalStore.getState().actions.updateSession(buffer.sessionId, {
        name: nextName,
        customName: true,
      });
      useBufferStore.getState().actions.updateBuffer({ ...buffer, name: nextName });
      cancelRename();
    },
    [bufferById, cancelRename, editingBufferId],
  );

  const handleTabSelect = useCallback(
    (buffer: PaneContent) => {
      const displayName = getBufferDisplayName(buffer);
      if (externalTabClick) {
        externalTabClick(buffer.id);
      } else {
        handleTabClick(buffer.id);
      }
      updateActivePath(buffer.path);
      setSrAnnouncement(
        t("tabs.switchedTo", {
          name: displayName,
          unsaved: buffer.type === "editor" && buffer.isDirty ? t("tabs.announcementUnsaved") : "",
        }),
      );
    },
    [externalTabClick, getBufferDisplayName, handleTabClick, t, updateActivePath],
  );

  const startRename = useCallback(
    (bufferId: string) => {
      const buffer = bufferById.get(bufferId);
      if (!buffer || buffer.type !== "terminal") return;

      handleTabSelect(buffer);
      requestAnimationFrame(() => {
        setEditingBufferId(bufferId);
        setEditingName(buffer.name);
      });
    },
    [bufferById, handleTabSelect],
  );

  const getClientPoint = (event: Event) => {
    const candidate = event as Partial<MouseEvent>;
    if (typeof candidate.clientX === "number" && typeof candidate.clientY === "number") {
      return { x: candidate.clientX, y: candidate.clientY };
    }
    return null;
  };

  const getDragPoint = (event: DragMoveEvent | DragEndEvent) => {
    if (pointerPointRef.current) return pointerPointRef.current;

    const rect = event.active.rect.current.translated ?? event.active.rect.current.initial;
    if (!rect) return dragPointRef.current;
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
    };
  };

  const isPointOutsideTabBar = (point: { x: number; y: number }) => {
    const rect = tabBarRef.current?.getBoundingClientRect();
    if (!rect) return false;

    const horizontalSlop = 24;
    const verticalSlop = 64;
    return (
      point.x < rect.left - horizontalSlop ||
      point.x > rect.right + horizontalSlop ||
      point.y < rect.top - verticalSlop ||
      point.y > rect.bottom + verticalSlop
    );
  };

  const handleDragStart = useCallback(
    (event: DragStartEvent) => {
      const buffer = bufferById.get(String(event.active.id));
      if (!buffer) return;

      setDraggedBufferId(buffer.id);
      pointerPointRef.current = getClientPoint(event.activatorEvent);
      setInternalTabDragData({
        source: "pane",
        bufferId: buffer.id,
        paneId,
      });
      suppressNextClick(buffer.id);
    },
    [bufferById, paneId, suppressNextClick],
  );

  const handleDragMove = useCallback((event: DragMoveEvent) => {
    const point = getDragPoint(event);
    if (!point) return;

    dragPointRef.current = point;
    if (isPointOutsideTabBar(point)) {
      setInternalTabDragHover(point);
    }
  }, []);

  const resetDrag = useCallback(() => {
    setDraggedBufferId(null);
    dragPointRef.current = null;
    pointerPointRef.current = null;
    clearInternalTabDragData();
    releaseClickSuppression();
  }, [releaseClickSuppression]);

  useEffect(() => {
    if (!draggedBufferId) return;

    const updatePointerPoint = (event: PointerEvent) => {
      pointerPointRef.current = { x: event.clientX, y: event.clientY };
    };

    window.addEventListener("pointermove", updatePointerPoint, true);
    return () => window.removeEventListener("pointermove", updatePointerPoint, true);
  }, [draggedBufferId]);

  const handleDragEnd = useCallback(
    (event: DragEndEvent) => {
      const activeId = String(event.active.id);
      const dragged = bufferById.get(activeId);
      const point = getDragPoint(event);
      const target = point ? resolveDropTarget(point) : { paneId: null, zone: null };
      const isOutsideTabBar = point ? isPointOutsideTabBar(point) : false;

      if (
        dragged &&
        paneId &&
        isOutsideTabBar &&
        target.paneId &&
        (target.paneId !== paneId || (target.zone && target.zone !== "center"))
      ) {
        const preserveEmptySource = target.paneId === paneId;
        const destinationPaneId = moveBufferToPaneDropTarget(
          dragged.id,
          paneId,
          { paneId: target.paneId, zone: target.zone },
          preserveEmptySource,
        );
        if (!destinationPaneId) {
          resetDrag();
          return;
        }
        activateBufferInPaneAndSync(destinationPaneId, dragged.id);
        if (destinationPaneId === BOTTOM_PANE_ID) {
          useUIState.getState().setBottomPaneActiveTab("buffers");
          useUIState.getState().setIsBottomPaneVisible(true);
        }
      } else if (event.over && reorderBuffers) {
        const oldIndex = sortedBufferIndexById.get(activeId) ?? -1;
        const newIndex = sortedBufferIndexById.get(String(event.over.id)) ?? -1;
        if (oldIndex !== -1 && newIndex !== -1 && oldIndex !== newIndex) {
          reorderBuffers(oldIndex, newIndex);
        }
      }

      resetDrag();
    },
    [bufferById, paneId, reorderBuffers, resetDrag, sortedBufferIndexById],
  );

  useEffect(() => {
    tabRefs.current = tabRefs.current.slice(0, sortedBuffers.length);
  }, [sortedBuffers.length]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent, index: number) => {
      const buffer = sortedBuffers[index];
      const nextIndex = getChromeNavigationIndex(e.key, index, sortedBuffers.length, "horizontal");

      if (nextIndex !== null) {
        e.preventDefault();
        const nextBuffer = sortedBuffers[nextIndex];
        if (nextBuffer && nextIndex !== index) {
          handleTabClick(nextBuffer.id);
          updateActivePath(nextBuffer.path);
          setSrAnnouncement(
            t("tabs.switchedTo", {
              name: getBufferDisplayName(nextBuffer),
              unsaved:
                nextBuffer.type === "editor" && nextBuffer.isDirty
                  ? t("tabs.announcementUnsaved")
                  : "",
            }),
          );
          tabRefs.current[nextIndex]?.focus();
        }
        return;
      }

      switch (e.key) {
        case "Delete":
        case "Backspace":
          if (!buffer.isPinned) {
            e.preventDefault();
            setSrAnnouncement(t("tabs.closed", { name: getBufferDisplayName(buffer) }));
            closeTab(buffer.id);
          } else {
            setSrAnnouncement(t("tabs.cannotClosePinned", { name: getBufferDisplayName(buffer) }));
          }
          break;

        case "Enter":
        case " ":
          e.preventDefault();
          handleTabClick(buffer.id);
          updateActivePath(buffer.path);
          setSrAnnouncement(
            t("tabs.activated", {
              name: getBufferDisplayName(buffer),
              unsaved:
                buffer.type === "editor" && buffer.isDirty ? t("tabs.announcementUnsaved") : "",
            }),
          );
          break;
      }
    },
    [sortedBuffers, getBufferDisplayName, handleTabClick, t, updateActivePath, closeTab],
  );


  // Only the tab whose menu is open builds one: building a tab menu is not free.
  const renderTabContextMenu = (buffer: PaneContent) => (
    <TabContextMenu
    buffer={buffer}
    paneId={paneId}
    onPin={handleTabPin}
    onRename={startRename}
    onCloseTab={(bufferId) => {
      const targetBuffer = bufferById.get(bufferId);
      if (targetBuffer) closeTab(bufferId);
    }}
    onCloseOthers={handleCloseOtherTabs}
    onCloseSaved={handleCloseSavedTabs}
    onCloseAll={handleCloseAllTabs}
    onCloseToRight={handleCloseTabsToRight}
    isPaneLocked={isPaneLocked}
    onTogglePaneLocked={
      paneId && !disablePaneActions && !isBottomPane
        ? handleTogglePaneLocked
        : undefined
    }
    onCopyPath={handleCopyPath}
    onCopyRelativePath={handleCopyRelativePath}
    onReload={(bufferId) => {
      const targetBuffer = bufferById.get(bufferId);
      if (targetBuffer && targetBuffer.path !== "extensions://marketplace") {
        const { closeBuffer, openBuffer } = useBufferStore.getState().actions;
        closeBuffer(bufferId);
        setTimeout(async () => {
          try {
            const content =
              targetBuffer.type === "editor" || targetBuffer.type === "diff"
                ? targetBuffer.content
                : "";
            openBuffer(
              targetBuffer.path,
              targetBuffer.name,
              content,
              targetBuffer.type === "image",
              targetBuffer.type === "diff",
            );
          } catch (error) {
            console.error("Failed to reload buffer:", error);
          }
        }, 100);
      }
    }}
    onRevealInFinder={handleRevealInFolder}
    onSplitRight={
      paneId
        ? (targetPaneId, bufferId) => {
            splitEditorGroup(targetPaneId, "horizontal", bufferId);
          }
        : undefined
    }
    onSplitDown={
      paneId
        ? (targetPaneId, bufferId) => {
            splitEditorGroup(targetPaneId, "vertical", bufferId);
          }
        : undefined
    }
  />
  );

  // Tab entries are memoized, so they get one stable set of actions that
  // always calls the latest handlers. Inline callbacks made every tab, with
  // its tooltip and context-menu roots, re-render whenever a file opened.
  const tabStripActionsRef = useRef({
    handleTabSelect,
    handleDoubleClick,
    handleKeyDown,
    closeTab,
    handleTabPin,
    setEditingName,
    commitRename,
    cancelRename,
    getClickCapture,
  });
  tabStripActionsRef.current = {
    handleTabSelect,
    handleDoubleClick,
    handleKeyDown,
    closeTab,
    handleTabPin,
    setEditingName,
    commitRename,
    cancelRename,
    getClickCapture,
  };
  const tabStripActions = useMemo<TabStripActions>(
    () => ({
      select: (buffer) => tabStripActionsRef.current.handleTabSelect(buffer),
      doubleClick: (event, index) => tabStripActionsRef.current.handleDoubleClick(event, index),
      keyDown: (event, index) => tabStripActionsRef.current.handleKeyDown(event, index),
      close: (bufferId) => tabStripActionsRef.current.closeTab(bufferId),
      pin: (bufferId) => tabStripActionsRef.current.handleTabPin(bufferId),
      editingNameChange: (value) => tabStripActionsRef.current.setEditingName(value),
      renameSubmit: (value) => tabStripActionsRef.current.commitRename(value),
      renameCancel: () => tabStripActionsRef.current.cancelRename(),
      clickCapture: (bufferId, event) =>
        tabStripActionsRef.current.getClickCapture(bufferId)?.(event),
      setTabRef: (index, element) => {
        tabRefs.current[index] = element;
      },
      menuOpenChange: (bufferId, open) => {
        if (open) setContextMenuBufferId(bufferId);
      },
      menuOpenChangeComplete: (bufferId, open) => {
        if (!open) {
          setContextMenuBufferId((current) => (current === bufferId ? null : current));
        }
      },
    }),
    [],
  );

  return (
    <>
      <TabDndContext
        modifiers={tabStripLayout.dragModifiers}
        onDragStart={handleDragStart}
        onDragMove={handleDragMove}
        onDragEnd={handleDragEnd}
        onDragCancel={resetDrag}
      >
        <TabBarSurface
          ref={tabBarRef}
          data-tab-bar-pane-id={paneId ?? ""}
          className={cn(
            "group/tabbar scrollbar-hidden bg-background overscroll-x-contain",
            tabStripLayout.wrapsTabs && "h-auto items-start py-1",
          )}
          role="tablist"
          aria-label={t("tabs.openFiles")}
        >
          <SortableContext items={sortedBufferIds} strategy={tabStripLayout.sortingStrategy}>
            <div
              ref={tabScrollRef}
              className={cn(
                "flex min-w-0 flex-1 items-center gap-2",
                tabStripLayout.wrapsTabs
                  ? "flex-wrap"
                  : "scrollbar-hidden overflow-x-auto overflow-y-hidden overscroll-x-contain",
              )}
            >
              {sortedBuffers.map((buffer, index) => (
                <TabStripEntry
                  key={buffer.id}
                  buffer={buffer}
                  displayName={getBufferDisplayName(buffer)}
                  index={index}
                  isActive={buffer.id === activeBufferId}
                  isGroupActive={isGroupActive}
                  isWrapped={tabStripLayout.wrapsTabs}
                  sortableClassName={tabStripLayout.sortableTabClassName}
                  isEditing={editingBufferId === buffer.id}
                  editingName={editingBufferId === buffer.id ? editingName : ""}
                  contextMenu={
                    contextMenuBufferId === buffer.id ? renderTabContextMenu(buffer) : null
                  }
                  actions={tabStripActions}
                />
              ))}
            </div>
          </SortableContext>

          <div
            className={cn(
              "flex shrink-0 items-center gap-1 pl-0.5",
              tabStripLayout.wrapsTabs ? "h-(--lithe-tab-height)" : "h-8",
            )}
          >
            {activeBuffer?.type === "editor" && (
              <MarkdownModePicker bufferId={activeBufferId ?? undefined} />
            )}
            {paneId && !isBottomPane && (
              <Button
                type="button"
                onClick={handleShowNewTab}
                variant="ghost"
                size="icon-xs"
                className={cn(
                  "opacity-0 transition-opacity",
                  "pointer-events-none group-focus-within/tabbar:pointer-events-auto group-hover/tabbar:pointer-events-auto",
                  "group-focus-within/tabbar:opacity-100 group-hover/tabbar:opacity-100 focus-visible:opacity-100",
                )}
                tooltip={t("tabs.newTab")}
                tooltipSide="bottom"
                aria-label={t("tabs.newTab")}
              >
                <Plus weight="bold" />
              </Button>
            )}
            {paneId && !disablePaneActions && !isBottomPane && isInSplit && (
              <Button
                type="button"
                onClick={() => closePane(paneId)}
                variant="ghost"
                size="icon-xs"
                tooltip={t("tabs.closeSplit")}
                tooltipSide="bottom"
                aria-label={t("tabs.closeSplitPane")}
              >
                <PanelLeftClose />
              </Button>
            )}
            {paneId && !disablePaneActions && !isBottomPane && (
              <Button
                type="button"
                onClick={handleTogglePaneFullscreen}
                variant="ghost"
                className={cn(
                  "opacity-0 transition-opacity",
                  "pointer-events-none group-focus-within/tabbar:pointer-events-auto group-hover/tabbar:pointer-events-auto",
                  "group-focus-within/tabbar:opacity-100 group-hover/tabbar:opacity-100 focus-visible:opacity-100",
                )}
                tooltip={isPaneFullscreen ? t("tabs.exitFullScreen") : t("tabs.fullScreenEditor")}
                tooltipSide="bottom"
                aria-label={t("tabs.toggleEditorFullScreen")}
                size="icon-xs"
              >
                {isPaneFullscreen ? <Minimize2 /> : <Maximize2 />}
              </Button>
            )}
          </div>
        </TabBarSurface>
      </TabDndContext>

      {/* Screen reader live region for announcements */}
      <div role="status" aria-live="polite" aria-atomic="true" className="sr-only">
        {srAnnouncement}
      </div>
    </>
  );
};

export default TabBar;

interface TabStripActions {
  select: (buffer: PaneContent) => void;
  doubleClick: (event: React.MouseEvent, index: number) => void;
  keyDown: (event: React.KeyboardEvent, index: number) => void;
  close: (bufferId: string) => void;
  pin: (bufferId: string) => void;
  editingNameChange: (value: string) => void;
  renameSubmit: (value: string) => void;
  renameCancel: () => void;
  clickCapture: (bufferId: string, event: React.MouseEvent<HTMLDivElement>) => void;
  setTabRef: (index: number, element: HTMLDivElement | null) => void;
  menuOpenChange: (bufferId: string, open: boolean) => void;
  menuOpenChangeComplete: (bufferId: string, open: boolean) => void;
}

interface TabStripEntryProps {
  buffer: PaneContent;
  displayName: string;
  index: number;
  isActive: boolean;
  isGroupActive?: boolean;
  isWrapped: boolean;
  sortableClassName?: string;
  isEditing: boolean;
  editingName: string;
  contextMenu: ReactNode;
  actions: TabStripActions;
}

/** One tab with its drag handle and context menu; re-renders only when its own props change. */
const TabStripEntry = memo(function TabStripEntry({
  buffer,
  displayName,
  index,
  isActive,
  isGroupActive,
  isWrapped,
  sortableClassName,
  isEditing,
  editingName,
  contextMenu,
  actions,
}: TabStripEntryProps) {
  const bufferId = buffer.id;
  const tabRef = useCallback(
    (element: HTMLDivElement | null) => actions.setTabRef(index, element),
    [actions, index],
  );
  const onClickCapture = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => actions.clickCapture(bufferId, event),
    [actions, bufferId],
  );
  const onClick = useCallback(() => actions.select(buffer), [actions, buffer]);
  const onDoubleClick = useCallback(
    (event: React.MouseEvent) => actions.doubleClick(event, index),
    [actions, index],
  );
  const onKeyDown = useCallback(
    (event: React.KeyboardEvent) => actions.keyDown(event, index),
    [actions, index],
  );
  const onOpenChange = useCallback(
    (open: boolean) => actions.menuOpenChange(bufferId, open),
    [actions, bufferId],
  );
  const onOpenChangeComplete = useCallback(
    (open: boolean) => actions.menuOpenChangeComplete(bufferId, open),
    [actions, bufferId],
  );

  return (
    <SortableTab
      id={bufferId}
      tabRef={tabRef}
      disabled={isEditing}
      className={sortableClassName}
      onClickCapture={onClickCapture}
    >
      {({ isDragging }) => (
        <ContextMenu onOpenChange={onOpenChange} onOpenChangeComplete={onOpenChangeComplete}>
          <ContextMenuTrigger className="contents">
            <TabBarItem
              buffer={buffer}
              displayName={displayName}
              index={index}
              isActive={isActive}
              isGroupActive={isGroupActive}
              isDraggedTab={isDragging}
              isWrapped={isWrapped}
              onClick={onClick}
              onDoubleClick={onDoubleClick}
              onKeyDown={onKeyDown}
              handleTabClose={actions.close}
              handleTabPin={actions.pin}
              isEditing={isEditing}
              editingName={editingName}
              onEditingNameChange={actions.editingNameChange}
              onRenameSubmit={actions.renameSubmit}
              onRenameCancel={actions.renameCancel}
            />
          </ContextMenuTrigger>
          {contextMenu}
        </ContextMenu>
      )}
    </SortableTab>
  );
});
