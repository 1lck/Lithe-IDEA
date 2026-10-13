import { useEffect, useImperativeHandle, useMemo, useRef, useState, type Ref } from "react";
import * as monaco from "monaco-editor";
import { editor as monacoEditor } from "monaco-editor";
import type { CommitDiffBlockControls } from "./commit-diff-block-controls";
import { mountMonacoCommitBlockControls } from "./monaco-commit-block-controls";
import "@/features/editor/engines/monaco/monaco-environment";
import "monaco-editor/min/vs/editor/editor.main.css";
import "@/features/editor/styles/monaco-editor.css";
import { mountDiffReview } from "@lithe/editor/diff-review";
import { toMonacoLanguageId } from "@lithe/editor/language";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { defineActiveMonacoTheme, defineMonacoTheme } from "@/features/editor/engines/monaco/theme";
import { useMonacoEditorSettings } from "@/features/editor/engines/monaco/use-monaco-editor-settings";
import { detectLanguageFromPath } from "@/features/editor/utils/language-detection";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { joinPath } from "@/utils/path-helpers";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { discardHunk, stageHunk, unstageHunk } from "../../api/git-status-api";
import {
  createMonacoDiffHunkActions,
  type DiffStagingContext,
} from "../../utils/monaco-diff-hunk-actions";
import { monacoDiffRows } from "../../utils/monaco-diff-rows";
import { commitDiffEditorAppearance } from "../../utils/commit-file-diff-appearance";
import type { GitDiff } from "../../types/git.types";
import type { MultiDiffSearchMatch } from "../../utils/multi-diff-search";
import {
  differenceNavigationState,
  differenceStartLine,
  emptyDiffNavigation,
  reviewSourceLine,
  type DiffNavigationState,
} from "../../utils/commit-file-diff-navigation";

export interface MonacoGitDiffHandle {
  navigateDifference: (direction: "previous" | "next") => void;
  jumpToSource: () => void;
}

interface Props {
  diff: GitDiff;
  viewMode?: "unified" | "split";
  showWhitespace?: boolean;
  embedded?: boolean;
  staging?: DiffStagingContext;
  searchMatches?: MultiDiffSearchMatch[];
  currentSearchMatch?: MultiDiffSearchMatch | null;
  ref?: Ref<MonacoGitDiffHandle>;
  sourceRepoPath?: string;
  onNavigationChange?: (state: DiffNavigationState) => void;
  startAtFirstDifference?: boolean;
  startAtLastDifference?: boolean;
  focusOnInitialDifference?: boolean;
  highlightWords?: boolean;
  repositoryPreview?: boolean;
  onSplitLayout?: (originalWidth: number) => void;
  blockControls?: CommitDiffBlockControls;
}

