import type React from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { isBackendCapabilityAvailable } from "@/config/backend-capabilities";
import DebuggerView from "@/features/debugger/components/debugger-view";
import DiagnosticsBuffer from "@/features/diagnostics/components/diagnostics-buffer";
import MavenRunPane from "@/features/maven/components/maven-run-pane";
import BuildOutputPane from "@/features/build/components/build-output-pane";
import RunPane from "@/features/run/components/run-pane";
import SpringEndpointsPane from "@/features/spring/components/spring-endpoints-pane";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useTranslation } from "@/i18n/locale-provider";
import { GitLogToolWindow } from "@/features/git/components/log/git-log-tool-window";
import { BOTTOM_PANE_ID } from "@/features/panes/constants/pane";
import { usePaneStore } from "@/features/panes/stores/pane.store";
import { activateBufferInPaneAndSync } from "@/features/panes/utils/pane-activation";
import { getAllPaneGroups } from "@/features/panes/utils/pane-tree";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import {
  clearInternalTabDragData,
  getInternalTabDragData,
  getInternalTabDragHover,
} from "@/features/tabs/utils/internal-tab-drag";
import TerminalContainer from "@/features/terminal/components/terminal-container";
import { cn } from "@/utils/cn";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { WorkbenchFullscreenSurface } from "@/features/window/components/workbench-fullscreen-surface";
import {
  startDocumentResizeSession,
  type DocumentResizeSession,
} from "@/utils/document-resize-session";
import { useTerminalDock } from "../terminal-dock-layout";
import { BottomBufferPane } from "./bottom-buffer-pane";

