import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import type { DatabaseType } from "@/features/database/types/provider.types";
import {
  PROVIDER_REGISTRY,
  type DatabaseViewerProps,
} from "@/features/database/providers/provider-registry";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { Buffer } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { isEditorKeyboardTarget } from "@/features/keymaps/utils/editor-keyboard-target";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { stageHunk, unstageHunk } from "@/features/git/api/git-status-api";
import type { GitHunk } from "@/features/git/types/git.types";
import { openSidebarResourceBuffer } from "@/features/sidebar/utils/open-sidebar-resource";
import {
  hasSidebarResourceDragData,
  readSidebarResourceDragData,
  type SidebarDragResource,
} from "@/features/sidebar/utils/sidebar-resource-drag";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import {
  useActiveWorkspaceId,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import TabBar from "@/features/tabs/components/tab-bar";
import { extractDroppedFilePaths } from "@/features/file-system/utils/file-system-dropped-paths";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/ui/empty";
import {
  clearInternalTabDragData,
  getInternalTabDragData,
  getInternalTabDragHover,
  resolveDropTarget,
} from "@/features/tabs/utils/internal-tab-drag";
import { activateBufferInPaneAndSync, activatePaneAndSyncBuffer } from "../utils/pane-activation";
import { reconcileMountedEditorBuffers } from "../utils/mounted-editor-buffers";
import { EmptyEditorState } from "./empty-editor-state";
import { BOTTOM_PANE_ID } from "../constants/pane";
import { usePaneStore } from "../stores/pane.store";
import type { PaneGroup } from "../types/pane.types";
import type { EditorContent, NewTabContent } from "../types/pane-content.types";
import {
  ensureBufferInPaneDropTarget,
  getOrCreatePaneDropTarget,
  moveBufferToPaneDropTarget,
} from "../utils/pane-drop-actions";
import { type DropZone, SplitDropOverlay } from "./split-drop-overlay";

const AgentTab = lazy(() =>
  import("@/features/ai/components/agent-tab").then((m) => ({
    default: m.AgentTab,
  })),
);
const CodeEditor = lazy(() => import("@/features/editor/components/code-editor"));

const databaseViewerCache = new Map<
  DatabaseType,
  React.LazyExoticComponent<React.ComponentType<DatabaseViewerProps>>
>();
function getDatabaseViewer(dbType: DatabaseType) {
  if (!databaseViewerCache.has(dbType)) {
    databaseViewerCache.set(dbType, lazy(PROVIDER_REGISTRY[dbType].viewerComponent));
  }
  return databaseViewerCache.get(dbType)!;
}
const ExternalEditorTerminal = lazy(() =>
  import("@/features/editor/components/external-editor-terminal").then((m) => ({
    default: m.ExternalEditorTerminal,
  })),
);
const DiffViewer = lazy(() => import("@/features/git/components/diff/git-diff-viewer"));
const GlobalSearchBuffer = lazy(
  () => import("@/features/global-search/components/global-search-buffer"),
);
const DiagnosticsBuffer = lazy(
  () => import("@/features/diagnostics/components/diagnostics-buffer"),
);
const ReferencesBuffer = lazy(() => import("@/features/references/components/references-buffer"));
const ExtensionsBuffer = lazy(() =>
  import("@/extensions/ui/components/extensions-sidebar").then((m) => ({
    default: m.ExtensionsSidebar,
  })),
);
const OnboardingView = lazy(() => import("@/features/onboarding/components/onboarding-view"));
const GitHubPRViewer = lazy(() => import("@/features/github/components/github-pr-viewer"));
const GitHubIssueViewer = lazy(() => import("@/features/github/components/github-issue-viewer"));
const GitHubActionViewer = lazy(() => import("@/features/github/components/github-action-viewer"));
const GitHubCreateView = lazy(() =>
  import("@/features/github/components/github-create-view").then((module) => ({
    default: module.GitHubCreateView,
  })),
);
const MarkdownDocumentView = lazy(() =>
  import("@/features/editor/markdown/markdown-document-view").then((module) => ({
    default: module.MarkdownDocumentView,
  })),
);
const ImageViewer = lazy(() =>
  import("@/features/viewer/image/components/image-viewer").then((m) => ({
    default: m.ImageViewer,
  })),
);
const PdfViewer = lazy(() =>
  import("@/features/viewer/pdf/components/pdf-viewer").then((m) => ({
    default: m.PdfViewer,
  })),
);
const BinaryFileViewer = lazy(() =>
  import("@/features/viewer/binary/components/binary-file-viewer").then((m) => ({
    default: m.BinaryFileViewer,
  })),
);
const TerminalTab = lazy(() =>
  import("@/features/terminal/components/terminal-tab").then((m) => ({
    default: m.TerminalTab,
  })),
);
const WebViewer = lazy(() =>
  import("@/features/viewer/web/components/web-viewer").then((m) => ({
    default: m.WebViewer,
  })),
);

interface PaneContainerProps {
  pane: PaneGroup;
}

const MAX_MOUNTED_EDITOR_BUFFERS = 8;

type EditorBufferShell = Pick<EditorContent, "id" | "path" | "name" | "type" | "readOnly">;
type PaneRenderBuffer = Exclude<Buffer, EditorContent | NewTabContent> | EditorBufferShell;
type PaneRenderState = {
  activeBuffer: PaneRenderBuffer | null;
  paneBuffers: PaneRenderBuffer[];
};

const editorBufferShellCache = new Map<string, EditorBufferShell>();

function getEditorBufferShell(buffer: EditorContent): EditorBufferShell {
  const cached = editorBufferShellCache.get(buffer.id);
  if (
    cached &&
    cached.path === buffer.path &&
    cached.name === buffer.name &&
    cached.readOnly === buffer.readOnly
  ) {
    return cached;
  }

  const shell = {
    id: buffer.id,
    path: buffer.path,
    name: buffer.name,
    type: buffer.type,
    readOnly: buffer.readOnly,
  } satisfies EditorBufferShell;
  editorBufferShellCache.set(buffer.id, shell);
  return shell;
}

function toPaneRenderBuffer(buffer: Buffer | undefined): PaneRenderBuffer | undefined {
  if (!buffer) return undefined;
  if (buffer.type === "newTab") return undefined;
  if (buffer.type === "editor") return getEditorBufferShell(buffer);
  return buffer;
}

const EMPTY_PANE_RENDER_STATE: PaneRenderState = {
  activeBuffer: null,
  paneBuffers: [],
};

function WebViewerDisabledState() {
  const { t } = useTranslation();

  return (
    <Empty className="size-full rounded-none bg-background px-6">
      <EmptyHeader>
        <EmptyTitle>{t("panes.webViewerDisabled")}</EmptyTitle>
        <EmptyDescription>{t("panes.webViewerDisabledDescription")}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}

function isStandardEditorBuffer(buffer: PaneRenderBuffer): buffer is EditorBufferShell {
  return buffer.type === "editor";
}

export function PaneContainer({ pane }: PaneContainerProps) {
  const { t } = useTranslation();
  const activePaneId = usePaneStore.use.activePaneId();
  const { closeBufferForce, openTerminalBuffer } = useBufferStore.use.actions();
  const rootFolderPath = useFileSystemStore.use.rootFolderPath?.();
  const handleFileOpen = useFileSystemStore.use.handleFileOpen?.();
  const webViewerEnabled = useSettingsStore((state) => state.settings.coreFeatures.webViewer);

  const [isDragOver, setIsDragOver] = useState(false);
  const [isTabDragOver, setIsTabDragOver] = useState(false);
  const [internalHoverZone, setInternalHoverZone] = useState<DropZone>(null);
  const [mountedEditorBufferIds, setMountedEditorBufferIds] = useState<readonly string[]>([]);
  const mountedEditorBufferStateRef = useRef({
    recentIds: [] as readonly string[],
    mountedIds: [] as readonly string[],
  });
  const containerRef = useRef<HTMLDivElement>(null);
  const workspaceScopeId = useWorkspaceStoreScopeId();
  const activeWorkspaceId = useActiveWorkspaceId();
  const isWorkspaceSurfaceActive = !workspaceScopeId || workspaceScopeId === activeWorkspaceId;
  const isActivePane = pane.id === activePaneId && isWorkspaceSurfaceActive;

  const { activeBuffer, paneBuffers } = useBufferStore(
    useShallow((state) => {
      if (pane.bufferIds.length === 0) {
        return EMPTY_PANE_RENDER_STATE;
      }

      const nextPaneBuffers: PaneRenderBuffer[] = [];
      let nextActiveBuffer: PaneRenderBuffer | null = null;

      for (const bufferId of pane.bufferIds) {
        const buffer = toPaneRenderBuffer(getBufferById(state.buffers, bufferId) ?? undefined);
        if (!buffer) continue;

        nextPaneBuffers.push(buffer);
        if (buffer.id === pane.activeBufferId) {
          nextActiveBuffer = buffer;
        }
      }

      return {
        activeBuffer: nextActiveBuffer,
        paneBuffers: nextPaneBuffers,
      };
    }),
  );

  useEffect(() => {
    if (!isActivePane || !pane.activeBufferId) return;

    const bufferStore = useBufferStore.getState();
    if (bufferStore.activeBufferId !== pane.activeBufferId) {
      bufferStore.actions.setActiveBuffer(pane.activeBufferId);
    }
  }, [isActivePane, pane.activeBufferId]);

  useEffect(() => {
    const openEditorBufferIds = paneBuffers
      .filter(isStandardEditorBuffer)
      .map((buffer) => buffer.id);
    const activeEditorBufferId =
      activeBuffer && isStandardEditorBuffer(activeBuffer) ? activeBuffer.id : null;
    const previous = mountedEditorBufferStateRef.current;
    const next = reconcileMountedEditorBuffers(
      previous,
      openEditorBufferIds,
      activeEditorBufferId,
      MAX_MOUNTED_EDITOR_BUFFERS,
    );
    mountedEditorBufferStateRef.current = next;
    if (next.mountedIds !== previous.mountedIds) {
      setMountedEditorBufferIds(next.mountedIds);
    }
  }, [activeBuffer, paneBuffers]);

  const handlePaneClick = useCallback(() => {
    activatePaneAndSyncBuffer(pane.id);
  }, [pane.id]);

  const handlePaneMouseDownCapture = useCallback(
    (e: React.MouseEvent) => {
      const target = e.target as HTMLElement;
      const isEditorTarget = isEditorKeyboardTarget(target);
      const isTerminalTextarea = target.classList.contains("xterm-helper-textarea");
      if (
        !isEditorTarget &&
        !isTerminalTextarea &&
        target.closest("button, input, textarea, [role='button'], [role='menu']")
      ) {
        return;
      }

      activatePaneAndSyncBuffer(pane.id);
    },
    [pane.id],
  );

  const handleTabClick = useCallback(
    (bufferId: string) => {
      activateBufferInPaneAndSync(pane.id, bufferId);
    },
    [pane.id],
  );

  const openFileTreeDropInPane = useCallback(
    async (
      fileDragData: { path: string; name: string; isDir: boolean },
      point: { x: number; y: number },
    ) => {
      if (!isWorkspaceSurfaceActive) return;
      if (fileDragData.isDir) return;
      if (!handleFileOpen) return;

      const target = resolveDropTarget(point);
      if (target.paneId !== pane.id) return;

      const targetPaneId = getOrCreatePaneDropTarget({ paneId: pane.id, zone: target.zone });
      if (!targetPaneId) return;

      activatePaneAndSyncBuffer(targetPaneId);

      try {
        await handleFileOpen(fileDragData.path, false);
        const openedBufferId = useBufferStore.getState().activeBufferId;
        if (openedBufferId) {
          ensureBufferInPaneDropTarget(openedBufferId, { paneId: targetPaneId, zone: "center" });
          activateBufferInPaneAndSync(targetPaneId, openedBufferId);
        }
      } catch (error) {
        console.error("Failed to open file from file tree drop:", error);
      } finally {
        delete window.__fileDragData;
      }
    },
    [handleFileOpen, isWorkspaceSurfaceActive, pane.id],
  );

  const openSidebarResourceInPane = useCallback(
    async (resource: SidebarDragResource, point: { x: number; y: number }) => {
      if (!isWorkspaceSurfaceActive) return;
      const opensBuffer =
        !(resource.type === "file" && resource.isDir) && resource.type !== "git-worktree";
      const target = resolveDropTarget(point);
      if (target.paneId !== pane.id) return;

      const targetPaneId = opensBuffer
        ? getOrCreatePaneDropTarget({ paneId: pane.id, zone: target.zone })
        : pane.id;
      if (!targetPaneId) return;

      activatePaneAndSyncBuffer(targetPaneId);

      try {
        const bufferId = await openSidebarResourceBuffer(resource);
        if (!bufferId) return;

        ensureBufferInPaneDropTarget(bufferId, { paneId: targetPaneId, zone: "center" });
        activateBufferInPaneAndSync(targetPaneId, bufferId);
      } catch (error) {
        console.error("Failed to open sidebar resource from drop:", error);
      }
    },
    [isWorkspaceSurfaceActive, pane.id],
  );

  const handleStageHunk = useCallback(
    async (hunk: GitHunk) => {
      if (!rootFolderPath) return;
      try {
        const success = await stageHunk(rootFolderPath, hunk);
        if (!success) return;
      } catch (error) {
        console.error("Error staging hunk:", error);
      }
    },
    [rootFolderPath],
  );

  const handleUnstageHunk = useCallback(
    async (hunk: GitHunk) => {
      if (!rootFolderPath) return;
      try {
        const success = await unstageHunk(rootFolderPath, hunk);
        if (!success) return;
      } catch (error) {
        console.error("Error unstaging hunk:", error);
      }
    },
    [rootFolderPath],
  );

  const handleExternalEditorExit = useCallback(() => {
    if (activeBuffer?.type === "externalEditor") {
      closeBufferForce(activeBuffer.id);
    }
  }, [activeBuffer, closeBufferForce]);

  // Listen for file tree drops on this pane
  useEffect(() => {
    if (!isWorkspaceSurfaceActive) {
      return;
    }

    const syncHover = () => {
      const hover = getInternalTabDragHover();
      setInternalHoverZone(hover.paneId === pane.id ? hover.zone : null);
    };

    window.addEventListener("lithe-internal-tab-drag-hover", syncHover);
    return () => window.removeEventListener("lithe-internal-tab-drag-hover", syncHover);
  }, [isWorkspaceSurfaceActive, pane.id]);

  useEffect(() => {
    if (!isWorkspaceSurfaceActive) {
      return;
    }

    const handleFileTreeDrop = async (e: CustomEvent) => {
      const fileDragData = window.__fileDragData;
      if (!fileDragData) return;

      await openFileTreeDropInPane(fileDragData, { x: e.detail.x, y: e.detail.y });
    };

    window.addEventListener(
      "file-tree-drop-on-pane",
      handleFileTreeDrop as unknown as EventListener,
    );
    return () => {
      window.removeEventListener(
        "file-tree-drop-on-pane",
        handleFileTreeDrop as unknown as EventListener,
      );
    };
  }, [isWorkspaceSurfaceActive, openFileTreeDropInPane]);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();

    const hasTabData =
      e.dataTransfer.types.includes("application/tab-data") || !!getInternalTabDragData();
    const hasFilePath = e.dataTransfer.types.includes("text/plain");
    const hasSidebarResource = hasSidebarResourceDragData(e.dataTransfer);
    const hasFileDragData = !!window.__fileDragData;

    if (
      hasTabData ||
      hasSidebarResource ||
      hasFilePath ||
      hasFileDragData ||
      e.dataTransfer.types.includes("Files")
    ) {
      e.dataTransfer.dropEffect = "move";
      setIsDragOver(true);
      if (hasTabData) {
        setIsTabDragOver(true);
      }
    }
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    const relatedTarget = e.relatedTarget as HTMLElement | null;
    const currentTarget = e.currentTarget as HTMLElement;
    if (!relatedTarget || !currentTarget.contains(relatedTarget)) {
      setIsDragOver(false);
      setIsTabDragOver(false);
    }
  }, []);

  const handleSplitDrop = useCallback(
    (zone: DropZone, e: React.DragEvent) => {
      setIsDragOver(false);
      setIsTabDragOver(false);

      if (!zone) return;

      const tabDataString = e.dataTransfer.getData("application/tab-data");
      const fallbackTabData = getInternalTabDragData();
      if (!tabDataString && !fallbackTabData) return;

      let bufferId: string | undefined;
      let sourcePaneId: string | undefined;
      let source: string | undefined;
      let terminalId: string | undefined;
      let terminalName: string | undefined;
      let shell: string | undefined;
      let initialCommand: string | undefined;
      let currentDirectory: string | undefined;
      let remoteConnectionId: string | undefined;
      try {
        const tabData = tabDataString ? JSON.parse(tabDataString) : fallbackTabData;
        bufferId = tabData.bufferId;
        sourcePaneId = tabData.paneId;
        source = tabData.source;
        terminalId = tabData.terminalId;
        terminalName = tabData.name;
        shell = tabData.shell;
        initialCommand = tabData.initialCommand;
        currentDirectory = tabData.currentDirectory;
        remoteConnectionId = tabData.remoteConnectionId;
      } catch {
        return;
      } finally {
        clearInternalTabDragData();
      }

      if (zone === "center") {
        if (source === "terminal-panel" && terminalId) {
          const newBufferId = openTerminalBuffer({
            sessionId: terminalId,
            name: terminalName,
            shell,
            command: initialCommand,
            workingDirectory: currentDirectory,
            remoteConnectionId,
          });
          activateBufferInPaneAndSync(pane.id, newBufferId);
          window.dispatchEvent(
            new CustomEvent("terminal-detach-to-buffer", {
              detail: { terminalId },
            }),
          );
        } else if (sourcePaneId && sourcePaneId !== pane.id && bufferId) {
          moveBufferToPaneDropTarget(bufferId, sourcePaneId, { paneId: pane.id, zone: "center" });
          activateBufferInPaneAndSync(pane.id, bufferId);
        } else if (!sourcePaneId && bufferId) {
          ensureBufferInPaneDropTarget(bufferId, { paneId: pane.id, zone: "center" });
          activateBufferInPaneAndSync(pane.id, bufferId);
        }
        return;
      }

      const newPaneId = getOrCreatePaneDropTarget({ paneId: pane.id, zone });
      if (!newPaneId) return;

      // Move the dragged buffer into the newly created pane.
      if (source === "terminal-panel" && terminalId) {
        const newBufferId = openTerminalBuffer({
          sessionId: terminalId,
          name: terminalName,
          shell,
          command: initialCommand,
          workingDirectory: currentDirectory,
          remoteConnectionId,
        });
        activateBufferInPaneAndSync(newPaneId, newBufferId);
        window.dispatchEvent(
          new CustomEvent("terminal-detach-to-buffer", {
            detail: { terminalId },
          }),
        );
      } else if (sourcePaneId && sourcePaneId !== pane.id && bufferId) {
        moveBufferToPaneDropTarget(bufferId, sourcePaneId, { paneId: newPaneId, zone: "center" });
        activateBufferInPaneAndSync(newPaneId, bufferId);
      } else if (bufferId) {
        moveBufferToPaneDropTarget(bufferId, pane.id, { paneId: newPaneId, zone: "center" });
        activateBufferInPaneAndSync(newPaneId, bufferId);
      }
    },
    [pane.id, openTerminalBuffer],
  );

  // Handle mouse up for file tree drag (which uses mouse events, not HTML5 drag API)
  const handleMouseUp = useCallback(
    async (event: React.MouseEvent) => {
      const fileDragData = window.__fileDragData;
      if (!fileDragData || fileDragData.isDir) {
        return; // Only handle file drops, not directory drops
      }

      await openFileTreeDropInPane(fileDragData, { x: event.clientX, y: event.clientY });
    },
    [openFileTreeDropInPane],
  );

  const handleDrop = useCallback(
    async (e: React.DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      setIsDragOver(false);
      setIsTabDragOver(false);
      activatePaneAndSyncBuffer(pane.id);

      // Tab drops are handled by SplitDropOverlay — skip here
      if (e.dataTransfer.types.includes("application/tab-data") || getInternalTabDragData()) {
        return;
      }

      const sidebarResource = readSidebarResourceDragData(e.dataTransfer);
      if (sidebarResource) {
        await openSidebarResourceInPane(sidebarResource, { x: e.clientX, y: e.clientY });
        return;
      }

      const droppedPaths = extractDroppedFilePaths(e.dataTransfer);
      if (droppedPaths.length > 0 && handleFileOpen) {
        for (const droppedPath of droppedPaths) {
          await handleFileOpen(droppedPath, false);
        }
        return;
      }
    },
    [pane.id, handleFileOpen, openSidebarResourceInPane],
  );

  const mountedEditorBuffers = paneBuffers.filter(
    (buffer): buffer is EditorBufferShell =>
      isStandardEditorBuffer(buffer) &&
      (buffer.id === activeBuffer?.id || mountedEditorBufferIds.includes(buffer.id)),
  );

  const renderActiveBuffer = useCallback(
    (buffer: PaneRenderBuffer) => {
      switch (buffer.type) {
        case "terminal":
          return (
            <TerminalTab
              sessionId={buffer.sessionId}
              bufferId={buffer.id}
              paneId={pane.id}
              shell={buffer.shell}
              initialCommand={buffer.initialCommand}
              workingDirectory={buffer.workingDirectory}
              remoteConnectionId={buffer.remoteConnectionId}
              isActive={isActivePane}
            />
          );

        case "webViewer":
          if (!webViewerEnabled) {
            return <WebViewerDisabledState />;
          }

          return <WebViewer url={buffer.url} bufferId={buffer.id} isActive={isActivePane} />;

        case "agent":
          return <AgentTab buffer={buffer} isActive={isActivePane} />;

        case "diff":
          return <DiffViewer onStageHunk={handleStageHunk} onUnstageHunk={handleUnstageHunk} />;

        case "pullRequest":
          return <GitHubPRViewer prNumber={buffer.prNumber} bufferId={buffer.id} />;

        case "githubIssue":
          return (
            <GitHubIssueViewer
              issueNumber={buffer.issueNumber}
              repoPath={buffer.repoPath}
              bufferId={buffer.id}
            />
          );

        case "githubAction":
          return (
            <GitHubActionViewer
              runId={buffer.runId}
              repoPath={buffer.repoPath}
              bufferId={buffer.id}
            />
          );

        case "githubForm":
          return <GitHubCreateView buffer={buffer} />;

        case "markdownDocument":
          return <MarkdownDocumentView bufferId={buffer.id} />;

        case "globalSearch":
          return <GlobalSearchBuffer />;

        case "diagnostics":
          return <DiagnosticsBuffer />;

        case "references":
          return <ReferencesBuffer />;

        case "extensions":
          return <ExtensionsBuffer />;

        case "onboarding":
          return (
            <OnboardingView
              bufferId={buffer.id}
              context={{
                mode: buffer.mode,
                currentVersion: buffer.currentVersion,
                previousVersion: buffer.previousVersion,
              }}
            />
          );

        case "image":
          return <ImageViewer filePath={buffer.path} fileName={buffer.name} bufferId={buffer.id} />;

        case "pdf":
          return <PdfViewer filePath={buffer.path} fileName={buffer.name} bufferId={buffer.id} />;

        case "database": {
          const config = PROVIDER_REGISTRY[buffer.databaseType];
          const DatabaseViewer = getDatabaseViewer(buffer.databaseType);
          let viewerProps: DatabaseViewerProps;
          if (config.isFileBased) {
            viewerProps = { databasePath: buffer.path };
          } else {
            const connectionId = buffer.connectionId;
            if (!connectionId) {
              return (
                <Empty className="h-full rounded-none" tone="error" role="alert">
                  <EmptyDescription>{t("panes.missingDatabaseConnection")}</EmptyDescription>
                </Empty>
              );
            }
            viewerProps = { connectionId };
          }
          return <DatabaseViewer {...viewerProps} />;
        }

        case "binary":
          return (
            <BinaryFileViewer
              filePath={buffer.path}
              fileName={buffer.name}
              rootFolderPath={rootFolderPath}
            />
          );

        case "externalEditor":
          return (
            <ExternalEditorTerminal
              filePath={buffer.path}
              fileName={buffer.name}
              terminalConnectionId={buffer.terminalConnectionId}
              onEditorExit={handleExternalEditorExit}
            />
          );

        default:
          return (
            <CodeEditor
              paneId={pane.id}
              bufferId={buffer.id}
              isActiveSurface={isActivePane}
              readOnly={buffer.type === "editor" ? buffer.readOnly : undefined}
            />
          );
      }
    },
    [
      handleExternalEditorExit,
      handleStageHunk,
      handleUnstageHunk,
      isActivePane,
      pane.id,
      rootFolderPath,
    ],
  );

  return (
    <div
      ref={containerRef}
      data-pane-container
      data-pane-id={pane.id}
      className={`relative flex size-full flex-col overflow-hidden bg-background ${
        isActivePane ? "ring-1 ring-primary/30" : ""
      } ${isDragOver || internalHoverZone ? "ring-2 ring-primary" : ""}`}
      onMouseDownCapture={handlePaneMouseDownCapture}
      onClick={handlePaneClick}
      onMouseUp={handleMouseUp}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {(isDragOver || internalHoverZone) && !isTabDragOver && !internalHoverZone && (
        <div className="pointer-events-none absolute inset-0 z-40 bg-primary/10" />
      )}
      <SplitDropOverlay
        visible={isTabDragOver || !!internalHoverZone}
        onDrop={handleSplitDrop}
        activeZoneOverride={internalHoverZone}
      />
      <TabBar
        paneId={pane.id}
        onTabClick={handleTabClick}
        disablePaneActions={pane.id === BOTTOM_PANE_ID}
      />
      <div className="relative min-h-0 flex-1 overflow-hidden">
        {!activeBuffer && <EmptyEditorState />}

        <Suspense fallback={null}>
          <>
            {/* Keep terminal and webviewer buffers always mounted to preserve
                PTY sessions and embedded webview state. */}
            {paneBuffers
              .filter(
                (
                  b,
                ): b is
                  | import("../types/pane-content.types").TerminalContent
                  | import("../types/pane-content.types").WebViewerContent =>
                  b.type === "terminal" || (webViewerEnabled && b.type === "webViewer"),
              )
              .map((b) => {
                const isActive = b.id === activeBuffer?.id;
                return (
                  <div
                    key={b.id}
                    className="absolute inset-0"
                    style={isActive ? undefined : { visibility: "hidden" }}
                  >
                    {b.type === "terminal" ? (
                      <TerminalTab
                        sessionId={b.sessionId}
                        bufferId={b.id}
                        paneId={pane.id}
                        shell={b.shell}
                        initialCommand={b.initialCommand}
                        workingDirectory={b.workingDirectory}
                        remoteConnectionId={b.remoteConnectionId}
                        isActive={isActive && isActivePane}
                        isVisible={isActive}
                      />
                    ) : (
                      <WebViewer
                        url={b.url}
                        bufferId={b.id}
                        profileKey={b.profileKey}
                        history={b.history}
                        historyIndex={b.historyIndex}
                        isActive={isActive && isActivePane}
                        isVisible={isActive}
                      />
                    )}
                  </div>
                );
              })}
            {mountedEditorBuffers.map((buffer) => {
              const isActive = buffer.id === activeBuffer?.id;
              return (
                <div
                  key={buffer.id}
                  className="absolute inset-0"
                  style={isActive ? undefined : { visibility: "hidden" }}
                >
                  <CodeEditor
                    paneId={pane.id}
                    bufferId={buffer.id}
                    isActiveSurface={isActive && isActivePane}
                    readOnly={buffer.readOnly}
                  />
                </div>
              );
            })}
            {activeBuffer &&
              activeBuffer.type !== "terminal" &&
              (activeBuffer.type !== "webViewer" || !webViewerEnabled) &&
              !isStandardEditorBuffer(activeBuffer) &&
              renderActiveBuffer(activeBuffer)}
          </>
        </Suspense>
      </div>
    </div>
  );
}
