import "../engines/monaco/monaco-environment";
import "monaco-editor/min/vs/editor/editor.main.css";
import "../styles/monaco-editor.css";

import {
  editor as monacoEditor,
  KeyCode,
  KeyMod,
  MarkerSeverity,
  Range as MonacoRange,
} from "monaco-editor";
import type * as Monaco from "monaco-editor";
import { initVimMode, type VimAdapterInstance } from "monaco-vim";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
  type MouseEventHandler,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { useOnClickOutside } from "usehooks-ts";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { useDiagnosticsStore } from "@/features/diagnostics/stores/diagnostics.store";
import type { Diagnostic } from "@/features/diagnostics/types/diagnostics.types";
import { InlineEditPopover } from "@/features/editor/inline-edit/inline-edit-popover";
import { useInlineEdit } from "@/features/editor/inline-edit/use-inline-edit";
import { useInlineEditToolbarStore } from "@/features/editor/stores/inline-edit-toolbar.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useGitBlame } from "@/features/git/hooks/use-git-blame";
import { keymapRegistry } from "@/features/keymaps/utils/registry";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { openMavenRunPane } from "@/features/maven/actions/maven-tool-window-actions";
import {
  canRunMavenTest,
  runMavenTestAction,
} from "@/features/maven/services/maven-test-actions";
import {
  javaTestMethodAtLine,
  type JavaTestMethod,
} from "@/features/maven/utils/maven-test-selection";
import { useJavaTestMethods } from "@/features/maven/hooks/use-java-test-methods";
import { recordStartupMilestone } from "@/features/bootstrap/startup-performance";
import { useVimStore } from "@/features/vim/stores/vim.store";
import { formatRelativeTime } from "@/utils/date";
import { frontendTrace } from "@/utils/frontend-trace";
import { LspOperationLog } from "@/platform/lsp-session-lifecycle";
import { isNativeTextInputTarget } from "@/utils/keyboard/text-input-target";
import { getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";
import EditorContextMenu from "../context-menu/context-menu";
import { useBufferStore } from "../stores/buffer.store";
import { editorBufferSurfacesEqual, selectEditorBufferSurface } from "../stores/buffer-metadata";
import { useJumpListStore } from "../stores/jump-list.store";
import { useEditorStateStore } from "../stores/state.store";
import type {
  EditorContentChangeOptions,
  EditorTextChange,
  Position,
  Range,
} from "../types/editor.types";
import { getBufferById } from "../utils/buffer-index";
import { applyEditorTextChangesToContent } from "../utils/editor-text-change";
import { queueLspDocumentChanges } from "../lsp/pending-document-changes";
import { lspDocumentTargetForEditor } from "../lsp/lsp-document-target";
import { fileOpenBenchmark } from "../utils/file-open-benchmark";
import { isEditorGoToDefinitionModifierClick } from "../utils/go-to-definition-gesture";
import { getLanguageIdFromPath } from "../utils/language-id";
import {
  cursorEntryToRecordAfterMouseGesture,
  type CursorHistoryEntry,
} from "../utils/mouse-cursor-history";
import { toggleCaseText } from "../utils/text-operations";
import { editorAPI } from "../extensions/api";
import {
  persistEditorViewportState,
  restoreNativeEditorViewState,
  scheduleCachedViewStateRestore,
  type NativeEditorViewStateHandle,
} from "../utils/view-state-restore";
import type { MarkdownScrollMetrics } from "../markdown/scroll-sync";
import type { EditorModelPositionResolver } from "../view-model/view-layout";
import { syncContainedEditorFontOptions } from "../engines/monaco/contained-editors";
import { registerMonacoDefinitionLinkGesture } from "../engines/monaco/definition-link";
import {
  consumeLocalContentSnapshot,
  rememberLocalContentSnapshot,
} from "../engines/monaco/content-sync";
import {
  clampMonacoHoverWidgets,
  mutationsContainMonacoHoverWidget,
  syncMonacoHoverBounds,
} from "../engines/monaco/hover-widgets";
import { toMonacoLanguageId } from "../engines/monaco/language";
import { ensureMonacoLanguageTokenizer } from "../engines/monaco/language-contributions";
import {
  createInlineGitBlameWidget,
  type InlineGitBlameWidget,
} from "../engines/monaco/inline-git-blame-widget";
import { acquireMonacoModel } from "../engines/monaco/model-lifecycle";
import { reactivateMonacoModelLanguage } from "../engines/monaco/model-language-activation";
import { getEditorBottomScrollPadding } from "../engines/monaco/scroll-padding";
import { monacoModelMatchesContent } from "../engines/monaco/line-endings";
import { applyMonacoModelContent } from "../engines/monaco/model-content";
import {
  clampMonacoPosition,
  createModelUri,
  toClampedMonacoPosition,
  toEditorPosition,
  toEditorRange,
  toMonacoRange,
} from "../engines/monaco/position";
import { defineActiveMonacoTheme, defineMonacoTheme } from "../engines/monaco/theme";
import { useMonacoEditorSettings } from "../engines/monaco/use-monaco-editor-settings";
import { registerMonacoVimCommands, toEditorVimMode } from "../engines/monaco/vim-commands";
import { registerMonacoLspProviders } from "../engines/monaco/lsp-providers";
import { registerMonacoCodeLensProvider } from "../engines/monaco/code-lens-provider";
import { LspClient } from "../lsp/lsp-client";
import { loadJavaNavigationMarkers } from "../lsp/java-navigation-marker-loader";
import { isTransientJavaMarkerError, normalizeLspError } from "../lsp/lsp-request-error";
import { useLspStore } from "../lsp/stores/lsp.store";
import {
  implementationMarkerAtLine,
  implementationMarkerDecorations,
  implementationMarkersForBuffer,
  javaMarkerRefreshRevision,
  javaMarkerRetryDelay,
  JAVA_IMPLEMENTATION_GLYPH_CLASS,
} from "../engines/monaco/java-implementation-markers";
import type { JavaImplementationMarker } from "../lsp/java-navigation-models";
import { toast } from "sonner";

registerMonacoLspProviders();
registerMonacoCodeLensProvider();

const EMPTY_DIAGNOSTICS: Diagnostic[] = [];
const INACTIVE_CURSOR_POSITION: Position = { line: 0, column: 0, offset: 0 };

function monacoViewStateHandle(
  editor: Monaco.editor.ICodeEditor,
): NativeEditorViewStateHandle {
  return {
    save: () => editor.saveViewState(),
    restore: (state) => {
      editor.restoreViewState(state as Monaco.editor.ICodeEditorViewState);
    },
  };
}

function persistMonacoSurfaceViewState(
  editor: Monaco.editor.IStandaloneCodeEditor,
  viewKey: string,
): void {
  if (!viewKey) return;

  const cached = useEditorStateStore.getState().actions.getCachedViewState(viewKey);
  const scroll = persistEditorViewportState({
    viewKey,
    liveScroll: {
      scrollTop: editor.getScrollTop(),
      scrollLeft: editor.getScrollLeft(),
    },
    cached: cached
      ? { scrollTop: cached.scrollTop, scrollLeft: cached.scrollLeft }
      : null,
    native: monacoViewStateHandle(editor),
  });
  const model = editor.getModel();
  const position = editor.getPosition();
  const selection = editor.getSelection();

  useEditorStateStore.getState().actions.cacheViewStateForBuffer(viewKey, {
    cursor:
      model && position
        ? toEditorPosition(model, position)
        : (cached?.cursor ?? { line: 0, column: 0, offset: 0 }),
    selection:
      model && selection && !selection.isEmpty()
        ? toEditorRange(model, selection)
        : cached?.selection,
    scrollTop: scroll.scrollTop,
    scrollLeft: scroll.scrollLeft,
  });
}

function applyMonacoSurfaceViewState(
  editor: Monaco.editor.IStandaloneCodeEditor,
  viewKey: string,
): void {
  if (!viewKey) return;

  const cached = useEditorStateStore.getState().actions.getCachedViewState(viewKey);
  const restoredNative = restoreNativeEditorViewState(viewKey, monacoViewStateHandle(editor));
  if (!restoredNative && cached) {
    const model = editor.getModel();
    if (model) {
      editor.setPosition(toClampedMonacoPosition(model, cached.cursor));
      if (cached.selection) editor.setSelection(toMonacoRange(model, cached.selection));
    }
  }
  if (!cached) return;
  if (restoredNative && cached.scrollTop === 0 && cached.scrollLeft === 0) {
    return;
  }
  editor.setScrollPosition({
    scrollTop: cached.scrollTop,
    scrollLeft: cached.scrollLeft,
  });
}

/** Imperative scroll access for embedders that mirror editor scrolling. */
export interface MonacoEditorScrollApi {
  getMetrics: () => MarkdownScrollMetrics;
  setScrollTop: (scrollTop: number) => void;
}

export interface MonacoEditorProps {
  bufferId?: string;
  paneId?: string;
  viewStateKey?: string;
  isActiveSurface?: boolean;
  isPreviewMode?: boolean;
  enableExpensiveServices?: boolean;
  readOnly?: boolean;
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
  onScrollOffsetChange?: (scrollTop: number, scrollLeft: number) => void;
  /** Reports viewport scroll metrics on every editor scroll event. */
  onScrollMetricsChange?: (metrics: MarkdownScrollMetrics) => void;
  /**
   * Hands out imperative scroll access once the editor exists, and null when
   * it is disposed. Kept as a callback so embedders never depend on editor
   * instance lifecycles.
   */
  onEditorScrollApiReady?: (api: MonacoEditorScrollApi | null) => void;
  onModelPositionResolverChange?: (resolver: EditorModelPositionResolver | null) => void;
  onMouseMove?: MouseEventHandler<HTMLDivElement>;
  onMouseLeave?: () => void;
  onMouseEnter?: () => void;
  onClick?: MouseEventHandler<HTMLDivElement>;
  className?: string;
}

export function MonacoEditor({
  bufferId: propBufferId,
  paneId,
  viewStateKey,
  isActiveSurface = true,
  isPreviewMode = false,
  enableExpensiveServices = true,
  readOnly = false,
  scrollable = true,
  alwaysConsumeMouseWheel = true,
  backgroundLayer,
  onReadonlySurfaceClick,
  highlightMatches,
  currentHighlightIndex,
  lineNumberStart,
  lineNumberMap,
  onContentChange,
  onScrollOffsetChange,
  onScrollMetricsChange,
  onEditorScrollApiReady,
  onModelPositionResolverChange,
  onMouseMove,
  onMouseLeave,
  onMouseEnter,
  onClick,
  className,
}: MonacoEditorProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<Monaco.editor.IStandaloneCodeEditor | null>(null);
  const modelRef = useRef<Monaco.editor.ITextModel | null>(null);
  const vimAdapterRef = useRef<VimAdapterInstance | null>(null);
  const vimStatusRef = useRef<HTMLDivElement | null>(null);
  const applyingExternalChangeRef = useRef(false);
  const previousContentRef = useRef("");
  const pendingLocalContentSnapshotsRef = useRef<string[]>([]);
  const decorationsRef = useRef<string[]>([]);
  const implementationDecorationsRef = useRef<Monaco.editor.IEditorDecorationsCollection | null>(
    null,
  );
  const implementationMarkerOwnerRef = useRef<string | null>(null);
  const implementationMarkersRef = useRef<JavaImplementationMarker[]>([]);
  const gitBlameWidgetRef = useRef<InlineGitBlameWidget | null>(null);
  const gitBlameRenderFrameRef = useRef<number | null>(null);
  const renderedGitBlameKeyRef = useRef<string | null>(null);
  const javaTestMethodsRef = useRef<JavaTestMethod[]>([]);
  const renderInlineGitBlameRef = useRef<() => void>(() => {});
  const mouseSelectingRef = useRef(false);
  const mouseGestureStartRef = useRef<CursorHistoryEntry | null>(null);
  const suppressNextCursorSelectionSyncRef = useRef(false);
  const restoringViewStateRef = useRef(false);
  const latestContentChangeRef = useRef(onContentChange);
  const isActiveSurfaceRef = useRef(isActiveSurface);
  const onScrollMetricsChangeRef = useRef(onScrollMetricsChange);
  const onEditorScrollApiReadyRef = useRef(onEditorScrollApiReady);
  // Read inside the editor-creation effect's long-lived closures. The flag flips
  // on every tab switch (it derives from `isActiveSurface`); keeping it out of
  // that effect's dependencies avoids disposing and rebuilding the whole Monaco
  // editor — and re-tokenizing the file from scratch — on each switch. Option
  // changes are applied by the dedicated `updateOptions` effect instead.
  const enableExpensiveServicesRef = useRef(enableExpensiveServices);
  const activeBufferId = useBufferStore((state) => propBufferId ?? state.activeBufferId);
  const buffer = useBufferStore(
    useCallback(
      (state) => selectEditorBufferSurface(state.buffers, activeBufferId),
      [activeBufferId],
    ),
    editorBufferSurfacesEqual,
  );
  const editorBuffer = buffer?.type === "editor" ? buffer : null;
  const editorBufferId = editorBuffer?.id;
  const contentRevision = editorBuffer?.contentRevision ?? 0;
  const content = useMemo(() => {
    if (!editorBufferId) return "";
    const current = getBufferById(useBufferStore.getState().buffers, editorBufferId);
    return current && current.type === "editor" ? (current.content ?? "") : "";
  }, [contentRevision, editorBufferId]);
  const filePath = editorBuffer?.path ?? "";
  const editorLanguage = editorBuffer?.language;
  const editorLanguageOverride = editorBuffer?.languageOverride;
  const documentUri = editorBuffer?.lspDocument?.documentUri;
  const sessionFilePath = editorBuffer?.lspDocument?.sessionFilePath;
  const documentLanguageId = editorBuffer?.lspDocument?.languageId;
  const documentTarget = useMemo(
    () =>
      editorBufferId
        ? lspDocumentTargetForEditor({
            path: filePath,
            language: editorLanguage,
            languageOverride: editorLanguageOverride,
            lspDocument:
              documentUri && sessionFilePath && documentLanguageId
                ? {
                    documentUri,
                    sessionFilePath,
                    languageId: documentLanguageId,
                  }
                : undefined,
          })
        : { filePath },
    [
      documentLanguageId,
      documentUri,
      editorBufferId,
      editorLanguage,
      editorLanguageOverride,
      filePath,
      sessionFilePath,
    ],
  );
  const languageId = documentTarget.languageId ?? getLanguageIdFromPath(filePath);
  const monacoLanguageId = toMonacoLanguageId(languageId);
  const [mavenTestsAvailable, setMavenTestsAvailable] = useState(false);
  const javaTestMethods = useJavaTestMethods(filePath, content, mavenTestsAvailable);
  javaTestMethodsRef.current = javaTestMethods;
  const {
    fontFamily,
    fontSize,
    lineHeight,
    tabSize,
    wordWrap,
    lineNumbers,
    renderWhitespace,
    renderIndentGuides,
    highlightOccurrences,
    editorFontLigatures,
    editorItalicComments,
    editorStickyScroll,
    editorBracketPairColorization,
    editorSmoothScrolling,
    editorScrollBeyondLastLine,
    editorCursorStyle,
    editorCursorBlinking,
    themeId,
  } = useMonacoEditorSettings();
  const minimapEnabled = useSettingsStore((state) => state.settings.showMinimap);
  const autoCompletion = useSettingsStore((state) => state.settings.autoCompletion);
  const parameterHints = useSettingsStore((state) => state.settings.parameterHints);
  const codeLens = useSettingsStore((state) => state.settings.codeLens);
  const inlayHints = useSettingsStore((state) => state.settings.inlayHints);
  const semanticTokens = useSettingsStore((state) => state.settings.semanticTokens);
  const javaMarkerRevision = useLspStore((state) =>
    javaMarkerRefreshRevision(state.lspStatus),
  );
  const inlineGitBlameEnabled = useSettingsStore((state) => state.settings.enableInlineGitBlame);
  const workspaceId = useActiveWorkspaceId();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const workspaceFolders = useFileSystemStore((state) => state.workspaceFolders);
  const vimModeEnabled = useSettingsStore((state) => state.settings.vimMode);
  const vimRelativeLineNumbers = useSettingsStore((state) => state.settings.vimRelativeLineNumbers);
  const vimCurrentMode = useVimStore.use.mode();
  const inlineEditRequested = useInlineEditToolbarStore.use.isVisible();
  const cursorPosition = useEditorStateStore((state) =>
    isActiveSurface && vimModeEnabled && vimRelativeLineNumbers
      ? state.cursorPosition
      : INACTIVE_CURSOR_POSITION,
  );
  const selection = useEditorStateStore((state) =>
    isActiveSurface && inlineEditRequested ? state.selection : undefined,
  );
  const {
    setCursorPosition,
    setSelection,
    setCursorAndSelection,
    setScrollForBuffer,
    setViewportHeight,
  } = useEditorStateStore.use.actions();
  const { getBlameForLine } = useGitBlame(
    isActiveSurface && enableExpensiveServices && inlineGitBlameEnabled && filePath
      ? filePath
      : undefined,
  );

  const renderInlineGitBlame = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model || model.isDisposed()) return;
    if (mouseSelectingRef.current) return;

    const widget = gitBlameWidgetRef.current ?? createInlineGitBlameWidget(editor);
    gitBlameWidgetRef.current = widget;

    const hideBlame = () => {
      renderedGitBlameKeyRef.current = null;
      widget.hide();
    };

    if (!inlineGitBlameEnabled || !isActiveSurface || !filePath) {
      hideBlame();
      return;
    }

    const position = editor.getPosition();
    const lineNumber = position?.lineNumber ?? 0;
    if (lineNumber < 1 || lineNumber > model.getLineCount()) {
      hideBlame();
      return;
    }

    const blameLine = getBlameForLine(lineNumber - 1);
    if (!blameLine) {
      hideBlame();
      return;
    }

    const blameContent = blameLine.is_uncommitted
      ? "  Uncommitted changes"
      : `  ${blameLine.author}, ${formatRelativeTime(blameLine.time)}`;
    const decorationKey = `${filePath}:${lineNumber}:${blameLine.commit_hash}:${blameContent}`;
    if (renderedGitBlameKeyRef.current === decorationKey) return;

    widget.show(lineNumber, model.getLineMaxColumn(lineNumber), blameContent);
    renderedGitBlameKeyRef.current = decorationKey;
  }, [filePath, getBlameForLine, inlineGitBlameEnabled, isActiveSurface]);
  renderInlineGitBlameRef.current = renderInlineGitBlame;

  const scheduleInlineGitBlameRender = useCallback(() => {
    if (mouseSelectingRef.current) return;
    if (gitBlameRenderFrameRef.current !== null) return;
    gitBlameRenderFrameRef.current = requestAnimationFrame(() => {
      gitBlameRenderFrameRef.current = null;
      renderInlineGitBlameRef.current();
    });
  }, []);
  const diagnosticsForFile = useDiagnosticsStore((state) =>
    filePath ? (state.diagnosticsByFile.get(filePath) ?? EMPTY_DIAGNOSTICS) : EMPTY_DIAGNOSTICS,
  );

  const modelDisplayPath = useMemo(() => {
    const workspaceRoot = [rootFolderPath, ...workspaceFolders.map((folder) => folder.path)]
      .filter((path): path is string => Boolean(path && pathStartsWithRoot(filePath, path)))
      .sort((left, right) => right.length - left.length)[0];
    return getRelativePath(filePath, workspaceRoot);
  }, [filePath, rootFolderPath, workspaceFolders]);

  useEffect(() => {
    if (!rootFolderPath || !filePath || !/\.java$/i.test(filePath)) {
      setMavenTestsAvailable(false);
      return;
    }

    let cancelled = false;
    setMavenTestsAvailable(false);
    void canRunMavenTest(rootFolderPath, filePath).then((available) => {
      if (!cancelled) setMavenTestsAvailable(available);
    });

    return () => {
      cancelled = true;
    };
  }, [filePath, rootFolderPath]);
  const modelUri = useMemo(
    () => createModelUri(activeBufferId ?? undefined, filePath, modelDisplayPath),
    [activeBufferId, filePath, modelDisplayPath],
  );

  latestContentChangeRef.current = onContentChange;
  isActiveSurfaceRef.current = isActiveSurface;
  onScrollMetricsChangeRef.current = onScrollMetricsChange;
  onEditorScrollApiReadyRef.current = onEditorScrollApiReady;
  enableExpensiveServicesRef.current = enableExpensiveServices;

  const isCurrentEditorSurface = useCallback(() => {
    if (!isActiveSurfaceRef.current) return false;
    if (editorBufferId && useBufferStore.getState().activeBufferId !== editorBufferId) {
      return false;
    }

    const activeViewKey = useEditorStateStore.getState().activeEditorViewKey;
    return !viewStateKey || !activeViewKey || activeViewKey === viewStateKey;
  }, [editorBufferId, viewStateKey]);

  const lineNumberFormatter = useCallback(
    (lineNumber: number) => {
      const mappedLine = lineNumberMap?.[lineNumber - 1];
      if (typeof mappedLine === "number") return String(mappedLine);
      if (vimModeEnabled && vimRelativeLineNumbers && !lineNumberMap) {
        const cursorLine = useEditorStateStore.getState().cursorPosition.line + 1;
        const distance = Math.abs(lineNumber - cursorLine);
        if (distance > 0) return String(distance);
      }
      return String((lineNumberStart ?? 1) + lineNumber - 1);
    },
    [lineNumberMap, lineNumberStart, vimModeEnabled, vimRelativeLineNumbers],
  );

  const syncCursorAndSelection = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model || !isCurrentEditorSurface()) return;

    const position = editor.getPosition();
    if (!position) return;
    const selection = editor.getSelection();
    setCursorAndSelection(
      toEditorPosition(model, position),
      selection ? toEditorRange(model, selection) : undefined,
    );
  }, [isCurrentEditorSurface, setCursorAndSelection]);

  const getMonacoCursorOffset = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    const position = editor?.getPosition();
    if (!model || !position) return null;
    return model.getOffsetAt(position);
  }, []);

  const getMonacoSelectionAnchor = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    const currentSelection = editor?.getSelection();
    if (!model || !currentSelection) return null;

    return toEditorPosition(model, currentSelection.getPosition());
  }, []);

  const getMonacoViewportMetrics = useCallback(() => {
    const editor = editorRef.current;
    if (!editor) return null;
    const layout = editor.getLayoutInfo();
    return {
      scrollTop: 0,
      scrollLeft: 0,
      viewportWidth: layout.width,
      viewportHeight: layout.height,
    };
  }, []);

  const applyMonacoInlineEdit = useCallback(
    (edit: { range: Range; editedText: string; newCursorOffset: number }) => {
      const editor = editorRef.current;
      const model = modelRef.current;
      if (!editor || !model) return;

      editor.pushUndoStop();
      editor.executeEdits("inline-edit", [
        {
          range: toMonacoRange(model, edit.range),
          text: edit.editedText,
          forceMoveMarkers: true,
        },
      ]);
      const nextPosition = model.getPositionAt(edit.newCursorOffset);
      editor.setSelection(
        new MonacoRange(
          nextPosition.lineNumber,
          nextPosition.column,
          nextPosition.lineNumber,
          nextPosition.column,
        ),
      );
      editor.setPosition(nextPosition);
      editor.revealPositionInCenterIfOutsideViewport(nextPosition);
      editor.pushUndoStop();
      syncCursorAndSelection();
    },
    [syncCursorAndSelection],
  );

  const inlineEditState = useInlineEdit({
    enabled: isActiveSurface && !readOnly && !isPreviewMode,
    viewKey: viewStateKey ?? activeBufferId ?? null,
    buffer: editorBuffer
      ? {
          id: editorBuffer.id,
          content,
          path: editorBuffer.path,
          language: languageId ?? "",
          getContent: () => previousContentRef.current || content,
        }
      : undefined,
    selection,
    fontSize,
    fontFamily,
    lineHeight,
    tabSize,
    lastScrollRef: { current: { top: 0, left: 0 } } as React.RefObject<{
      top: number;
      left: number;
    }>,
    resolveModelPosition: (line, column) => {
      const editor = editorRef.current;
      const model = modelRef.current;
      if (!editor || !model || model.isDisposed()) return null;
      const position = clampMonacoPosition(model, {
        lineNumber: line + 1,
        column: column + 1,
      });
      const top = editor.getTopForLineNumber(position.lineNumber) - editor.getScrollTop();
      const left =
        editor.getOffsetForColumn(position.lineNumber, position.column) - editor.getScrollLeft();
      const lineLength = model.getLineLength(position.lineNumber);
      const modelLine = position.lineNumber - 1;
      return {
        ...toEditorPosition(model, position),
        viewLine: modelLine,
        modelLine,
        top,
        left,
        height: lineHeight,
        segment: {
          viewLine: modelLine,
          modelLine,
          startColumn: 0,
          endColumn: lineLength,
          top,
          height: lineHeight,
        },
      };
    },
    getCursorOffset: getMonacoCursorOffset,
    getSelectionAnchor: getMonacoSelectionAnchor,
    getViewportMetrics: getMonacoViewportMetrics,
    applyInlineEdit: applyMonacoInlineEdit,
    setCursorPosition,
    setSelection,
  });
  const [contextMenuPosition, setContextMenuPosition] = useState<{
    x: number;
    y: number;
  } | null>(null);
  const [contextMenuTestMethod, setContextMenuTestMethod] = useState<JavaTestMethod | null>(null);
  const [implementationMarkers, setImplementationMarkers] = useState<JavaImplementationMarker[]>(
    [],
  );

  const executeEditorCommand = useCallback((commandId: string) => {
    void keymapRegistry.executeCommand(commandId);
  }, []);

  const runMavenTestFromEditor = useCallback(
    (method?: string) => {
      if (!filePath) return;
      setContextMenuPosition(null);
      setContextMenuTestMethod(null);
      openMavenRunPane();
      void runMavenTestAction(filePath, method, workspaceId).catch((error) => {
        toast.error(error instanceof Error ? error.message : "Unable to run Maven test.");
      });
    },
    [filePath, workspaceId],
  );

  const runTestClassFromEditor = useCallback(() => {
    runMavenTestFromEditor();
  }, [runMavenTestFromEditor]);

  const runTestMethodFromEditor = useCallback(() => {
    const method = contextMenuTestMethod?.name;
    if (!method) return;
    runMavenTestFromEditor(method);
  }, [contextMenuTestMethod, runMavenTestFromEditor]);

  const triggerMonacoAction = useCallback(
    (actionId: string) => {
      const editor = editorRef.current;
      if (!editor) return;

      editor.trigger("lithe-context-menu", actionId, null);
      editor.focus();
      syncCursorAndSelection();
    },
    [syncCursorAndSelection],
  );

  const toggleMonacoSelectionCase = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    const selection = editor?.getSelection();
    if (!editor || !model || !selection || selection.isEmpty()) return;

    const startOffset = model.getOffsetAt(selection.getStartPosition());
    const endOffset = model.getOffsetAt(selection.getEndPosition());
    const result = toggleCaseText(model.getValue(), startOffset, endOffset);
    const replacement = result.content.slice(result.selectionStart, result.selectionEnd);

    editor.pushUndoStop();
    editor.executeEdits("lithe-context-menu", [
      { range: selection, text: replacement, forceMoveMarkers: true },
    ]);
    editor.setSelection(selection);
    editor.pushUndoStop();
    editor.focus();
    syncCursorAndSelection();
  }, [syncCursorAndSelection]);

  const selectEntireModel = useCallback(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model) return;

    editor.setSelection(model.getFullModelRange());
    editor.focus();
    syncCursorAndSelection();
  }, [syncCursorAndSelection]);

  const runMonacoSelectionAction = useCallback(
    (actionId: string) => {
      const editor = editorRef.current;
      if (!editor) return;

      editor.trigger("lithe-keybinding", actionId, null);
      editor.focus();
      syncCursorAndSelection();
    },
    [syncCursorAndSelection],
  );

  const executeMonacoTextEdit = useCallback(
    (range: Monaco.Range, text: string) => {
      const editor = editorRef.current;
      const model = modelRef.current;
      if (!editor || !model) return;

      const startOffset = model.getOffsetAt(range.getStartPosition());
      editor.pushUndoStop();
      editor.executeEdits("lithe-api", [{ range, text, forceMoveMarkers: true }]);
      const nextPosition = model.getPositionAt(startOffset + text.length);
      editor.setSelection(
        new MonacoRange(
          nextPosition.lineNumber,
          nextPosition.column,
          nextPosition.lineNumber,
          nextPosition.column,
        ),
      );
      editor.setPosition(nextPosition);
      editor.pushUndoStop();
      syncCursorAndSelection();
    },
    [syncCursorAndSelection],
  );

  useOnClickOutside(inlineEditState.inlineEditPopoverRef as RefObject<HTMLElement>, (event) => {
    if (!inlineEditState.inlineEditVisible) return;
    const target = event.target as HTMLElement | null;
    if (
      target?.closest(".inline-edit-model-selector-menu") ||
      target?.closest(".inline-edit-model-command")
    ) {
      return;
    }
    inlineEditState.inlineEditToolbarActions.hide();
  });

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container || !editorBufferId) return;
    restoringViewStateRef.current = true;
    const fontOptions = { fontFamily, fontSize, lineHeight };
    syncMonacoHoverBounds(container);
    if (filePath && fileOpenBenchmark.has(filePath)) {
      fileOpenBenchmark.mark(filePath, "monaco-create-start");
    }
    const languageTokenizerPromise = ensureMonacoLanguageTokenizer(monacoLanguageId).catch(
      (error) => {
        console.error(`Failed to load Monaco tokenizer for ${monacoLanguageId}:`, error);
        return false;
      },
    );

    const acquiredModel = acquireMonacoModel(content, monacoLanguageId, modelUri);
    const model = acquiredModel.model;
    const editor = monacoEditor.create(container, {
      model,
      automaticLayout: true,
      fontFamily,
      fontSize,
      lineHeight,
      tabSize,
      insertSpaces: true,
      readOnly: readOnly || isPreviewMode,
      domReadOnly: readOnly || isPreviewMode,
      minimap: { enabled: minimapEnabled },
      fontLigatures: editorFontLigatures,
      // Geist Mono is a variable font; Windows DPI plus Monaco's default
      // monospace width cache places the caret one column left of the click.
      disableMonospaceOptimizations: true,
      selectOnLineNumbers: true,
      glyphMargin: enableExpensiveServicesRef.current && monacoLanguageId === "java",
      stickyScroll: { enabled: editorStickyScroll },
      bracketPairColorization: { enabled: editorBracketPairColorization },
      smoothScrolling: editorSmoothScrolling,
      scrollBeyondLastLine: editorScrollBeyondLastLine,
      padding: { bottom: getEditorBottomScrollPadding(container.clientHeight) },
      lineNumbers: lineNumbers ? lineNumberFormatter : "off",
      renderWhitespace: renderWhitespace === "none" ? "none" : renderWhitespace,
      wordWrap: wordWrap ? "on" : "off",
      guides: {
        indentation: renderIndentGuides,
        highlightActiveIndentation: renderIndentGuides,
      },
      occurrencesHighlight: highlightOccurrences ? "singleFile" : "off",
      selectionHighlight: highlightOccurrences,
      quickSuggestions: autoCompletion,
      suggestOnTriggerCharacters: autoCompletion,
      // Expensive-service options are read from the ref so this effect stays
      // stable across active-surface flips; the dedicated `updateOptions` effect
      // below re-applies them whenever the live value changes.
      parameterHints: { enabled: enableExpensiveServicesRef.current && parameterHints },
      codeLens: enableExpensiveServicesRef.current && codeLens,
      inlayHints: { enabled: enableExpensiveServicesRef.current && inlayHints ? "on" : "off" },
      theme: defineMonacoTheme(themeId, editorItalicComments),
      cursorStyle: vimModeEnabled && vimCurrentMode === "normal" ? "block" : editorCursorStyle,
      cursorBlinking:
        vimModeEnabled && vimCurrentMode === "normal" ? "solid" : editorCursorBlinking,
      contextmenu: false,
      overviewRulerLanes: 0,
      fixedOverflowWidgets: false,
      "semanticHighlighting.enabled": enableExpensiveServicesRef.current && semanticTokens,
      scrollbar: {
        vertical: scrollable ? "auto" : "hidden",
        horizontal: scrollable ? "auto" : "hidden",
        handleMouseWheel: scrollable,
        alwaysConsumeMouseWheel: scrollable && alwaysConsumeMouseWheel,
      },
    });

    editorRef.current = editor;
    modelRef.current = model;
    const implementationDecorations = editor.createDecorationsCollection();
    implementationDecorationsRef.current = implementationDecorations;
    previousContentRef.current = content;
    pendingLocalContentSnapshotsRef.current = [];
    if (filePath && fileOpenBenchmark.has(filePath)) {
      fileOpenBenchmark.mark(filePath, "monaco-created", `${model.getLineCount()} lines`);
    }
    let benchmarkRafId: number | null = null;
    let benchmarkTimeoutId: number | null = null;
    let benchmarkFinished = false;
    const getBenchmarkTokenTypes = () =>
      Array.from(
        new Set(
          monacoEditor
            .tokenize(content.slice(0, 4_096), model.getLanguageId())
            .flatMap((line) => line.map((token) => token.type))
            .filter(Boolean),
        ),
      ).slice(0, 12);
    const finishBenchmark = () => {
      if (benchmarkFinished) return;
      benchmarkFinished = true;
      if (benchmarkRafId !== null) cancelAnimationFrame(benchmarkRafId);
      if (benchmarkTimeoutId !== null) window.clearTimeout(benchmarkTimeoutId);
      if (!filePath || !fileOpenBenchmark.has(filePath) || model.isDisposed()) return;
      const benchmarkTokenTypes = getBenchmarkTokenTypes();
      fileOpenBenchmark.finish(filePath, "editor-ready", `${content.length} chars`, {
        contentLength: content.length,
        lineCount: model.getLineCount(),
        largeContentMode: false,
        languageId: model.getLanguageId(),
        themeId,
        tokenTypes: benchmarkTokenTypes,
      });
      recordStartupMilestone("editor:first-ready");
    };
    void languageTokenizerPromise.then((loaded) => {
      if (model.isDisposed()) return;
      if (loaded) {
        reactivateMonacoModelLanguage(model, monacoLanguageId, (target, language) => {
          monacoEditor.setModelLanguage(target as Monaco.editor.ITextModel, language);
        });
      }
      const tokenTypes = getBenchmarkTokenTypes();
      frontendTrace(tokenTypes.length > 0 ? "info" : "error", "bench:syntax", filePath, {
        languageId: model.getLanguageId(),
        themeId,
        tokenTypes,
      });
      if (filePath && fileOpenBenchmark.has(filePath)) {
        fileOpenBenchmark.mark(
          filePath,
          "syntax-ready",
          loaded ? model.getLanguageId() : "built-in",
        );
      }
      if (document.visibilityState === "visible") {
        benchmarkRafId = requestAnimationFrame(finishBenchmark);
        benchmarkTimeoutId = window.setTimeout(finishBenchmark, 100);
      } else {
        benchmarkTimeoutId = window.setTimeout(finishBenchmark, 0);
      }
    });

    let hoverClampRaf: number | null = null;
    const scheduleMonacoHoverClamp = () => {
      if (hoverClampRaf !== null) return;
      hoverClampRaf = requestAnimationFrame(() => {
        hoverClampRaf = null;
        clampMonacoHoverWidgets(container);
      });
    };
    const hoverMutationObserver = new MutationObserver((mutations) => {
      if (mutationsContainMonacoHoverWidget(mutations)) scheduleMonacoHoverClamp();
    });
    hoverMutationObserver.observe(container, {
      childList: true,
      subtree: true,
    });
    const hoverResizeObserver = new ResizeObserver(scheduleMonacoHoverClamp);
    hoverResizeObserver.observe(container);
    scheduleMonacoHoverClamp();

    let bottomScrollPadding = getEditorBottomScrollPadding(container.clientHeight);
    const syncBottomScrollPadding = (viewportHeight: number) => {
      const nextBottomScrollPadding = getEditorBottomScrollPadding(viewportHeight);
      if (nextBottomScrollPadding === bottomScrollPadding) return;
      bottomScrollPadding = nextBottomScrollPadding;
      editor.updateOptions({ padding: { bottom: bottomScrollPadding } });
    };

    const syncNestedEditorFonts = () => syncContainedEditorFontOptions(container, fontOptions);
    const createdEditorDisposable = monacoEditor.onDidCreateEditor((createdEditor) => {
      requestAnimationFrame(() => {
        const editorElement = createdEditor.getDomNode();
        if (!editorElement || !container.contains(editorElement)) return;
        createdEditor.updateOptions(fontOptions);
      });
    });
    requestAnimationFrame(syncNestedEditorFonts);

    const scrollApi: MonacoEditorScrollApi = {
      getMetrics: () => ({
        scrollTop: editor.getScrollTop(),
        scrollHeight: editor.getScrollHeight(),
        clientHeight: editor.getLayoutInfo().height,
      }),
      setScrollTop: (scrollTop) => {
        editor.setScrollTop(scrollTop);
      },
    };
    onEditorScrollApiReadyRef.current?.(scrollApi);

    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyA, selectEntireModel);
    const definitionLinkGesture = registerMonacoDefinitionLinkGesture({
      editor,
      model,
      documentTarget,
      workspaceScope: rootFolderPath ? { workspaceId, root: rootFolderPath } : undefined,
      isEnabled: () => enableExpensiveServicesRef.current,
    });
    let definitionClickIntent = 0;
    const cursorEntryFromEditor = (): CursorHistoryEntry | null => {
      const position = editor.getPosition();
      if (!position || !editorBufferId || !filePath) return null;

      return {
        bufferId: editorBufferId,
        filePath,
        paneId,
        ...toEditorPosition(model, position),
        scrollTop: editor.getScrollTop(),
        scrollLeft: editor.getScrollLeft(),
      };
    };
    const handleNativeMouseDownCapture = (event: MouseEvent) => {
      if (event.button !== 0) return;
      mouseSelectingRef.current = true;
      mouseGestureStartRef.current = cursorEntryFromEditor();
    };
    container.addEventListener("mousedown", handleNativeMouseDownCapture, true);

    const handleWindowSelectAllShortcut = (event: KeyboardEvent) => {
      const isSelectAllShortcut =
        (event.metaKey || event.ctrlKey) &&
        !event.altKey &&
        !event.shiftKey &&
        event.key.toLowerCase() === "a";

      if (!isSelectAllShortcut) return;

      const target = event.target;
      const activeElement = document.activeElement;
      if (isNativeTextInputTarget(target, activeElement)) return;

      const isInsideEditor =
        editor.hasTextFocus() ||
        (target instanceof Node && container.contains(target)) ||
        (activeElement instanceof Node && container.contains(activeElement));

      if (!isInsideEditor) {
        const targetElement = target instanceof HTMLElement ? target : null;
        if (targetElement?.closest(".terminal-container")) return;
        if (!isActiveSurfaceRef.current) return;
      }

      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      selectEntireModel();
    };

    window.addEventListener("keydown", handleWindowSelectAllShortcut, true);

    const disposables = [
      editor.onContextMenu((event) => {
        event.event.preventDefault();
        event.event.stopPropagation();
        setContextMenuTestMethod(null);

        if (event.target.position) {
          setContextMenuTestMethod(
            /\.java$/i.test(filePath)
              ? javaTestMethodAtLine(
                  javaTestMethodsRef.current,
                  event.target.position.lineNumber - 1,
                )
              : null,
          );
          const currentSelection = editor.getSelection();
          if (!currentSelection?.containsPosition(event.target.position)) {
            editor.setPosition(event.target.position);
            editor.setSelection(
              new MonacoRange(
                event.target.position.lineNumber,
                event.target.position.column,
                event.target.position.lineNumber,
                event.target.position.column,
              ),
            );
            syncCursorAndSelection();
          }
        }

        editor.focus();
        setContextMenuPosition({ x: event.event.posx, y: event.event.posy });
      }),
      editor.onKeyDown((event) => {
        const browserEvent = event.browserEvent;
        const isSelectAllShortcut =
          (browserEvent.metaKey || browserEvent.ctrlKey) &&
          !browserEvent.altKey &&
          !browserEvent.shiftKey &&
          browserEvent.key.toLowerCase() === "a";

        if (!isSelectAllShortcut) return;

        event.preventDefault();
        event.stopPropagation();
        selectEntireModel();
      }),
      editor.onDidChangeModelContent((event) => {
        if (applyingExternalChangeRef.current) return;
        const contentChanges: EditorTextChange[] = event.changes.map((change) => ({
          rangeOffset: change.rangeOffset,
          rangeLength: change.rangeLength,
          text: change.text,
          startLine: change.range.startLineNumber - 1,
          startColumn: change.range.startColumn - 1,
          endLine: change.range.endLineNumber - 1,
          endColumn: change.range.endColumn - 1,
        }));
        const previousContent = previousContentRef.current;
        const nextContent = applyEditorTextChangesToContent(previousContent, contentChanges);
        const editorState = useEditorStateStore.getState();
        previousContentRef.current = nextContent;
        rememberLocalContentSnapshot(pendingLocalContentSnapshotsRef.current, nextContent);
        if (filePath && enableExpensiveServicesRef.current) {
          queueLspDocumentChanges(filePath, contentChanges);
        }
        latestContentChangeRef.current?.(
          nextContent,
          previousContent,
          editorState.cursorPosition,
          editorState.selection,
          {
            contentChange: contentChanges[0],
            contentChanges,
          },
        );
        syncCursorAndSelection();
      }),
      editor.onMouseDown((event) => {
        if (!isCurrentEditorSurface()) return;
        const mouseEvent = event.event;
        const markerElement = event.target.element;
        if (
          event.target.type === monacoEditor.MouseTargetType.GUTTER_GLYPH_MARGIN &&
          event.target.position &&
          markerElement?.classList.contains(JAVA_IMPLEMENTATION_GLYPH_CLASS)
        ) {
          const marker = implementationMarkerAtLine(
            implementationMarkersRef.current,
            event.target.position.lineNumber,
            event.target.detail.glyphMarginLane,
          );
          if (marker) {
            mouseEvent.preventDefault();
            mouseEvent.stopPropagation();
            mouseSelectingRef.current = false;
            mouseGestureStartRef.current = null;
            editor.setPosition({
              lineNumber: marker.line + 1,
              column: marker.utf16Column + 1,
            });
            syncCursorAndSelection();
            void keymapRegistry.executeCommand(
              marker.direction === "down"
                ? "editor.goToImplementation"
                : "editor.goToSuperMethod",
              { marker },
            );
            return;
          }
        }
        if (
          isEditorGoToDefinitionModifierClick(mouseEvent) &&
          event.target.type === monacoEditor.MouseTargetType.CONTENT_TEXT &&
          event.target.position
        ) {
          mouseEvent.preventDefault();
          mouseEvent.stopPropagation();
          mouseSelectingRef.current = false;
          mouseGestureStartRef.current = null;
          editor.setPosition(event.target.position);
          syncCursorAndSelection();
          const clickedPosition = event.target.position;
          const clickIntent = ++definitionClickIntent;
          if (!definitionLinkGesture.enabled) {
            void keymapRegistry.executeCommand("editor.goToDefinition");
            return;
          }
          void definitionLinkGesture.resolveForClick(clickedPosition).then((definitionHint) => {
            if (
              clickIntent !== definitionClickIntent ||
              !definitionHint ||
              model.isDisposed() ||
              !isActiveSurfaceRef.current
            ) {
              return;
            }
            const currentPosition = editor.getPosition();
            if (
              !currentPosition ||
              currentPosition.lineNumber !== clickedPosition.lineNumber ||
              currentPosition.column !== clickedPosition.column
            ) {
              return;
            }
            void keymapRegistry.executeCommand("editor.goToDefinition", { definitionHint });
          });
          return;
        }
        if (mouseEvent.leftButton) {
          mouseSelectingRef.current = true;
          if (!mouseGestureStartRef.current) {
            mouseGestureStartRef.current = cursorEntryFromEditor();
          }
        }
      }),
      editor.onMouseUp(() => {
        if (!mouseSelectingRef.current) return;
        mouseSelectingRef.current = false;
        if (!isCurrentEditorSurface()) {
          mouseGestureStartRef.current = null;
          return;
        }
        const entry = cursorEntryToRecordAfterMouseGesture(
          mouseGestureStartRef.current,
          cursorEntryFromEditor(),
        );
        if (entry) useJumpListStore.getState().actions.recordCursorEntry(entry);
        mouseGestureStartRef.current = null;
        scheduleInlineGitBlameRender();
      }),
      editor.onDidChangeCursorSelection(() => {
        if (!isCurrentEditorSurface()) return;
        if (suppressNextCursorSelectionSyncRef.current) {
          suppressNextCursorSelectionSyncRef.current = false;
          scheduleInlineGitBlameRender();
          return;
        }
        syncCursorAndSelection();
        scheduleInlineGitBlameRender();
      }),
      definitionLinkGesture,
      editor.onDidScrollChange((event) => {
        if (!isCurrentEditorSurface()) return;
        if (restoringViewStateRef.current) return;
        const viewKey = viewStateKey ?? activeBufferId ?? null;
        setScrollForBuffer(viewKey, event.scrollTop, event.scrollLeft);
        onScrollOffsetChange?.(event.scrollTop, event.scrollLeft);
        onScrollMetricsChangeRef.current?.({
          scrollTop: event.scrollTop,
          scrollHeight: event.scrollHeight,
          clientHeight: editor.getLayoutInfo().height,
        });
      }),
      editor.onDidLayoutChange((info) => {
        setViewportHeight(info.height);
        syncBottomScrollPadding(info.height);
        scheduleMonacoHoverClamp();
        if (!restoringViewStateRef.current) return;
        applyMonacoSurfaceViewState(editor, viewStateKey ?? activeBufferId ?? "");
      }),
    ];

    const handleWindowMouseUp = () => {
      if (!mouseSelectingRef.current) return;
      mouseSelectingRef.current = false;
      if (!isCurrentEditorSurface()) {
        mouseGestureStartRef.current = null;
        return;
      }
      const entry = cursorEntryToRecordAfterMouseGesture(
        mouseGestureStartRef.current,
        cursorEntryFromEditor(),
      );
      if (entry) useJumpListStore.getState().actions.recordCursorEntry(entry);
      mouseGestureStartRef.current = null;
      scheduleInlineGitBlameRender();
    };
    window.addEventListener("mouseup", handleWindowMouseUp);

    const unsubscribeCursor = editorAPI.on("cursorChange", (position) => {
      if (!modelRef.current || editorRef.current !== editor) return;
      if (!isCurrentEditorSurface() || mouseSelectingRef.current) return;
      const monacoPosition = toClampedMonacoPosition(model, position);
      const currentPosition = editor.getPosition();
      if (
        currentPosition &&
        currentPosition.lineNumber === monacoPosition.lineNumber &&
        currentPosition.column === monacoPosition.column
      ) {
        editor.focus();
        return;
      }
      const currentSelection = editor.getSelection();
      if (currentSelection && !currentSelection.isEmpty()) {
        editor.revealPositionInCenterIfOutsideViewport(monacoPosition);
        editor.focus();
        return;
      }
      editor.setPosition(monacoPosition);
      editor.revealPositionInCenterIfOutsideViewport(monacoPosition);
      editor.focus();
    });
    const unsubscribeSelection = editorAPI.on("selectionChange", (selection) => {
      if (!modelRef.current || editorRef.current !== editor) return;
      if (!isCurrentEditorSurface() || mouseSelectingRef.current) return;
      if (selection) {
        editor.setSelection(toMonacoRange(model, selection));
      } else {
        const position = editor.getPosition();
        if (position) {
          editor.setSelection(
            new MonacoRange(
              position.lineNumber,
              position.column,
              position.lineNumber,
              position.column,
            ),
          );
        }
      }
    });
    scheduleInlineGitBlameRender();

    const createdViewKey = viewStateKey ?? activeBufferId ?? "";
    applyMonacoSurfaceViewState(editor, createdViewKey);
    const cancelCreatedViewStateRestore = scheduleCachedViewStateRestore({
      editor,
      restoreEditor: () => applyMonacoSurfaceViewState(editor, createdViewKey),
      isEditorCurrent: () => editorRef.current === editor,
      isNavigationRevisionCurrent: () => true,
      focus: () => {
        if (isActiveSurfaceRef.current) editor.focus();
      },
      onRestoreComplete: () => {
        restoringViewStateRef.current = false;
      },
    });

    return () => {
      cancelCreatedViewStateRestore();
      if (benchmarkRafId !== null) cancelAnimationFrame(benchmarkRafId);
      if (benchmarkTimeoutId !== null) window.clearTimeout(benchmarkTimeoutId);
      if (filePath && fileOpenBenchmark.has(filePath)) {
        fileOpenBenchmark.cancel(filePath, "editor-unmounted-before-ready");
      }
      onModelPositionResolverChange?.(null);
      unsubscribeCursor();
      unsubscribeSelection();
      container.removeEventListener("mousedown", handleNativeMouseDownCapture, true);
      window.removeEventListener("keydown", handleWindowSelectAllShortcut, true);
      window.removeEventListener("mouseup", handleWindowMouseUp);
      for (const disposable of disposables) {
        disposable.dispose();
      }
      hoverMutationObserver.disconnect();
      hoverResizeObserver.disconnect();
      if (hoverClampRaf !== null) {
        cancelAnimationFrame(hoverClampRaf);
      }
      if (gitBlameRenderFrameRef.current !== null) {
        cancelAnimationFrame(gitBlameRenderFrameRef.current);
        gitBlameRenderFrameRef.current = null;
      }
      try {
        gitBlameWidgetRef.current?.dispose();
      } catch (error) {
        console.error("Failed to dispose inline Git blame widget:", error);
      }
      gitBlameWidgetRef.current = null;
      renderedGitBlameKeyRef.current = null;
      mouseSelectingRef.current = false;
      mouseGestureStartRef.current = null;
      createdEditorDisposable.dispose();
      onEditorScrollApiReadyRef.current?.(null);
      try {
        vimAdapterRef.current?.dispose();
      } catch (error) {
        console.error("Failed to dispose Monaco Vim adapter:", error);
      }
      vimAdapterRef.current = null;
      vimStatusRef.current?.remove();
      vimStatusRef.current = null;
      implementationDecorations.clear();
      if (implementationDecorationsRef.current === implementationDecorations) {
        implementationDecorationsRef.current = null;
      }
      implementationMarkerOwnerRef.current = null;
      implementationMarkersRef.current = [];
      persistMonacoSurfaceViewState(editor, viewStateKey ?? activeBufferId ?? "");
      if (editorRef.current === editor) editorRef.current = null;
      if (modelRef.current === model) modelRef.current = null;
      try {
        editor.dispose();
      } catch (error) {
        console.error("Failed to dispose Monaco editor:", error);
      }
      try {
        acquiredModel.release();
      } catch (error) {
        console.error("Failed to release Monaco model:", error);
      }
    };
  }, [
    activeBufferId,
    autoCompletion,
    editorBracketPairColorization,
    editorCursorBlinking,
    editorCursorStyle,
    editorFontLigatures,
    editorItalicComments,
    editorScrollBeyondLastLine,
    editorSmoothScrolling,
    editorStickyScroll,
    documentTarget,
    inlayHints,
    setContextMenuPosition,
    filePath,
    paneId,
    fontFamily,
    fontSize,
    highlightOccurrences,
    isPreviewMode,
    lineHeight,
    lineNumbers,
    lineNumberFormatter,
    minimapEnabled,
    modelUri,
    monacoLanguageId,
    onScrollOffsetChange,
    parameterHints,
    readOnly,
    renderIndentGuides,
    renderWhitespace,
    rootFolderPath,
    workspaceId,
    scrollable,
    alwaysConsumeMouseWheel,
    scheduleInlineGitBlameRender,
    selectEntireModel,
    semanticTokens,
    setScrollForBuffer,
    setViewportHeight,
    syncCursorAndSelection,
    tabSize,
    themeId,
    viewStateKey,
    wordWrap,
    editorBufferId,
    isCurrentEditorSurface,
  ]);

  useLayoutEffect(() => {
    if (!isActiveSurface) return;

    const adapterOwnerId = viewStateKey ?? activeBufferId ?? modelUri.toString();
    const canEdit = !readOnly && !isPreviewMode;
    const container = containerRef.current;
    editorAPI.setTextareaRef(null);
    if (container) editorAPI.setViewportRef(container);
    editorAPI.setActiveFindAdapter({
      ownerId: adapterOwnerId,
      openFind: (replace) => {
        editorRef.current?.trigger(
          "lithe-keybinding",
          replace ? "editor.action.startFindReplaceAction" : "actions.find",
          null,
        );
      },
    });

    editorAPI.setActiveEditorAdapter({
      ownerId: adapterOwnerId,
      insertText: (text, position) => {
        if (!canEdit) return;
        const editor = editorRef.current;
        const model = modelRef.current;
        if (!editor || !model) return;

        if (position) {
          const monacoPosition = toClampedMonacoPosition(model, position);
          executeMonacoTextEdit(
            new MonacoRange(
              monacoPosition.lineNumber,
              monacoPosition.column,
              monacoPosition.lineNumber,
              monacoPosition.column,
            ),
            text,
          );
          return;
        }

        const selection = editor.getSelection();
        if (selection && !selection.isEmpty()) {
          executeMonacoTextEdit(selection, text);
          return;
        }

        const currentPosition = editor.getPosition() ?? {
          lineNumber: 1,
          column: 1,
        };
        executeMonacoTextEdit(
          new MonacoRange(
            currentPosition.lineNumber,
            currentPosition.column,
            currentPosition.lineNumber,
            currentPosition.column,
          ),
          text,
        );
      },
      deleteRange: (range) => {
        if (!canEdit) return;
        const model = modelRef.current;
        if (model) executeMonacoTextEdit(toMonacoRange(model, range), "");
      },
      replaceRange: (range, text) => {
        if (!canEdit) return;
        const model = modelRef.current;
        if (model) executeMonacoTextEdit(toMonacoRange(model, range), text);
      },
      selectAll: selectEntireModel,
      clearSelection: () => {
        const editor = editorRef.current;
        const position = editor?.getPosition();
        const currentSelection = editor?.getSelection();
        if (!editor || !position || !currentSelection || currentSelection.isEmpty()) return;

        suppressNextCursorSelectionSyncRef.current = true;
        editor.setSelection(
          new MonacoRange(
            position.lineNumber,
            position.column,
            position.lineNumber,
            position.column,
          ),
        );
      },
      setCursorPosition: (position) => {
        const editor = editorRef.current;
        const model = modelRef.current;
        if (!editor || !model || model.isDisposed()) return;

        const monacoPosition = toClampedMonacoPosition(model, position);
        editor.setPosition(monacoPosition);
        editor.revealPositionInCenterIfOutsideViewport(monacoPosition);
      },
      setScroll: (scrollTop, scrollLeft) => {
        editorRef.current?.setScrollPosition({ scrollTop, scrollLeft });
      },
      focus: () => editorRef.current?.focus(),
      addSelectionToNextFindMatch: () =>
        runMonacoSelectionAction("editor.action.addSelectionToNextFindMatch"),
      addSelectionToPreviousFindMatch: () =>
        runMonacoSelectionAction("editor.action.addSelectionToPreviousFindMatch"),
      selectAllFindMatches: () => runMonacoSelectionAction("editor.action.selectHighlights"),
      insertCursorAbove: () => runMonacoSelectionAction("editor.action.insertCursorAbove"),
      insertCursorBelow: () => runMonacoSelectionAction("editor.action.insertCursorBelow"),
      insertCursorsAtLineEnds: () =>
        runMonacoSelectionAction("editor.action.insertCursorAtEndOfEachLineSelected"),
      removeSecondaryCursors: () => runMonacoSelectionAction("removeSecondaryCursors"),
      undo: () => {
        if (!canEdit) return;
        editorRef.current?.trigger("lithe-api", "undo", null);
        syncCursorAndSelection();
      },
      redo: () => {
        if (!canEdit) return;
        editorRef.current?.trigger("lithe-api", "redo", null);
        syncCursorAndSelection();
      },
    });

    const editor = editorRef.current;
    const model = modelRef.current;
    const isCachedActivation =
      !!filePath &&
      !!editor &&
      !!model &&
      fileOpenBenchmark.hasMark(filePath, "existing-buffer-activated") &&
      !fileOpenBenchmark.hasMark(filePath, "monaco-create-start");
    let benchmarkRafId: number | null = null;
    let benchmarkTimeoutId: number | null = null;

    if (isCachedActivation && editor && model) {
      fileOpenBenchmark.mark(filePath, "cached-editor-activated");
      let benchmarkFinished = false;
      const finishCachedActivation = () => {
        if (benchmarkFinished || model.isDisposed()) return;
        benchmarkFinished = true;
        if (benchmarkRafId !== null) cancelAnimationFrame(benchmarkRafId);
        if (benchmarkTimeoutId !== null) window.clearTimeout(benchmarkTimeoutId);
        const tokenTypes = Array.from(
          new Set(
            monacoEditor
              .tokenize(model.getValue().slice(0, 4_096), model.getLanguageId())
              .flatMap((line) => line.map((token) => token.type))
              .filter(Boolean),
          ),
        ).slice(0, 12);
        fileOpenBenchmark.finish(filePath, "editor-ready", `${model.getValueLength()} chars`, {
          contentLength: model.getValueLength(),
          lineCount: model.getLineCount(),
          largeContentMode: false,
          languageId: model.getLanguageId(),
          themeId,
          tokenTypes,
        });
        recordStartupMilestone("editor:first-ready");
      };

      if (document.visibilityState === "visible") {
        benchmarkRafId = requestAnimationFrame(finishCachedActivation);
        benchmarkTimeoutId = window.setTimeout(finishCachedActivation, 100);
      } else {
        benchmarkTimeoutId = window.setTimeout(finishCachedActivation, 0);
      }
    }

    const focusTimerId = canEdit ? window.setTimeout(() => editorRef.current?.focus(), 0) : null;

    return () => {
      if (focusTimerId !== null) window.clearTimeout(focusTimerId);
      if (benchmarkRafId !== null) cancelAnimationFrame(benchmarkRafId);
      if (benchmarkTimeoutId !== null) window.clearTimeout(benchmarkTimeoutId);
      editorAPI.clearActiveFindAdapter(adapterOwnerId);
      editorAPI.clearActiveEditorAdapter(adapterOwnerId);
      if (container && editorAPI.getViewportRef() === container) {
        editorAPI.setViewportRef(null);
      }
    };
  }, [
    activeBufferId,
    executeMonacoTextEdit,
    filePath,
    isActiveSurface,
    isPreviewMode,
    modelUri,
    readOnly,
    runMonacoSelectionAction,
    selectEntireModel,
    syncCursorAndSelection,
    themeId,
    viewStateKey,
  ]);

  useEffect(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model) return;

    monacoEditor.setModelLanguage(model, monacoLanguageId);
  }, [monacoLanguageId]);

  // Rust Core combines JDT LS CodeLens and semantic navigation results into
  // the four relationship/direction variants rendered by this UI layer.
  //
  // The request is issued directly rather than through Monaco's codeLens
  // provider: Monaco only invokes a provider when it intends to render inline
  // lens text, so hooking the gutter into that lifecycle leaves the icons
  // dependent on a callback that may never fire. The React store revision is
  // read during render so startup transitions cannot be missed between mount
  // and effect subscription.
  useEffect(() => {
    implementationMarkerOwnerRef.current = null;
    implementationMarkersRef.current = [];
    implementationDecorationsRef.current?.clear();
    frontendTrace("debug", "java.gutter.effect", filePath, {
      enableExpensiveServices,
      monacoLanguageId,
      hasBufferId: Boolean(editorBufferId),
      hasFilePath: Boolean(filePath),
      hasWorkspaceRoot: Boolean(rootFolderPath),
    });
    if (
      !enableExpensiveServices ||
      monacoLanguageId !== "java" ||
      !editorBufferId ||
      !filePath ||
      !rootFolderPath
    ) {
      setImplementationMarkers([]);
      return;
    }

    type MarkerRefreshState =
      | { phase: "idle" }
      | { phase: "scheduled"; timerId: number }
      | { phase: "running"; operation: LspOperationLog }
      | { phase: "disposed" };
    const owner: { state: MarkerRefreshState; retryAttempt: number } = {
      state: { phase: "idle" },
      retryAttempt: 0,
    };
    const isDisposed = () => owner.state.phase === "disposed";
    const lspClient = LspClient.getInstance();

    const refreshMarkers = async () => {
      if (isDisposed()) return;
      const model = modelRef.current;
      if (!model || model.isDisposed()) return;
      const operation = new LspOperationLog("javaNavigationMarkers", crypto.randomUUID(), {
        bufferId: editorBufferId,
        filePath,
        hasDocumentUri: Boolean(documentTarget.documentUri),
        retryAttempt: owner.retryAttempt,
      });
      owner.state = { phase: "running", operation };
      try {
        const markers = await loadJavaNavigationMarkers({
          client: lspClient,
          target: documentTarget,
          workspaceScope: { workspaceId, root: rootFolderPath },
          content: model.getValue(),
        });
        if (isDisposed()) {
          operation.cancelled("editor-owner-disposed");
          return;
        }
        if (model.isDisposed() || modelRef.current !== model) {
          operation.cancelled("editor-model-replaced");
          return;
        }

        implementationMarkerOwnerRef.current = editorBufferId;
        implementationMarkersRef.current = markers;
        setImplementationMarkers(markers);
        operation.succeeded({ markerCount: markers.length });
      } catch (error) {
        if (isDisposed()) operation.cancelled("editor-owner-disposed");
        else if (normalizeLspError(error).code === "timed_out") operation.timedOut();
        else if (isTransientJavaMarkerError(error)) operation.cancelled("transient-jdtls-state");
        else operation.failed(error);
        throw error;
      } finally {
        if (owner.state.phase === "running" && owner.state.operation === operation) {
          owner.state = { phase: "idle" };
        }
      }
    };

    const scheduleRefresh = (delayMilliseconds = 180) => {
      if (isDisposed()) return;
      if (owner.state.phase === "scheduled") window.clearTimeout(owner.state.timerId);
      // Match the macOS editor delay: a typing burst should produce one marker
      // batch for the settled document version, not one batch per keystroke.
      const timerId = window.setTimeout(() => {
        if (owner.state.phase !== "scheduled" || owner.state.timerId !== timerId) return;
        owner.state = { phase: "idle" };
        void refreshMarkers().catch((error) => {
          if (isDisposed()) return;
          if (isTransientJavaMarkerError(error)) {
            const retryDelay = javaMarkerRetryDelay(owner.retryAttempt);
            if (retryDelay !== null) {
              owner.retryAttempt += 1;
              frontendTrace("info", "java.gutter.retry", filePath, {
                attempt: owner.retryAttempt,
                delayMilliseconds: retryDelay,
                reason: error instanceof Error ? error.message : String(error),
              });
              scheduleRefresh(retryDelay);
              return;
            }
          }
          frontendTrace("warn", "java.gutter.resolve", filePath, {
            error: error instanceof Error ? error.message : String(error),
            retriesExhausted: isTransientJavaMarkerError(error),
          });
        });
      }, delayMilliseconds);
      owner.state = { phase: "scheduled", timerId };
    };

    // JDTLS answers codeLens only once its index is ready, so the render-level
    // revision re-runs this owner when the session or document lifecycle moves.
    scheduleRefresh();

    return () => {
      const state = owner.state;
      owner.state = { phase: "disposed" };
      if (state.phase === "scheduled") window.clearTimeout(state.timerId);
      if (state.phase === "running") state.operation.cancelled("editor-owner-disposed");
    };
  }, [
    documentTarget,
    editorBufferId,
    enableExpensiveServices,
    filePath,
    javaMarkerRevision,
    monacoLanguageId,
    rootFolderPath,
    workspaceId,
  ]);

  useEffect(() => {
    const visibleMarkers = implementationMarkersForBuffer(
      implementationMarkers,
      implementationMarkerOwnerRef.current,
      editorBufferId,
    );
    implementationMarkersRef.current = visibleMarkers;
    implementationDecorationsRef.current?.set(
      implementationMarkerDecorations(visibleMarkers),
    );
  }, [editorBufferId, implementationMarkers]);

  useEffect(() => {
    const model = modelRef.current;
    if (!model) return;

    monacoEditor.setModelMarkers(
      model,
      "lithe",
      diagnosticsForFile.map((diagnostic) => ({
        severity:
          diagnostic.severity === "error"
            ? MarkerSeverity.Error
            : diagnostic.severity === "warning"
              ? MarkerSeverity.Warning
              : MarkerSeverity.Info,
        message: diagnostic.message,
        source: diagnostic.source,
        code: diagnostic.code,
        startLineNumber: diagnostic.line + 1,
        startColumn: diagnostic.column + 1,
        endLineNumber: diagnostic.endLine + 1,
        endColumn: Math.max(diagnostic.endColumn + 1, diagnostic.column + 2),
      })),
    );

    return () => {
      if (!model.isDisposed()) {
        monacoEditor.setModelMarkers(model, "lithe", []);
      }
    };
  }, [diagnosticsForFile]);

  useEffect(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editorBufferId || !editor || !model) return;

    const previousContent = previousContentRef.current;
    if (previousContent === content || monacoModelMatchesContent(previousContent, content)) {
      consumeLocalContentSnapshot(pendingLocalContentSnapshotsRef.current, content);
      return;
    }

    // React can deliver older store echoes after Monaco has already accepted more typing.
    if (consumeLocalContentSnapshot(pendingLocalContentSnapshotsRef.current, content)) {
      return;
    }

    applyingExternalChangeRef.current = true;
    const selection = editor.getSelection();
    applyMonacoModelContent(model, content);
    if (selection) editor.setSelection(selection);
    previousContentRef.current = content;
    applyingExternalChangeRef.current = false;
  }, [content, editorBufferId]);

  useEffect(() => {
    if (!isActiveSurface || readOnly || isPreviewMode) return;

    const handleTriggerSuggest = () => {
      const editor = editorRef.current;
      if (!editor) return;

      editor.focus();
      editor.trigger("lithe", "editor.action.triggerSuggest", {});
    };

    window.addEventListener("editor-trigger-suggest", handleTriggerSuggest);
    return () => window.removeEventListener("editor-trigger-suggest", handleTriggerSuggest);
  }, [isActiveSurface, isPreviewMode, readOnly]);

  useEffect(() => {
    if (!isActiveSurface) return;

    const handleShowHover = () => {
      const editor = editorRef.current;
      if (!editor) return;

      editor.focus();
      editor.trigger("lithe", "editor.action.showHover", {});
    };

    window.addEventListener("editor-show-hover", handleShowHover);
    return () => window.removeEventListener("editor-show-hover", handleShowHover);
  }, [isActiveSurface]);

  useEffect(() => {
    const editor = editorRef.current;
    if (!editor) return;

    if (!vimModeEnabled || !vimRelativeLineNumbers || lineNumberMap) return;

    editor.updateOptions({
      lineNumbers: lineNumbers ? lineNumberFormatter : "off",
    });
  }, [
    cursorPosition.line,
    lineNumberFormatter,
    lineNumberMap,
    lineNumbers,
    vimModeEnabled,
    vimRelativeLineNumbers,
  ]);

  // Theme application is isolated from option updates so that tab switches
  // (which flip `enableExpensiveServices`) do not redefine the theme and
  // invalidate every model's tokenization cache via `TokenizationRegistry`.
  useEffect(() => {
    const editor = editorRef.current;
    if (!editor) return;

    const applyTheme = (nextThemeId?: string) => {
      monacoEditor.setTheme(
        nextThemeId
          ? defineMonacoTheme(nextThemeId, editorItalicComments)
          : defineActiveMonacoTheme(themeId, editorItalicComments),
      );
    };

    applyTheme();

    const unsubscribeRegistry = themeRegistry.onRegistryChange(applyTheme);
    const unsubscribeTheme = themeRegistry.onThemeChange(applyTheme);
    const unsubscribeReady = themeRegistry.onReady(applyTheme);

    return () => {
      unsubscribeRegistry();
      unsubscribeTheme();
      unsubscribeReady();
    };
  }, [editorItalicComments, themeId]);

  useEffect(() => {
    const editor = editorRef.current;
    const container = containerRef.current;
    if (!editor) return;
    const fontOptions = { fontFamily, fontSize, lineHeight };

    editor.updateOptions({
      ...fontOptions,
      tabSize,
      readOnly: readOnly || isPreviewMode,
      domReadOnly: readOnly || isPreviewMode,
      lineNumbers: lineNumbers ? lineNumberFormatter : "off",
      minimap: { enabled: minimapEnabled },
      fontLigatures: editorFontLigatures,
      disableMonospaceOptimizations: true,
      selectOnLineNumbers: true,
      stickyScroll: { enabled: editorStickyScroll },
      bracketPairColorization: { enabled: editorBracketPairColorization },
      smoothScrolling: editorSmoothScrolling,
      scrollBeyondLastLine: editorScrollBeyondLastLine,
      renderWhitespace: renderWhitespace === "none" ? "none" : renderWhitespace,
      wordWrap: wordWrap ? "on" : "off",
      guides: {
        indentation: renderIndentGuides,
        highlightActiveIndentation: renderIndentGuides,
      },
      occurrencesHighlight: highlightOccurrences ? "singleFile" : "off",
      selectionHighlight: highlightOccurrences,
      glyphMargin: enableExpensiveServices && monacoLanguageId === "java",
      quickSuggestions: autoCompletion,
      suggestOnTriggerCharacters: autoCompletion,
      parameterHints: { enabled: enableExpensiveServices && parameterHints },
      codeLens: enableExpensiveServices && codeLens,
      inlayHints: { enabled: enableExpensiveServices && inlayHints ? "on" : "off" },
      cursorStyle: vimModeEnabled && vimCurrentMode === "normal" ? "block" : editorCursorStyle,
      cursorBlinking:
        vimModeEnabled && vimCurrentMode === "normal" ? "solid" : editorCursorBlinking,
      "semanticHighlighting.enabled": enableExpensiveServices && semanticTokens,
      scrollbar: {
        vertical: scrollable ? "auto" : "hidden",
        horizontal: scrollable ? "auto" : "hidden",
        handleMouseWheel: scrollable,
        alwaysConsumeMouseWheel: scrollable && alwaysConsumeMouseWheel,
      },
    });
    if (container) syncContainedEditorFontOptions(container, fontOptions);

    const viewKey = viewStateKey ?? activeBufferId ?? "";
    if (
      viewKey &&
      (restoringViewStateRef.current || !isActiveSurfaceRef.current) &&
      useEditorStateStore.getState().actions.getCachedViewState(viewKey)
    ) {
      applyMonacoSurfaceViewState(editor, viewKey);
    }

    return undefined;
  }, [
    activeBufferId,
    autoCompletion,
    codeLens,
    editorBracketPairColorization,
    editorCursorBlinking,
    editorCursorStyle,
    editorFontLigatures,
    editorScrollBeyondLastLine,
    editorSmoothScrolling,
    editorStickyScroll,
    enableExpensiveServices,
    fontFamily,
    fontSize,
    highlightOccurrences,
    inlayHints,
    isPreviewMode,
    lineHeight,
    lineNumbers,
    lineNumberFormatter,
    minimapEnabled,
    monacoLanguageId,
    parameterHints,
    readOnly,
    renderIndentGuides,
    renderWhitespace,
    scrollable,
    alwaysConsumeMouseWheel,
    semanticTokens,
    tabSize,
    viewStateKey,
    vimCurrentMode,
    vimModeEnabled,
    wordWrap,
  ]);

  useEffect(() => {
    const editor = editorRef.current;
    const container = containerRef.current;
    const { setMode } = useVimStore.getState().actions;

    vimAdapterRef.current?.dispose();
    vimAdapterRef.current = null;
    vimStatusRef.current?.remove();
    vimStatusRef.current = null;

    if (!editor || !container || !vimModeEnabled || readOnly || isPreviewMode) {
      return;
    }

    registerMonacoVimCommands();

    const statusNode = document.createElement("div");
    statusNode.className = "monaco-vim-statusbar";
    statusNode.setAttribute("aria-live", "polite");
    container.appendChild(statusNode);

    const adapter = initVimMode(editor, statusNode);
    adapter.on("vim-mode-change", (event: { mode: string }) => {
      setMode(toEditorVimMode(event.mode));
    });
    adapter.on("dispose", () => {
      useVimStore.getState().actions.setMode("normal");
    });

    vimAdapterRef.current = adapter;
    vimStatusRef.current = statusNode;
    setMode("normal");

    return () => {
      try {
        adapter.dispose();
      } catch (error) {
        console.error("Failed to dispose Monaco Vim adapter:", error);
      }
      if (vimAdapterRef.current === adapter) vimAdapterRef.current = null;
      statusNode.remove();
      if (vimStatusRef.current === statusNode) vimStatusRef.current = null;
    };
  }, [isPreviewMode, readOnly, vimModeEnabled]);

  useEffect(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model) return;

    const decorations = (highlightMatches ?? []).map((match, index) => {
      const start = model.getPositionAt(match.start);
      const end = model.getPositionAt(match.end);
      return {
        range: new MonacoRange(start.lineNumber, start.column, end.lineNumber, end.column),
        options: {
          className:
            index === currentHighlightIndex
              ? "monaco-search-match monaco-search-match-current"
              : "monaco-search-match",
          overviewRuler: undefined,
        },
      };
    });

    decorationsRef.current = editor.deltaDecorations(decorationsRef.current, decorations);
  }, [currentHighlightIndex, highlightMatches]);

  useEffect(() => {
    scheduleInlineGitBlameRender();
  }, [renderInlineGitBlame, scheduleInlineGitBlameRender]);

  useEffect(() => {
    const editor = editorRef.current;
    const model = modelRef.current;
    if (!editor || !model) {
      onModelPositionResolverChange?.(null);
      return;
    }

    onModelPositionResolverChange?.((line, column) => {
      if (model.isDisposed()) return null;
      const position = clampMonacoPosition(model, {
        lineNumber: line + 1,
        column: column + 1,
      });
      let editorPosition: Position;
      let top: number;
      let left: number;
      let lineLength: number;

      try {
        editorPosition = toEditorPosition(model, position);
        top = editor.getTopForLineNumber(position.lineNumber);
        left = editor.getOffsetForColumn(position.lineNumber, position.column);
        lineLength = model.getLineLength(position.lineNumber);
      } catch (error) {
        if (model.isDisposed()) return null;
        throw error;
      }
      const modelLine = position.lineNumber - 1;

      return {
        ...editorPosition,
        viewLine: modelLine,
        modelLine,
        top,
        left,
        height: lineHeight,
        segment: {
          viewLine: modelLine,
          modelLine,
          startColumn: 0,
          endColumn: lineLength,
          top,
          height: lineHeight,
        },
      };
    });

    return () => {
      onModelPositionResolverChange?.(null);
    };
  }, [lineHeight, onModelPositionResolverChange]);

  useLayoutEffect(() => {
    const editor = editorRef.current;
    if (!editor) return;

    const viewStateKeyForRestore = viewStateKey ?? activeBufferId ?? "";
    if (!isActiveSurface) {
      // Snapshot the live viewport before hidden layout and option updates can
      // reset Monaco to the first line. Do not call layout() here.
      persistMonacoSurfaceViewState(editor, viewStateKeyForRestore);
      return;
    }

    const cached = useEditorStateStore
      .getState()
      .actions.getCachedViewState(viewStateKeyForRestore);
    const navigationRevision = editorAPI.getOwnerNavigationRevision(viewStateKeyForRestore);

    restoringViewStateRef.current = true;
    editor.layout();
    applyMonacoSurfaceViewState(editor, viewStateKeyForRestore);

    const cancelCachedViewStateRestore = scheduleCachedViewStateRestore({
      editor,
      cachedScroll: cached
        ? { scrollTop: cached.scrollTop, scrollLeft: cached.scrollLeft }
        : undefined,
      restoreEditor: () => applyMonacoSurfaceViewState(editor, viewStateKeyForRestore),
      isEditorCurrent: () => editorRef.current === editor,
      isNavigationRevisionCurrent: () =>
        editorAPI.getOwnerNavigationRevision(viewStateKeyForRestore) === navigationRevision,
      focus: () => {
        if (isActiveSurfaceRef.current) editor.focus();
      },
      onRestoreComplete: () => {
        restoringViewStateRef.current = false;
      },
    });

    return () => {
      cancelCachedViewStateRestore();
      restoringViewStateRef.current = false;
    };
  }, [activeBufferId, isActiveSurface, viewStateKey]);

  const shellStyle = {
    "--lithe-monaco-font-family": fontFamily,
    "--lithe-monaco-font-size": `${fontSize}px`,
    "--lithe-monaco-line-height": `${lineHeight}px`,
  } as CSSProperties;
  const canEdit = !readOnly && !isPreviewMode;

  return (
    <>
      <div
        className={`monaco-editor-shell absolute inset-0 min-h-0 bg-background ${className ?? ""}`}
        style={shellStyle}
        onMouseMove={onMouseMove}
        onMouseLeave={onMouseLeave}
        onMouseEnter={onMouseEnter}
        onClick={(event) => {
          if (readOnly && onReadonlySurfaceClick) {
            const editor = editorRef.current;
            const model = modelRef.current;
            const target = editor?.getTargetAtClientPoint(event.clientX, event.clientY);
            if (target?.position && model) {
              onReadonlySurfaceClick({
                line: target.position.lineNumber - 1,
                column: target.position.column - 1,
              });
            }
          }
          onClick?.(event);
        }}
      >
        {backgroundLayer}
        <div
          ref={containerRef}
          className="absolute inset-0"
          data-monaco-editor-scroll
          data-line-number-start={lineNumberStart}
          data-line-number-map={lineNumberMap?.length ?? undefined}
        />
        <InlineEditPopover state={inlineEditState} selection={selection} />
      </div>
      {contextMenuPosition &&
        createPortal(
          <EditorContextMenu
            isOpen
            position={contextMenuPosition}
            onClose={() => {
              setContextMenuPosition(null);
              setContextMenuTestMethod(null);
            }}
            onCopy={() => executeEditorCommand("editor.copy")}
            onCut={canEdit ? () => executeEditorCommand("editor.cut") : undefined}
            onPaste={canEdit ? () => executeEditorCommand("editor.paste") : undefined}
            onSelectAll={() => executeEditorCommand("editor.selectAll")}
            onDelete={
              canEdit
                ? () => {
                    const currentSelection = editorAPI.getSelection();
                    if (currentSelection) editorAPI.deleteRange(currentSelection);
                  }
                : undefined
            }
            onFind={() => executeEditorCommand("workbench.showFind")}
            onGoToLine={() => executeEditorCommand("editor.goToLine")}
            onDuplicate={canEdit ? () => executeEditorCommand("editor.duplicateLine") : undefined}
            onSelectNextOccurrence={() => executeEditorCommand("editor.selectNextOccurrence")}
            onSelectAllOccurrences={() => executeEditorCommand("editor.selectAllOccurrences")}
            onIndent={canEdit ? () => triggerMonacoAction("editor.action.indentLines") : undefined}
            onOutdent={
              canEdit ? () => triggerMonacoAction("editor.action.outdentLines") : undefined
            }
            onToggleComment={
              canEdit ? () => executeEditorCommand("editor.toggleComment") : undefined
            }
            onFormat={canEdit ? () => executeEditorCommand("editor.formatDocument") : undefined}
            onFormatSelection={
              canEdit ? () => executeEditorCommand("editor.formatSelection") : undefined
            }
            onToggleCase={canEdit ? toggleMonacoSelectionCase : undefined}
            onMoveLineUp={canEdit ? () => executeEditorCommand("editor.moveLineUp") : undefined}
            onMoveLineDown={canEdit ? () => executeEditorCommand("editor.moveLineDown") : undefined}
            onGoToDefinition={() => executeEditorCommand("editor.goToDefinition")}
            onGoToTypeDefinition={() => executeEditorCommand("editor.goToTypeDefinition")}
            onFindReferences={() => executeEditorCommand("editor.goToReferences")}
            onRenameSymbol={canEdit ? () => executeEditorCommand("editor.renameSymbol") : undefined}
            onQuickFix={canEdit ? () => executeEditorCommand("editor.quickFix") : undefined}
            onShowHover={() => executeEditorCommand("editor.showHover")}
            onTriggerSuggest={
              canEdit ? () => executeEditorCommand("editor.triggerSuggest") : undefined
            }
            onRunTestClass={
              mavenTestsAvailable ? runTestClassFromEditor : undefined
            }
            onRunTestMethod={
              mavenTestsAvailable && contextMenuTestMethod ? runTestMethodFromEditor : undefined
            }
          />,
          document.body,
        )}
    </>
  );
}
