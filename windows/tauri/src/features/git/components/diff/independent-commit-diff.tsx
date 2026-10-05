import { useEffect, useImperativeHandle, useMemo, useRef, useState, type Ref } from "react";
import "@/features/editor/engines/monaco/monaco-environment";
import "monaco-editor/min/vs/editor/editor.main.css";
import { toMonacoLanguageId } from "@lithe/editor/language";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { defineActiveMonacoTheme, defineMonacoTheme } from "@/features/editor/engines/monaco/theme";
import { useMonacoEditorSettings } from "@/features/editor/engines/monaco/use-monaco-editor-settings";
import { detectLanguageFromPath } from "@/features/editor/utils/language-detection";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { joinPath } from "@/utils/path-helpers";
import { monacoDiffRows } from "../../utils/monaco-diff-rows";
import { commitDiffEditorAppearance } from "../../utils/commit-file-diff-appearance";
import {
  emptyDiffNavigation,
  reviewSourceLine,
  type DiffNavigationState,
} from "../../utils/commit-file-diff-navigation";
import type { GitDiff } from "../../types/git.types";
import type { MonacoGitDiffHandle } from "./monaco-git-diff";
import { mountIndependentCommitDiff } from "./independent-commit-diff-surface";
import * as monaco from "monaco-editor";
import { ensureMonacoLanguageTokenizer } from "@lithe/editor/language-contributions";
import type { CommitDiffBlockControls } from "./commit-diff-block-controls";

interface Props {
  diff: GitDiff;
  sourceRepoPath?: string;
  showWhitespace: boolean;
  highlightWords: boolean;
  startAtFirstDifference: boolean;
  blockControls?: CommitDiffBlockControls;
  onNavigationChange: (state: DiffNavigationState) => void;
  onSplitLayout: (width: number) => void;
  ref?: Ref<MonacoGitDiffHandle>;
}

