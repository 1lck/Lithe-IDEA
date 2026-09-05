import type React from "react";
import { invoke } from "@/platform/tauri-core";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { CsvPreview } from "@/extensions/viewers/csv/csv-preview";
import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import { useLspIntegration } from "@/features/editor/hooks/use-lsp-integration";
import { useEditorScroll } from "@/features/editor/hooks/use-scroll";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import {
  editorBufferSurfacesEqual,
  selectEditorBufferSurface,
} from "@/features/editor/stores/buffer-metadata";
import { useEditorSettingsStore } from "@/features/editor/stores/settings.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { useEditorViewStore } from "@/features/editor/stores/view.store";
import { areBufferPathsEqual, getBufferById } from "@/features/editor/utils/buffer-index";
import { calculateLineHeight, splitLines } from "@/features/editor/utils/lines";
import { resolveGoToLineTarget } from "@/features/editor/utils/go-to-line";
import type { EditorModelPositionResolver } from "@/features/editor/view-model/view-layout";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { PaneResizeHandle } from "@/features/panes/components/pane-resize-handle";
import { isMarkdownPreviewableFile } from "@/features/editor/markdown/previewable";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { toast } from "sonner";
import { useEditorAppStore } from "@/features/editor/stores/editor-app.store";
import { useZoomStore } from "@/features/window/stores/zoom.store";
import { editorAPI } from "../extensions/api";
import CodeLensOverlay from "../lsp/code-lens-overlay";
import RenameInput from "../lsp/rename-input";
import { SignatureHelpTooltip } from "../lsp/signature-help-tooltip";
import type { CodeLensItem } from "../lsp/use-code-lens";
import { useRename } from "../lsp/use-rename";
import { MarkdownPreview } from "../markdown/markdown-preview";
import { NotebookEditor } from "../notebook/notebook-editor";
import { getPythonScriptCells } from "../notebook/python-script-cells";
import {
  applyRMarkdownChunkOptionSemantics,
  clearRMarkdownChunkOutput,
  formatRMarkdownChunkOutput,
  getRMarkdownChunks,
  rMarkdownChunkShouldEvaluate,
  rMarkdownChunkShouldPersistOutput,
  updateRMarkdownChunkOutput,
} from "../notebook/rmarkdown-chunks";
import type { EditorContentChangeOptions, Position, Range } from "../types/editor.types";
import { ScrollDebugOverlay } from "./debug/scroll-debug-overlay";
import { HtmlPreview } from "./html/html-preview";
import {
  MonacoEditor,
  type MonacoEditorProps,
  type MonacoEditorScrollApi,
} from "./monaco-editor";
import {
  MarkdownScrollSyncController,
  markdownScrollOffset,
  markdownScrollRatio,
  type MarkdownScrollMetrics,
} from "../markdown/scroll-sync";
import { EditorStylesheet } from "./stylesheet";
import { ExternalConflictBanner } from "./external-conflict-banner";
import Breadcrumb, { type BreadcrumbProps } from "./toolbar/breadcrumb";

interface CodeEditorProps {
  onKeyDown?: (e: React.KeyboardEvent<HTMLDivElement>) => void;
  onCursorPositionChange?: (position: number) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  paneId?: string;
  bufferId?: string;
  isActiveSurface?: boolean;
  showToolbar?: boolean;
  readOnly?: boolean;
  breadcrumbProps?: BreadcrumbProps;
  scrollable?: boolean;
  alwaysConsumeMouseWheel?: boolean;
  backgroundLayer?: ReactNode;
  onReadonlySurfaceClick?: (position: { line: number; column: number }) => void;
  highlightMatches?: Array<{ start: number; end: number }>;
  currentHighlightIndex?: number;
  lineNumberStart?: number;
  lineNumberMap?: Array<number | null>;
  onContentChange?: (
    content: string,
    previousContent?: string,
    previousCursorPosition?: Position,
    previousSelection?: Range,
    options?: EditorContentChangeOptions,
  ) => void;
}