const MIN_REVIEW_HEIGHT = 160;
const MAX_EMBEDDED_REVIEW_HEIGHT = 760;
const noMatches: MultiDiffSearchMatch[] = [];
export default function MonacoGitDiff({
  diff,
  viewMode = "split",
  showWhitespace = false,
  embedded = false,
  staging,
  searchMatches = noMatches,
  currentSearchMatch = null,
  ref,
  sourceRepoPath,
  onNavigationChange,
  startAtFirstDifference = false,
  startAtLastDifference = false,
  focusOnInitialDifference = true,
  highlightWords = true,
  repositoryPreview = false,
  onSplitLayout,
  blockControls,
}: Props) {
  const { t } = useTranslation();
  const container = useRef<HTMLDivElement>(null);
  const review = useRef<ReturnType<typeof mountDiffReview> | null>(null);
  const hunkActions = useRef<ReturnType<typeof createMonacoDiffHunkActions> | null>(null);
  const [error, setError] = useState<string>();
  const [actionFailed, setActionFailed] = useState(false);
  const [height, setHeight] = useState(MIN_REVIEW_HEIGHT);
  const blockWidgets = useRef<ReturnType<typeof mountMonacoCommitBlockControls> | null>(null);
  const latestBlockControls = useRef(blockControls);
  latestBlockControls.current = blockControls;
  const installBlockWidgets = () => {
    blockWidgets.current?.dispose();
    blockWidgets.current = null;
    const view = review.current?.editor.getModifiedEditor();
    if (!view) return;
    view.updateOptions({ glyphMargin: Boolean(latestBlockControls.current) });
    if (!updating.current && latestBlockControls.current) {
      blockWidgets.current = mountMonacoCommitBlockControls(view, monaco, latestBlockControls.current);
    }
  };
  useEffect(() => {
    installBlockWidgets();
  }, [blockControls]);
  const rows = useMemo(() => monacoDiffRows(diff, { hideHunkHeaders: repositoryPreview }), [diff, repositoryPreview]);
  const sourcePath = diff.new_path || diff.file_path || diff.old_path || "";
  const latest = useRef({ rows, sourcePath, sourceRepoPath, isDeleted: diff.is_deleted });
  const updating = useRef(false);
  const firstDifferencePending = useRef(startAtFirstDifference);
  const initialDifferenceFocusRef = useRef(focusOnInitialDifference);
  initialDifferenceFocusRef.current = focusOnInitialDifference;
  const lastDifferenceLanding = useRef(startAtLastDifference);
  lastDifferenceLanding.current = startAtLastDifference;
  const landingDiff = useRef(diff);
  const navigationListener = useRef(onNavigationChange);
  navigationListener.current = onNavigationChange;
  const splitLayoutListener = useRef(onSplitLayout);
  splitLayoutListener.current = onSplitLayout;
  const controls = useRef<(MonacoGitDiffHandle & { publish: () => void }) | null>(null);
  useImperativeHandle(
    ref,
    () => ({
      navigateDifference: (direction) => controls.current?.navigateDifference(direction),
      jumpToSource: () => controls.current?.jumpToSource(),
    }),
    [],
  );
  const repoPath = staging?.repoPath;
  const isStaged = staging?.isStaged ?? false;
  const canDiscard = staging?.canDiscard === true;
  const actionTitle = isStaged ? t("git.diff.unstage") : t("git.diff.stage");
  const discardTitle = t("git.rollback");
  // The confirmation runs from an owner created per patch; read the current
  // translator instead of rebuilding the owner when the language changes.
  const { fontSize, fontFamily, lineHeight, tabSize, themeId, editorItalicComments, editorFontLigatures } = useMonacoEditorSettings();

  useEffect(() => {
    let closed = false;
    const instance = mountDiffReview(container.current!, (hunkID, action) => {
      const owner = hunkActions.current;
      if (closed || updating.current || !owner) return;
      setActionFailed(false);
      void owner.apply(hunkID, action).then((result) => {
        if (!closed && hunkActions.current === owner && result === "failed") setActionFailed(true);
      });
    });
    review.current = instance;
    const editors = [
      instance.editor.getOriginalEditor(),
      instance.editor.getModifiedEditor(),
    ] as const;
    const publishLayout = () => splitLayoutListener.current?.(editors[0].getLayoutInfo().width);
    publishLayout();
    let focusedSide: "left" | "right" = "right";
    let computedVersions: readonly number[] | null = null;
    const sourcePosition = (
      side: "left" | "right",
      position: { lineNumber: number; column: number } | null,
    ) => {
      if (closed || updating.current || latest.current.isDeleted || !position) return null;
      const line = reviewSourceLine(latest.current.rows, side, position.lineNumber);
      return line ? { line, column: position.column } : null;
    };
    const openSource = (
      side: "left" | "right",
      position: { lineNumber: number; column: number } | null,
    ) => {
      const location = sourcePosition(side, position);
      if (!location) return;
      const state = useFileSystemStore.getState();
      const path = latest.current.sourcePath;
      const root = latest.current.sourceRepoPath ?? state.rootFolderPath;
      const absolute = /^(?:[A-Za-z]:[\\/]|\/|[a-z]+:\/\/)/i.test(path);
      const target = absolute || !root ? path : joinPath(root, path);
      void state
        .handleFileSelect(target, false, location.line, location.column, undefined, false)
        .catch((error) => {
          if (!closed) setError(String(error));
        });
    };
    const navigationState = (): DiffNavigationState => {
      if (closed || updating.current) return emptyDiffNavigation;
      // getLineChanges may retain the previous computation while content changes.
      if (!computedVersions || editors.some((view, index) =>
        view.getModel()?.getVersionId() !== computedVersions![index])) return emptyDiffNavigation;
      const modified = editors[1];
      const sideEditor = focusedSide === "left" ? editors[0] : modified;
      const changes = instance.editor.getLineChanges();
      if (changes === null) return emptyDiffNavigation;
      return {
        ready: true,
        ...differenceNavigationState(
          changes,
          modified.getPosition()?.lineNumber ?? 1,
          modified.getModel()?.getLineCount() ?? 1,
        ),
        canJumpToSource: sourcePosition(focusedSide, sideEditor.getPosition()) !== null,
      };
    };
    const publish = () => {
      if (firstDifferencePending.current && navigationState().ready) {
        const changes = instance.editor.getLineChanges();
        if (changes !== null) {
          // Consume once after Monaco finishes; later cursor/model updates keep their position.
          firstDifferencePending.current = false;
          if (changes.length) {
            const change = changes[lastDifferenceLanding.current ? changes.length - 1 : 0];
            const lineNumber = differenceStartLine(change, editors[1].getModel()?.getLineCount() ?? 1);
            editors[1].setPosition({ lineNumber, column: 1 });
            editors[1].revealPositionInCenter({ lineNumber, column: 1 });
            if (initialDifferenceFocusRef.current) editors[1].focus();
            focusedSide = "right";
          }
        }
      }
      navigationListener.current?.(navigationState());
    };
    controls.current = {
      publish,
      navigateDifference: (direction) => {
        const state = navigationState();
        if (!(direction === "next" ? state.canNext : state.canPrevious)) return;
        instance.editor.goToDiff(direction);
        editors[1].focus();
        focusedSide = "right";
        publish();
      },
      jumpToSource: () =>
        openSource(focusedSide, (focusedSide === "left" ? editors[0] : editors[1]).getPosition()),
    };
    const resize = () => {
      if (!closed)
        setHeight(
          Math.max(
            MIN_REVIEW_HEIGHT,
            Math.min(
              MAX_EMBEDDED_REVIEW_HEIGHT,
              Math.max(...editors.map((view) => view.getContentHeight())),
            ),
          ),
        );
    };
    const listeners = editors.flatMap((view, index) => {
      let pressed: { lineNumber: number; column: number } | null = null;
      return [
        view.onDidContentSizeChange(resize),
        view.onDidChangeCursorPosition(publish),
        view.onDidFocusEditorText(() => {
          focusedSide = index === 0 ? "left" : "right";
          publish();
        }),
        view.onMouseDown((event) => {
          pressed =
            !updating.current &&
            event.event.leftButton &&
            !event.event.shiftKey &&
            (event.event.ctrlKey || event.event.metaKey)
              ? event.target.position
              : null;
        }),
        view.onMouseUp((event) => {
          const start = pressed;
          pressed = null;
          const position = event.target.position;
          // Source navigation is explicit: Ctrl/Cmd-click. Ordinary selection and
          // drag-selection must remain in the review.
          if (
            updating.current ||
            !start ||
            !position ||
            !event.event.leftButton ||
            !view.getSelection()?.isEmpty() ||
            start.lineNumber !== position.lineNumber ||
            start.column !== position.column
          )
            return;
          openSource(index === 0 ? "left" : "right", position);
        }),
      ];
    });
    listeners.push(
      editors[0].onDidLayoutChange(publishLayout),
      instance.editor.onDidUpdateDiff(() => {
        computedVersions = editors.map((view) => view.getModel()?.getVersionId() ?? 0);
        resize();
        publish();
      }),
    );
    return () => {
      closed = true;
      listeners.forEach((listener) => listener.dispose());
      controls.current = null;
      blockWidgets.current?.dispose();
      blockWidgets.current = null;
      instance.dispose();
      review.current = null;
    };
  }, []);

  useEffect(() => {
    const owner = createMonacoDiffHunkActions(diff, repoPath ? { repoPath, isStaged, canDiscard } : undefined,
      { stage: stageHunk, unstage: unstageHunk, discard: discardHunk });
    hunkActions.current = owner;
    setActionFailed(false);
    return () => {
      owner.dispose();
      if (hunkActions.current === owner) hunkActions.current = null;
    };
  }, [diff, repoPath, isStaged, canDiscard]);

  useEffect(() => {
    let cancelled = false;
    setError(undefined);
    updating.current = true;
    installBlockWidgets();
    if (landingDiff.current !== diff) {
      landingDiff.current = diff;
      firstDifferencePending.current = startAtFirstDifference;
    }
    controls.current?.publish();
    const titles = { stage: actionTitle, unstage: actionTitle, discard: discardTitle };
    const actions = (hunkActions.current?.actions ?? []).map((id) => ({ id, title: titles[id] }));
    const instance = review.current!;
    void instance.update({
        rows,
        language: toMonacoLanguageId(detectLanguageFromPath(sourcePath)),
        sideBySide: viewMode === "split",
        collapse: false,
        overview: !embedded,
        highlightWords,
        actions,
      })
      .then(() => {
        if (!cancelled) {
          latest.current = { rows, sourcePath, sourceRepoPath, isDeleted: diff.is_deleted };
          updating.current = false;
          installBlockWidgets();
          controls.current?.publish();
        }
      })
      .catch((error) => {
        if (!cancelled) setError(String(error));
      });
    return () => {
      cancelled = true;
    };
  }, [
    rows,
    sourcePath,
    sourceRepoPath,
    diff.is_deleted,
    viewMode,
    embedded,
    highlightWords,
    repoPath,
    isStaged,
    canDiscard,
    actionTitle,
    discardTitle,
  ]);

  useEffect(() => {
    review.current?.select({ matches: searchMatches.map(match => ({ rowID: `line-${match.lineIndex}`,
      startColumn: match.start + 1, endColumn: match.end + 1, current: match === currentSearchMatch })), searchIDs: searchMatches.map(match => `line-${match.lineIndex}`),
      currentID: currentSearchMatch ? `line-${currentSearchMatch.lineIndex}` : null,
      revealID: currentSearchMatch ? `line-${currentSearchMatch.lineIndex}` : null });
  }, [searchMatches, currentSearchMatch]);

  useEffect(() => {
    review.current?.configure({ fontSize, fontFamily, lineHeight, fontLigatures: editorFontLigatures,
      renderWhitespace: showWhitespace ? "all" : "none", scrollbar: { alwaysConsumeMouseWheel: false },
      ...(repositoryPreview ? commitDiffEditorAppearance(fontSize, lineHeight) : {}) });
    review.current?.editor.getModel()?.original.updateOptions({ tabSize });
    review.current?.editor.getModel()?.modified.updateOptions({ tabSize });
  }, [fontSize, fontFamily, lineHeight, tabSize, showWhitespace, editorFontLigatures, repositoryPreview]);

  useEffect(() => {
    const apply = (next?: string) => monacoEditor.setTheme(next
      ? defineMonacoTheme(next, editorItalicComments) : defineActiveMonacoTheme(themeId, editorItalicComments));
    apply();
    const unsubscribe = [themeRegistry.onRegistryChange(apply), themeRegistry.onThemeChange(apply), themeRegistry.onReady(apply)];
    return () => unsubscribe.forEach(stop => stop());
  }, [themeId, editorItalicComments]);

  return <div className="relative min-h-0 w-full overflow-hidden bg-background" style={{ height: embedded ? height : "100%" }}>
    <div ref={container} className="absolute inset-0" title="Ctrl/Cmd-click to open source" />
    {actionFailed && <div role="alert" className="absolute bottom-0 inset-x-0 bg-background p-2 text-destructive">{t("git.operationFailed")}</div>}
    {error && <div role="alert" className="absolute inset-0 bg-background p-4 text-destructive">{error}</div>}
  </div>;
}