export default function IndependentCommitDiff(props: Props) {
  const host = useRef<HTMLDivElement>(null);
  const surface = useRef<ReturnType<typeof mountIndependentCommitDiff> | null>(null);
  const latest = useRef(props);
  latest.current = props;
  const pendingFirst = useRef(props.startAtFirstDifference);
  const landingDiff = useRef(props.diff);
  const [error, setError] = useState<string>();
  const rows = useMemo(() => monacoDiffRows(props.diff, { hideHunkHeaders: true }), [props.diff]);
  const settings = useMonacoEditorSettings();
  const source = (side: 0 | 1, line: number, column: number) => {
    const instance = surface.current,
      { diff, sourceRepoPath } = latest.current;
    if (!instance?.ready || diff.is_deleted) return;
    const sourceLine = reviewSourceLine(instance.plan.rows, side === 0 ? "left" : "right", line);
    if (!sourceLine) return;
    const path = diff.new_path || diff.file_path || diff.old_path || "";
    const state = useFileSystemStore.getState(),
      root = sourceRepoPath ?? state.rootFolderPath;
    const target =
      /^(?:[A-Za-z]:[\\/]|\/|[a-z]+:\/\/)/i.test(path) || !root ? path : joinPath(root, path);
    void state
      .handleFileSelect(target, false, sourceLine, column, undefined, false)
      .catch((reason) => {
        if (surface.current === instance) setError(String(reason));
      });
  };
  const publish = () => {
    const instance = surface.current;
    if (!instance?.ready) {
      latest.current.onNavigationChange(emptyDiffNavigation);
      return;
    }
    if (pendingFirst.current) {
      pendingFirst.current = false;
      if (instance.plan.changes.length) instance.reveal(instance.plan.changes[0]);
    }
    const side = instance.focused,
      view = instance.views[side],
      caret = view.getPosition()?.lineNumber ?? 1;
    const starts = instance.plan.changes.map(
      (change) => (side ? change.rightStart : change.leftStart) + 1,
    );
    latest.current.onNavigationChange({
      ready: true,
      count: starts.length,
      canPrevious: starts.some((line) => line < caret),
      canNext: starts.some((line) => line > caret),
      canJumpToSource:
        !latest.current.diff.is_deleted &&
        reviewSourceLine(instance.plan.rows, side === 0 ? "left" : "right", caret) !== null,
    });
  };
  useImperativeHandle(
    props.ref,
    () => ({
      jumpToSource: () => surface.current?.jump(),
      navigateDifference: (direction) => {
        const instance = surface.current;
        if (!instance?.ready) return;
        const side = instance.focused,
          view = instance.views[side],
          caret = view.getPosition()?.lineNumber ?? 1;
        const changes =
          direction === "next" ? instance.plan.changes : [...instance.plan.changes].reverse();
        const change = changes.find((change) =>
          direction === "next"
            ? (side ? change.rightStart : change.leftStart) + 1 > caret
            : (side ? change.rightStart : change.leftStart) + 1 < caret,
        );
        if (change) instance.reveal(change);
      },
    }),
    [],
  );
  useEffect(() => {
    const instance = mountIndependentCommitDiff(host.current!, {
      runtime: monaco,
      wholeFileAdded: props.diff.is_new === true,
      prepareLanguage: ensureMonacoLanguageTokenizer,
      source,
      changed: publish,
      failed: (reason) => setError(String(reason)),
      splitLayout: (width) => latest.current.onSplitLayout(width),
    });
    surface.current = instance;
    instance.setBlockControls(latest.current.blockControls);
    return () => {
      surface.current = null;
      instance.dispose();
    };
  }, [props.diff.is_new]);
  useEffect(() => {
    surface.current?.setBlockControls(props.blockControls);
  }, [props.blockControls]);
  useEffect(() => {
    let cancelled = false;
    setError(undefined);
    const instance = surface.current!;
    // Reopening the same file can replace its snapshot without remounting this
    // component. Preference updates keep the existing cursor and scroll position.
    if (landingDiff.current !== props.diff) {
      landingDiff.current = props.diff;
      pendingFirst.current = props.startAtFirstDifference;
    }
    void instance
      .update(
        rows,
        toMonacoLanguageId(detectLanguageFromPath(props.diff.new_path || props.diff.file_path)),
        false,
        props.highlightWords,
      )
      .then(() => {
        if (!cancelled) publish();
      })
      .catch((reason) => {
        if (!cancelled) setError(String(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [rows, props.diff, props.highlightWords]);
  useEffect(() => {
    const { fontSize, fontFamily, lineHeight, tabSize, editorFontLigatures } = settings;
    surface.current?.configure(
      {
        ...commitDiffEditorAppearance(fontSize, lineHeight),
        fontSize,
        fontFamily,
        fontLigatures: editorFontLigatures,
        scrollBeyondLastColumn: 0,
        renderWhitespace: props.showWhitespace ? "all" : "none",
      },
      tabSize,
    );
  }, [
    settings.fontSize,
    settings.fontFamily,
    settings.lineHeight,
    settings.tabSize,
    settings.editorFontLigatures,
    props.showWhitespace,
    props.diff.is_new,
  ]);
  useEffect(() => {
    const apply = (next?: string) => {
      monaco.editor.setTheme(
        next
          ? defineMonacoTheme(next, settings.editorItalicComments)
          : defineActiveMonacoTheme(settings.themeId, settings.editorItalicComments),
      );
      surface.current?.refresh();
    };
    apply();
    const stop = [
      themeRegistry.onRegistryChange(apply),
      themeRegistry.onThemeChange(apply),
      themeRegistry.onReady(apply),
    ];
    return () => stop.forEach((fn) => fn());
  }, [settings.themeId, settings.editorItalicComments]);
  return (
    <div className="relative h-full min-h-0 overflow-hidden">
      <div ref={host} className="absolute inset-0" />
      {error && (
        <div role="alert" className="absolute inset-0 bg-background p-4 text-destructive">
          {error}
        </div>
      )}
    </div>
  );
}