const noopContentChange: NonNullable<CodeEditorProps["onContentChange"]> = () => {};

export interface CodeEditorRef {
  editor: HTMLDivElement | null;
  textarea: HTMLDivElement | null;
}

interface GoToLineEventDetail {
  line?: number;
  column?: number;
  path?: string;
}

const PYTHON_SCRIPT_CELL_COMMAND = "lithe.runPythonScriptCell";
const R_MARKDOWN_CHUNK_COMMAND = "lithe.runRMarkdownChunk";

interface NotebookRunResult {
  stdout: string;
  stderr: string;
  status: number | null;
  timedOut: boolean;
  displayData?: Array<unknown>;
}

function isPythonScriptFile(filePath: string): boolean {
  const normalized = filePath.toLowerCase();
  return normalized.endsWith(".py") || normalized.endsWith(".ipy");
}

function isRMarkdownFile(filePath: string): boolean {
  return filePath.toLowerCase().endsWith(".rmd");
}

function editorWorkingDirectory(path: string): string | null {
  if (!path || path.startsWith("remote://") || path.includes("://")) return null;
  const lastSlash = path.lastIndexOf("/");
  if (lastSlash <= 0) return null;
  return path.slice(0, lastSlash);
}

function truncateCellOutput(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length <= 180) return trimmed;
  return `${trimmed.slice(0, 177)}...`;
}