const BottomPane = () => {
  const { t } = useTranslation();
  const isBottomPaneVisible = useUIState((state) => state.isBottomPaneVisible);
  const bottomPaneActiveTab = useUIState((state) => state.bottomPaneActiveTab);
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const terminalEnabled = useSettingsStore((state) => state.settings.coreFeatures.terminal);
  const debuggerEnabled = useSettingsStore((state) => state.settings.coreFeatures.debugger);
  const bottomRoot = usePaneStore.use.bottomRoot();
  const bottomPaneBufferIds = useMemo(() => {
    const bufferIds: string[] = [];
    for (const pane of getAllPaneGroups(bottomRoot)) {
      for (const bufferId of pane.bufferIds) {
        bufferIds.push(bufferId);
      }
    }
    return bufferIds;
  }, [bottomRoot]);
  const { moveBufferToPane } = usePaneStore.use.actions();
  const { openTerminalBuffer } = useBufferStore.use.actions();
  const [height, setHeight] = useState(320);
  const dock = useTerminalDock();
  const isRightDocked = dock?.position === "right";
  const isLeftDocked = dock?.position === "left";
  const isSideDocked = isRightDocked || isLeftDocked;
  const paneHeight = dock?.height ?? height;
  const resizeSession = useRef<DocumentResizeSession | null>(null);
  const [isResizing, setIsResizing] = useState(false);
  const [isFullScreen, setIsFullScreen] = useState(false);
  const [isInternalHoverTarget, setIsInternalHoverTarget] = useState(false);
  const paneFrameRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const syncHover = () => {
      setIsInternalHoverTarget(getInternalTabDragHover().paneId === BOTTOM_PANE_ID);
    };

    window.addEventListener("lithe-internal-tab-drag-hover", syncHover);
    return () => window.removeEventListener("lithe-internal-tab-drag-hover", syncHover);
  }, []);

  useEffect(() => {
    if (isBottomPaneVisible && bottomPaneActiveTab === "references") {
      useUIState.getState().setIsBottomPaneVisible(false);
    }
  }, [bottomPaneActiveTab, isBottomPaneVisible]);

  useEffect(() => {
    if (
      isBottomPaneVisible &&
      bottomPaneActiveTab === "debugger" &&
      (!debuggerEnabled || !isBackendCapabilityAvailable("debugger"))
    ) {
      useUIState.getState().setIsBottomPaneVisible(false);
    }
  }, [bottomPaneActiveTab, isBottomPaneVisible, debuggerEnabled]);

  useEffect(() => {
    if (
      isBottomPaneVisible &&
      bottomPaneActiveTab === "terminal" &&
      (!terminalEnabled || !isBackendCapabilityAvailable("terminal"))
    ) {
      useUIState.getState().setIsBottomPaneVisible(false);
    }
  }, [bottomPaneActiveTab, isBottomPaneVisible, terminalEnabled]);

  useEffect(() => {
    if (
      isBottomPaneVisible &&
      bottomPaneActiveTab === "run" &&
      !isBackendCapabilityAvailable("run")
    ) {
      useUIState.getState().setIsBottomPaneVisible(false);
    }
  }, [bottomPaneActiveTab, isBottomPaneVisible]);

  useEffect(() => {
    if (
      isBottomPaneVisible &&
      bottomPaneActiveTab === "buffers" &&
      bottomPaneBufferIds.length === 0
    ) {
      useUIState.getState().setIsBottomPaneVisible(false);
    }
  }, [bottomPaneActiveTab, bottomPaneBufferIds.length, isBottomPaneVisible]);

  useEffect(() => {
    const frame = paneFrameRef.current;
    if (frame) {
      frame.style.height = isSideDocked
        ? "100%"
        : `calc(${paneHeight}px + var(--lithe-bottom-pane-gap))`;
      frame.style.width = isSideDocked ? `calc(${dock!.width}px + var(--lithe-workbench-gap))` : "";
    }
    return () => resizeSession.current?.dispose({ commit: false });
  }, [
    rootFolderPath,
    dock?.position,
    isSideDocked,
    isFullScreen,
    isBottomPaneVisible,
    dock?.width,
    paneHeight,
  ]);

  const handlePointerDown = (event: React.PointerEvent) => {
    if (event.button !== 0) return;
    event.preventDefault();
    resizeSession.current?.dispose({ commit: false });
    const frame = paneFrameRef.current!;
    const applySize = (size: number) => {
      if (isSideDocked) frame.style.width = `calc(${size}px + var(--lithe-workbench-gap))`;
      else frame.style.height = `calc(${size}px + var(--lithe-bottom-pane-gap))`;
    };
    resizeSession.current = startDocumentResizeSession({
      startX: isSideDocked ? event.clientX : event.clientY,
      startWidth: isSideDocked ? dock!.width : paneHeight,
      direction: isLeftDocked ? 1 : -1,
      axis: isSideDocked ? "x" : "y",
      cursor: isSideDocked ? "ew-resize" : "ns-resize",
      clampWidth: isSideDocked
        ? dock!.clampWidth
        : (dock?.clampHeight ??
          ((value) => Math.min(Math.max(value, 200), window.innerHeight * 0.8))),
      applyWidth: applySize,
      commitWidth: (size) => {
        applySize(size);
        if (dock) dock.resize(size);
        else setHeight(size);
      },
      onActiveChange: setIsResizing,
    });
  };

  const handleDragOver = useCallback((e: React.DragEvent<HTMLDivElement>) => {
    if (!e.dataTransfer.types.includes("application/tab-data") && !getInternalTabDragData()) {
      return;
    }
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
  }, []);

  const handleDrop = useCallback(
    (e: React.DragEvent<HTMLDivElement>) => {
      const tabDataString = e.dataTransfer.getData("application/tab-data");
      const fallbackTabData = getInternalTabDragData();
      if (!tabDataString && !fallbackTabData) return;

      e.preventDefault();

      try {
        const tabData = (tabDataString ? JSON.parse(tabDataString) : fallbackTabData) as
          | {
              bufferId?: string;
              paneId?: string;
              source?: "pane" | "terminal-panel";
              terminalId?: string;
              name?: string;
              shell?: string;
              initialCommand?: string;
              currentDirectory?: string;
              remoteConnectionId?: string;
            }
          | undefined;

        if (!tabData) return;

        if (tabData.source === "terminal-panel" && tabData.terminalId) {
          const bufferId = openTerminalBuffer({
            sessionId: tabData.terminalId,
            name: tabData.name,
            shell: tabData.shell,
            command: tabData.initialCommand,
            workingDirectory: tabData.currentDirectory,
            remoteConnectionId: tabData.remoteConnectionId,
          });
          activateBufferInPaneAndSync(BOTTOM_PANE_ID, bufferId);
          window.dispatchEvent(
            new CustomEvent("terminal-detach-to-buffer", {
              detail: { terminalId: tabData.terminalId },
            }),
          );
        } else if (tabData.bufferId && tabData.paneId && tabData.paneId !== BOTTOM_PANE_ID) {
          moveBufferToPane(tabData.bufferId, tabData.paneId, BOTTOM_PANE_ID);
          activateBufferInPaneAndSync(BOTTOM_PANE_ID, tabData.bufferId);
        } else {
          return;
        }

        useUIState.getState().setBottomPaneActiveTab("buffers");
        useUIState.getState().setIsBottomPaneVisible(true);
      } catch {
        // Ignore malformed drag payloads.
      } finally {
        clearInternalTabDragData();
      }
    },
    [moveBufferToPane, openTerminalBuffer],
  );

  const resizeGutter = !isFullScreen ? (
    <div
      onPointerDown={handlePointerDown}
      className={cn(
        "relative shrink-0 touch-none",
        isSideDocked
          ? "h-full w-(--lithe-workbench-gap) cursor-ew-resize"
          : "h-(--lithe-bottom-pane-gap) w-full cursor-ns-resize",
        isLeftDocked && "order-last",
      )}
      role="separator"
      aria-orientation={isSideDocked ? "vertical" : "horizontal"}
      aria-label={t(isSideDocked ? "terminal.resizePanel" : "layout.resizeBottomPane")}
    />
  ) : null;

  const paneContent = (
    <div
      data-bottom-pane-drop-target
      className={cn(
        "lithe-glass-island relative flex min-h-0 min-w-0 flex-col overflow-hidden rounded-(--lithe-island-radius) bg-background",
        isInternalHoverTarget && "ring-2 ring-primary ring-inset",
        isFullScreen && "size-full rounded-none border-0 shadow-none ring-0",
        !isFullScreen && "flex-1",
      )}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
    >
      <div className="h-full overflow-hidden">
        {/* Terminal Container - Always mounted to preserve terminal sessions */}
        {terminalEnabled && isBackendCapabilityAvailable("terminal") && (
          <TerminalContainer
            currentDirectory={rootFolderPath}
            className={cn("h-full", bottomPaneActiveTab === "terminal" ? "block" : "hidden")}
            onFullScreen={() => setIsFullScreen(!isFullScreen)}
            isFullScreen={isFullScreen}
            onMinimize={() => {
              // Reopening the terminal should restore the docked panel, not full screen.
              setIsFullScreen(false);
              useUIState.getState().setIsBottomPaneVisible(false);
            }}
          />
        )}

        {debuggerEnabled &&
          isBackendCapabilityAvailable("debugger") &&
          bottomPaneActiveTab === "debugger" && (
            <div className="h-full">
              <DebuggerView />
            </div>
          )}

        {bottomPaneActiveTab === "run" && isBackendCapabilityAvailable("run") && (
          <div className="h-full">
            <RunPane />
          </div>
        )}

        {bottomPaneActiveTab === "maven" && (
          <div className="h-full">
            <MavenRunPane />
          </div>
        )}
        {bottomPaneActiveTab === "build" ? <div className="h-full"><BuildOutputPane /></div> : null}

        {bottomPaneActiveTab === "diagnostics" && (
          <div className="h-full">
            <DiagnosticsBuffer
              onClose={() => useUIState.getState().setIsBottomPaneVisible(false)}
              onFullScreen={() => setIsFullScreen(!isFullScreen)}
              isFullScreen={isFullScreen}
              showCloseButton
            />
          </div>
        )}

        {bottomPaneActiveTab === "buffers" && (
          <div className="h-full">
            {bottomPaneBufferIds.length > 0 ? <BottomBufferPane /> : null}
          </div>
        )}

        {bottomPaneActiveTab === "gitLog" && (
          <div className="h-full">
            <GitLogToolWindow />
          </div>
        )}

        {bottomPaneActiveTab === "springEndpoints" && (
          <div className="h-full">
            <SpringEndpointsPane />
          </div>
        )}
      </div>
    </div>
  );

  const pane = isFullScreen ? (
    <WorkbenchFullscreenSurface hidden={!isBottomPaneVisible}>
      {paneContent}
    </WorkbenchFullscreenSurface>
  ) : (
    paneContent
  );

  if (isFullScreen) {
    // Keep terminal listeners and sessions mounted while a fullscreen panel is hidden.
    return pane;
  }

  return (
    <div
      ref={paneFrameRef}
      className={cn(
        "flex min-h-0 min-w-0 shrink-0",
        isSideDocked ? "h-full flex-row" : "flex-col",
        !isBottomPaneVisible && "hidden",
      )}
      style={{
        height: isSideDocked ? "100%" : `calc(${paneHeight}px + var(--lithe-bottom-pane-gap))`,
        width: isSideDocked ? `calc(${dock!.width}px + var(--lithe-workbench-gap))` : undefined,
      }}
    >
      {resizeGutter}
      {pane}
      {isResizing ? (
        <div
          className={cn(
            "fixed inset-0 z-40",
            isSideDocked ? "cursor-ew-resize" : "cursor-ns-resize",
          )}
        />
      ) : null}
    </div>
  );
};

export default BottomPane;