const CodeEditor = ({
  className,
  paneId,
  bufferId: propBufferId,
  isActiveSurface = true,
  showToolbar = false,
  readOnly = false,
  breadcrumbProps,
  scrollable = true,
  alwaysConsumeMouseWheel = true,
  backgroundLayer,
  onReadonlySurfaceClick,
  highlightMatches,
  currentHighlightIndex,
  lineNumberStart,
  lineNumberMap,
  onContentChange,
}: CodeEditorProps) => {
  const { t } = useTranslation();
  const editorRef = useRef<HTMLDivElement>(null);
  const codeLensRef = useRef<HTMLDivElement>(null);
  const renameInputRef = useRef<HTMLDivElement>(null);
  const valueRef = useRef("");
  const editorModelPositionResolverRef = useRef<EditorModelPositionResolver | null>(null);
  const [codeLensContentLeft, setCodeLensContentLeft] = useState<number>(
    EDITOR_CONSTANTS.EDITOR_PADDING_LEFT,
  );
  const { setRefs, setContent, setFileInfo, setActiveEditorViewKey } =
    useEditorStateStore.use.actions();
  const { setDisabled } = useEditorSettingsStore.use.actions();

  const activeBufferId = useBufferStore((state) => propBufferId ?? state.activeBufferId);
  const zoomLevel = useZoomStore.use.editorZoomLevel();
  const activeBuffer = useBufferStore(
    useCallback(
      (state) => selectEditorBufferSurface(state.buffers, activeBufferId),
      [activeBufferId],
    ),
    editorBufferSurfacesEqual,
  );
  const editorViewKey = paneId && activeBufferId ? `${paneId}:${activeBufferId}` : activeBufferId;
  const { handleContentChange } = useEditorAppStore.use.actions();
  const handleBufferContentChange = useCallback<NonNullable<CodeEditorProps["onContentChange"]>>(
    (content, previousContent, previousCursorPosition, previousSelection, options) => {
      if (!activeBufferId) return;
      void handleContentChange(
        activeBufferId,
        content,
        previousContent,
        previousCursorPosition,
        previousSelection,
        options,
      );
    },
    [activeBufferId, handleContentChange],
  );
  const editorFontSize = useSettingsStore((state) => state.settings.fontSize);
  const editorLineHeight = useSettingsStore((state) => state.settings.editorLineHeight);
  const codeLensEnabled = useSettingsStore((state) => state.settings.codeLens);

  // Apply zoom to font size for position calculations (must match editor.tsx)
  const zoomedFontSize = editorFontSize * zoomLevel;
  const zoomedLineHeight = calculateLineHeight(zoomedFontSize, editorLineHeight);

  const filePath = activeBuffer?.path || "";
  const needsLiveNotebookContent = isPythonScriptFile(filePath) || isRMarkdownFile(filePath);
  const notebookContent = useBufferStore((state) => {
    if (!needsLiveNotebookContent) return "";
    const buffer = getBufferById(state.buffers, activeBufferId);
    return buffer && hasTextContent(buffer) ? buffer.content : "";
  });
  const onChange = activeBuffer
    ? (onContentChange ?? (isActiveSurface ? handleBufferContentChange : noopContentChange))
    : noopContentChange;
  const handleEditorContentChange = useCallback(
    (
      content: string,
      previousContent?: string,
      previousCursorPosition?: Position,
      previousSelection?: Range,
      options?: EditorContentChangeOptions,
    ) => {
      valueRef.current = content;
      onChange(content, previousContent, previousCursorPosition, previousSelection, options);
    },
    [onChange],
  );
  const isPreviewBuffer = activeBuffer?.isPreview ?? false;
  const showNotebookEditor =
    activeBuffer?.type === "editor" && filePath.toLowerCase().endsWith(".ipynb");
  const [forceExpensiveServices, setForceExpensiveServices] = useState(false);
  const tooLargeForEditorServices = useEditorViewStore(
    (state) => state.tooLargeForEditorServices === true,
  );
  const enableInteractiveServices =
    isActiveSurface && !isPreviewBuffer && !readOnly && !showNotebookEditor;
  const enableRichEditorServices =
    enableInteractiveServices && (!tooLargeForEditorServices || forceExpensiveServices);
  const enableCodeLens = enableRichEditorServices && codeLensEnabled;

  useLayoutEffect(() => {
    const buffer = getBufferById(useBufferStore.getState().buffers, activeBufferId);
    valueRef.current = buffer && hasTextContent(buffer) ? buffer.content : "";
  }, [activeBufferId, activeBuffer?.contentRevision]);

  useEffect(() => {
    setForceExpensiveServices(false);
  }, [activeBufferId]);

  const showMarkdownPreview = activeBuffer?.type === "markdownPreview";
  const showHtmlPreview = activeBuffer?.type === "htmlPreview";
  const showCsvPreview = activeBuffer?.type === "csvPreview";

  // In-place Markdown display mode (editor/split/preview) mirrors the macOS
  // editor area; only plain Markdown editor buffers expose the switcher.
  const isMarkdownEditorSurface =
    activeBuffer?.type === "editor" && isMarkdownPreviewableFile(activeBuffer.path);
  const markdownViewMode = isMarkdownEditorSurface
    ? (activeBuffer.markdownViewMode ?? "source")
    : null;
  const showMarkdownSplit = markdownViewMode === "split";
  const showMarkdownPreviewSurface = markdownViewMode === "preview";

  // Initialize refs in store
  useEffect(() => {
    if (!isActiveSurface) return;
    setRefs({
      editorRef,
    });
  }, [isActiveSurface, setRefs]);

  useEffect(() => {
    if (!isActiveSurface) return;
    setActiveEditorViewKey(editorViewKey ?? null);
  }, [editorViewKey, isActiveSurface, setActiveEditorViewKey]);

  // Focus editor when active buffer changes
  useEffect(() => {
    if (!enableInteractiveServices) return;
    if (!activeBufferId || !editorRef.current) return;

    const focusTarget =
      editorRef.current
        .querySelector<HTMLElement>("[data-monaco-editor-scroll]")
        ?.querySelector<HTMLTextAreaElement>("textarea") ??
      editorRef.current.querySelector<HTMLTextAreaElement>("textarea");

    if (!focusTarget) return;

    // Small delay to ensure the editor surface is mounted.
    const focusTimer = setTimeout(() => {
      focusTarget.focus();
    }, 0);

    return () => clearTimeout(focusTimer);
  }, [activeBufferId, enableInteractiveServices]);

  // Sync content and file info with editor instance store
  useEffect(() => {
    if (!isActiveSurface) return;
    setContent("", onChange);
  }, [isActiveSurface, onChange, setContent]);

  useEffect(() => {
    if (!isActiveSurface) return;
    setFileInfo(filePath);
  }, [filePath, isActiveSurface, setFileInfo]);

  // Editor view store automatically syncs with active buffer

  // Set disabled state
  useEffect(() => {
    if (!isActiveSurface) return;
    setDisabled(false);
  }, [isActiveSurface, setDisabled]);

  const resolveModelPosition = useCallback<EditorModelPositionResolver>(
    (line, column) => editorModelPositionResolverRef.current?.(line, column) ?? null,
    [],
  );
  const handleModelPositionResolverChange = useCallback(
    (resolver: EditorModelPositionResolver | null) => {
      editorModelPositionResolverRef.current = resolver;
    },
    [],
  );
  const getCodeLensLineText = useCallback((line: number) => {
    return splitLines(valueRef.current)[line] ?? "";
  }, []);
  const measureCodeLensContentLeft = useCallback(() => {
    const container = editorRef.current;
    if (!container) return;

    const containerRect = container.getBoundingClientRect();
    const contentContainer = container.querySelector<HTMLElement>(
      "[data-editor-content-container]",
    );
    if (contentContainer) {
      const contentRect = contentContainer.getBoundingClientRect();
      setCodeLensContentLeft(Math.max(0, contentRect.left - containerRect.left));
      return;
    }

    const monacoContent = container.querySelector<HTMLElement>(".monaco-editor .view-lines");
    if (monacoContent) {
      const contentRect = monacoContent.getBoundingClientRect();
      setCodeLensContentLeft(Math.max(0, contentRect.left - containerRect.left));
      return;
    }

    setCodeLensContentLeft(EDITOR_CONSTANTS.EDITOR_PADDING_LEFT);
  }, []);

  useLayoutEffect(() => {
    const container = editorRef.current;
    if (!container) return;

    measureCodeLensContentLeft();
    const animationFrame = requestAnimationFrame(measureCodeLensContentLeft);
    const resizeObserver = new ResizeObserver(measureCodeLensContentLeft);
    resizeObserver.observe(container);

    return () => {
      cancelAnimationFrame(animationFrame);
      resizeObserver.disconnect();
    };
  }, [activeBufferId, measureCodeLensContentLeft, showToolbar, zoomedFontSize, zoomedLineHeight]);

  // Consolidated LSP document lifecycle
  useLspIntegration({
    enabled: enableRichEditorServices,
    filePath,
    contentRevision: activeBuffer?.contentRevision ?? 0,
  });

  // Rename symbol support
  const rename = useRename(enableRichEditorServices ? filePath : undefined);

  const pythonScriptCells = useMemo(
    () =>
      enableInteractiveServices && isPythonScriptFile(filePath)
        ? getPythonScriptCells(notebookContent)
        : [],
    [enableInteractiveServices, filePath, notebookContent],
  );
  const pythonScriptCellLenses = useMemo<CodeLensItem[]>(
    () =>
      pythonScriptCells.map((cell) => ({
        line: cell.markerLine,
        title: t("run.runCell"),
        command: PYTHON_SCRIPT_CELL_COMMAND,
        arguments: [cell.index],
      })),
    [pythonScriptCells, t],
  );
  const rMarkdownChunks = useMemo(
    () =>
      enableInteractiveServices && isRMarkdownFile(filePath)
        ? getRMarkdownChunks(notebookContent)
        : [],
    [enableInteractiveServices, filePath, notebookContent],
  );
  const rMarkdownChunkLenses = useMemo<CodeLensItem[]>(
    () =>
      rMarkdownChunks.map((chunk) => ({
        line: chunk.markerLine,
        title: t("run.runChunk"),
        command: R_MARKDOWN_CHUNK_COMMAND,
        arguments: [chunk.index],
      })),
    [rMarkdownChunks, t],
  );
  const inlineCodeLenses = useMemo(
    () => (codeLensEnabled ? [...pythonScriptCellLenses, ...rMarkdownChunkLenses] : []),
    [codeLensEnabled, pythonScriptCellLenses, rMarkdownChunkLenses],
  );

  const handleCodeLensExecute = useCallback(
    (lens: { title: string; command?: string; arguments?: unknown[] }) => {
      if (!filePath || !lens.command) return;

      if (lens.command === PYTHON_SCRIPT_CELL_COMMAND) {
        const cellIndex = typeof lens.arguments?.[0] === "number" ? lens.arguments[0] : -1;
        const cell = pythonScriptCells[cellIndex];
        if (!cell) return;

        void invoke<NotebookRunResult>("notebook_run_python_cell", {
          code: cell.code,
          setupCode: cell.setupCode,
          cwd: editorWorkingDirectory(filePath),
        })
          .then((result) => {
            if (result.timedOut) {
              toast.error(t("notebook.pythonCellTimedOut"));
              return;
            }
            if (result.status !== 0 || result.stderr.trim()) {
              toast.error(
                truncateCellOutput(result.stderr || `Python exited with status ${result.status}.`),
              );
              return;
            }
            const stdout = truncateCellOutput(result.stdout);
            if (stdout) {
              toast.success(t("notebook.pythonCellOutput", { output: stdout }));
              return;
            }
            if (result.displayData?.length) {
              toast.success(
                t("notebook.pythonDisplayOutputs", { count: result.displayData.length }),
              );
              return;
            }
            toast.success(t("notebook.pythonCellRan"));
          })
          .catch((error) => {
            toast.error(error instanceof Error ? error.message : t("notebook.pythonCellRunFailed"));
          });
        return;
      }

      if (lens.command === R_MARKDOWN_CHUNK_COMMAND) {
        const chunkIndex = typeof lens.arguments?.[0] === "number" ? lens.arguments[0] : -1;
        const chunk = rMarkdownChunks[chunkIndex];
        if (!chunk) return;

        if (!rMarkdownChunkShouldEvaluate(chunk)) {
          handleEditorContentChange(clearRMarkdownChunkOutput(valueRef.current, chunk));
          toast.success(t("notebook.rChunkSkippedEvalFalse"));
          return;
        }

        void invoke<NotebookRunResult>("notebook_run_r_cell", {
          code: chunk.code,
          setupCode: chunk.setupCode,
          cwd: editorWorkingDirectory(filePath),
        })
          .then((result) => {
            const currentValue = valueRef.current;
            const currentChunk = getRMarkdownChunks(currentValue)[chunkIndex] ?? chunk;
            const semanticResult = applyRMarkdownChunkOptionSemantics(result, currentChunk);
            if (rMarkdownChunkShouldPersistOutput(currentChunk)) {
              handleEditorContentChange(
                updateRMarkdownChunkOutput(
                  currentValue,
                  currentChunk,
                  formatRMarkdownChunkOutput(semanticResult),
                ),
              );
            } else {
              handleEditorContentChange(clearRMarkdownChunkOutput(currentValue, currentChunk));
            }

            if (result.timedOut) {
              toast.error(t("notebook.rChunkTimedOut"));
              return;
            }
            const allowCapturedError = currentChunk.options.error === true;
            if (
              !allowCapturedError &&
              (semanticResult.status !== 0 || semanticResult.stderr.trim())
            ) {
              toast.error(
                truncateCellOutput(
                  semanticResult.stderr || `R exited with status ${semanticResult.status}.`,
                ),
              );
              return;
            }
            const stdout = truncateCellOutput(semanticResult.stdout);
            if (allowCapturedError && semanticResult.stderr.trim()) {
              toast.success(t("notebook.rChunkCapturedErrorOutput"));
              return;
            }
            toast.success(
              stdout ? t("notebook.rChunkOutput", { output: stdout }) : t("notebook.rChunkRan"),
            );
          })
          .catch((error) => {
            toast.error(error instanceof Error ? error.message : t("notebook.rChunkRunFailed"));
          });
        return;
      }
    },
    [filePath, handleEditorContentChange, pythonScriptCells, rMarkdownChunks, t],
  );

  // Keep app-owned overlays aligned with Monaco's scroll position.
  const syncLspOverlayTransform = useCallback((scrollTop: number, scrollLeft: number) => {
    const transform = `translate(-${scrollLeft}px, -${scrollTop}px)`;
    for (const ref of [codeLensRef, renameInputRef]) {
      if (ref.current) {
        ref.current.style.transform = transform;
      }
    }
  }, []);

  // Scroll management
  useEditorScroll(editorRef, null);

  // Handle go-to-line events (from search results, diagnostics, vim, etc.)
  useEffect(() => {
    if (!isActiveSurface) return;
    const goToLine = (lineNumber: number, columnNumber?: number) => {
      if (!editorRef.current) return false;

      const currentContent = valueRef.current;
      if (!currentContent) return false;

      const target = resolveGoToLineTarget({
        content: currentContent,
        lineNumber,
        columnNumber,
        lineCount: useEditorViewStore.getState().actions.getLineCount(),
      });

      editorAPI.setSelection(undefined);
      editorAPI.setCursorPosition({
        line: target.line,
        column: target.column,
        offset: target.offset,
      });

      return true;
    };

    const handleGoToLine = (event: CustomEvent<GoToLineEventDetail>) => {
      const lineNumber = event.detail?.line;
      const columnNumber = event.detail?.column;
      const targetPath = event.detail?.path;
      if (targetPath && !areBufferPathsEqual(targetPath, filePath)) return;
      if (!lineNumber) return;

      // Newly opened buffers mount their editor asynchronously (slower still in
      // debug builds), so keep retrying until the editor accepts the position.
      let attempts = 0;
      const tryGoToLine = () => {
        if (goToLine(lineNumber, columnNumber)) return;
        attempts += 1;
        if (attempts < 10) setTimeout(tryGoToLine, 150);
      };
      tryGoToLine();
    };

    window.addEventListener("menu-go-to-line", handleGoToLine as EventListener);
    return () => {
      window.removeEventListener("menu-go-to-line", handleGoToLine as EventListener);
    };
  }, [filePath, isActiveSurface]);

  if (!activeBuffer) {
    return <div className="flex flex-1 items-center justify-center text-foreground"></div>;
  }

  const monacoEditorProps: MonacoEditorProps = {
    bufferId: activeBufferId ?? undefined,
    viewStateKey: editorViewKey ?? undefined,
    isActiveSurface,
    isPreviewMode: isPreviewBuffer,
    enableExpensiveServices: enableRichEditorServices,
    readOnly,
    scrollable,
    alwaysConsumeMouseWheel: alwaysConsumeMouseWheel,
    backgroundLayer,
    onReadonlySurfaceClick: onReadonlySurfaceClick,
    highlightMatches: highlightMatches,
    currentHighlightIndex: currentHighlightIndex,
    lineNumberStart: lineNumberStart,
    lineNumberMap: lineNumberMap,
    onContentChange: handleEditorContentChange,
    onScrollOffsetChange: syncLspOverlayTransform,
    onModelPositionResolverChange: handleModelPositionResolverChange,
  };

  return (
    <>
      <EditorStylesheet />
      <div className="absolute inset-0 flex flex-col overflow-hidden">
        {/* Breadcrumbs */}
        {showToolbar && (
          <Breadcrumb
            {...breadcrumbProps}
            editorViewKey={editorViewKey}
            bufferId={activeBufferId ?? undefined}
            filePathOverride={breadcrumbProps?.filePathOverride ?? filePath}
            showFilePath={breadcrumbProps?.showFilePath ?? false}
          />
        )}

        {activeBufferId && <ExternalConflictBanner bufferId={activeBufferId} />}

        {tooLargeForEditorServices && enableInteractiveServices && !forceExpensiveServices && (
          <div className="flex items-center justify-between gap-3 border-b border-border bg-muted/40 px-3 py-1.5 text-xs text-muted-foreground">
            <span>{t("editor.largeFileServicesDisabled")}</span>
            <button
              type="button"
              className="shrink-0 font-medium text-foreground underline-offset-2 hover:underline"
              onClick={() => setForceExpensiveServices(true)}
            >
              {t("editor.enableLargeFileServices")}
            </button>
          </div>
        )}

        <div
          ref={editorRef}
          className={`editor-container relative min-h-0 flex-1 overflow-hidden ${className || ""}`}
          data-zoom-level={zoomLevel}
          style={{
            scrollbarWidth: "none",
            msOverflowStyle: "none",
            // Zoom is now applied via font size scaling in Editor component
            // to avoid subpixel rendering mismatches between text and positioned elements
          }}
        >
          {/* Code Lens */}
          {enableCodeLens && !showMarkdownSplit && inlineCodeLenses.length > 0 && (
            <CodeLensOverlay
              ref={codeLensRef}
              lenses={inlineCodeLenses}
              fontSize={zoomedFontSize}
              lineHeight={zoomedLineHeight}
              scrollTop={editorRef.current?.querySelector("textarea")?.scrollTop ?? 0}
              viewportHeight={editorRef.current?.clientHeight ?? 600}
              contentLeft={codeLensContentLeft}
              getLineText={getCodeLensLineText}
              onExecute={handleCodeLensExecute}
              resolveModelPosition={resolveModelPosition}
            />
          )}

          {/* Signature Help */}
          {enableRichEditorServices && (
            <SignatureHelpTooltip
              editorRef={editorRef}
              filePath={filePath}
              resolveModelPosition={resolveModelPosition}
            />
          )}

          {/* Rename Input */}
          {enableRichEditorServices && rename.renameState && (
            <RenameInput
              ref={renameInputRef}
              symbol={rename.renameState.symbol}
              line={rename.renameState.line}
              column={rename.renameState.column}
              fontSize={zoomedFontSize}
              lineHeight={zoomedLineHeight}
              charWidth={zoomedFontSize * 0.6}
              resolveModelPosition={resolveModelPosition}
              inputRef={rename.inputRef}
              onSubmit={(newName) => void rename.executeRename(newName)}
              onCancel={rename.cancelRename}
            />
          )}

          {/* Main editor - absolute positioned to fill container */}
          <div className="absolute inset-0 bg-background">
            {showMarkdownSplit ? (
              <MarkdownSplitEditor editorProps={monacoEditorProps} />
            ) : showMarkdownPreviewSurface || showMarkdownPreview ? (
              <MarkdownPreview />
            ) : showHtmlPreview ? (
              <HtmlPreview />
            ) : showCsvPreview ? (
              <CsvPreview />
            ) : showNotebookEditor ? (
              <NotebookEditor />
            ) : (
              <MonacoEditor {...monacoEditorProps} />
            )}
          </div>
        </div>
      </div>

      {/* Debug overlay for scroll monitoring */}
      {enableInteractiveServices && <ScrollDebugOverlay />}
    </>
  );
};

CodeEditor.displayName = "CodeEditor";

/**
 * In-place Markdown split surface: Monaco on the left, live preview on the
 * right. Split sizes stay in this local layout container so dragging only
 * mutates flexGrow here, and reset when the split closes (session-only,
 * matching the macOS editor area behavior).
 *
 * Scrolling is synchronized proportionally in both directions through
 * MarkdownScrollSyncController, mirroring the macOS editor/preview sync.
 */
function MarkdownSplitEditor({ editorProps }: { editorProps: MonacoEditorProps }) {
  const [sizes, setSizes] = useState<[number, number]>([50, 50]);
  const rightPaneRef = useRef<HTMLDivElement>(null);
  const scrollApiRef = useRef<MonacoEditorScrollApi | null>(null);
  const syncRef = useRef<MarkdownScrollSyncController | null>(null);
  if (!syncRef.current) syncRef.current = new MarkdownScrollSyncController();

  const applyEditorRatioToPreview = useCallback(() => {
    const controller = syncRef.current;
    const api = scrollApiRef.current;
    const preview = rightPaneRef.current?.querySelector<HTMLElement>(".markdown-preview");
    if (!controller || !api || !preview) return;
    if (controller.getSource() === "preview") return;
    const metrics = api.getMetrics();
    const offset = markdownScrollOffset(
      markdownScrollRatio(metrics),
      preview.scrollHeight,
      preview.clientHeight,
    );
    controller.markApplied("preview", offset);
    preview.scrollTop = offset;
  }, []);

  const handleEditorScrollMetrics = useCallback((metrics: MarkdownScrollMetrics) => {
    const controller = syncRef.current;
    if (!controller) return;
    const ratio = controller.report("editor", metrics);
    if (ratio === null) return;
    const preview = rightPaneRef.current?.querySelector<HTMLElement>(".markdown-preview");
    if (!preview) return;
    const offset = markdownScrollOffset(ratio, preview.scrollHeight, preview.clientHeight);
    controller.markApplied("preview", offset);
    preview.scrollTop = offset;
  }, []);

  const handleScrollApiReady = useCallback((api: MonacoEditorScrollApi | null) => {
    scrollApiRef.current = api;
  }, []);

  // Preview -> editor sync. The preview scroll container is inside
  // MarkdownPreview, so listen in the capture phase on the stable pane wrapper.
  useEffect(() => {
    const rightPane = rightPaneRef.current;
    if (!rightPane) return;
    const handlePreviewScroll = (event: Event) => {
      const target = event.target as HTMLElement | null;
      if (!target || !target.classList.contains("markdown-preview")) return;
      const controller = syncRef.current;
      if (!controller) return;
      const ratio = controller.report("preview", {
        scrollTop: target.scrollTop,
        scrollHeight: target.scrollHeight,
        clientHeight: target.clientHeight,
      });
      if (ratio === null) return;
      const api = scrollApiRef.current;
      if (!api) return;
      const metrics = api.getMetrics();
      const offset = markdownScrollOffset(ratio, metrics.scrollHeight, metrics.clientHeight);
      controller.markApplied("editor", offset);
      api.setScrollTop(offset);
    };
    rightPane.addEventListener("scroll", handlePreviewScroll, true);
    return () => rightPane.removeEventListener("scroll", handlePreviewScroll, true);
  }, []);

  // The preview parses its HTML asynchronously, so its content height arrives
  // after mount. Re-anchor the preview to the editor ratio whenever that
  // content resizes while the editor is the sync source.
  useEffect(() => {
    const preview = rightPaneRef.current?.querySelector<HTMLElement>(".markdown-preview");
    if (!preview || typeof ResizeObserver === "undefined") return;
    const content = preview.querySelector<HTMLElement>(".markdown-content");
    if (!content) return;
    const observer = new ResizeObserver(() => applyEditorRatioToPreview());
    observer.observe(content);
    applyEditorRatioToPreview();
    return () => observer.disconnect();
  }, [applyEditorRatioToPreview]);

  return (
    <div className="flex h-full flex-row" data-pane-split-container="true">
      {/* `relative` keeps the absolutely-positioned monaco shell anchored to this pane. */}
      <div
        className="relative min-h-0 min-w-0 overflow-hidden"
        style={{ flexBasis: 0, flexGrow: sizes[0] }}
      >
        <MonacoEditor
          {...editorProps}
          onScrollMetricsChange={handleEditorScrollMetrics}
          onEditorScrollApiReady={handleScrollApiReady}
        />
      </div>
      <PaneResizeHandle
        direction="horizontal"
        initialSizes={sizes}
        resizeHandleCount={1}
        onResize={setSizes}
      />
      <div
        ref={rightPaneRef}
        className="relative min-h-0 min-w-0 overflow-hidden"
        style={{ flexBasis: 0, flexGrow: sizes[1] }}
      >
        <MarkdownPreview />
      </div>
    </div>
  );
}

export default CodeEditor;
