import { useEffect, useMemo, useRef, useState } from "react";
import { editor as monacoEditor } from "monaco-editor";
import "@/features/editor/engines/monaco/monaco-environment";
import "monaco-editor/min/vs/editor/editor.main.css";
import "@/features/editor/styles/monaco-editor.css";
import { mountDiffReview, projectReviewRows } from "@lithe/editor/diff-review";
import { toMonacoLanguageId } from "@lithe/editor/language";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { defineActiveMonacoTheme, defineMonacoTheme } from "@/features/editor/engines/monaco/theme";
import { useMonacoEditorSettings } from "@/features/editor/engines/monaco/use-monaco-editor-settings";
import { detectLanguageFromPath } from "@/features/editor/utils/language-detection";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { joinPath } from "@/utils/path-helpers";
import { monacoDiffRows } from "../../utils/monaco-diff-rows";
import type { GitDiff } from "../../types/git.types";
import type { MultiDiffSearchMatch } from "../../utils/multi-diff-search";

interface Props {
  diff: GitDiff;
  viewMode?: "unified" | "split";
  showWhitespace?: boolean;
  embedded?: boolean;
  searchMatches?: MultiDiffSearchMatch[];
  currentSearchMatch?: MultiDiffSearchMatch | null;
}

const MIN_REVIEW_HEIGHT = 160;
const MAX_EMBEDDED_REVIEW_HEIGHT = 760;
const noMatches: MultiDiffSearchMatch[] = [];
export default function MonacoGitDiff({ diff, viewMode = "split", showWhitespace = false,
  embedded = false, searchMatches = noMatches, currentSearchMatch = null }: Props) {
  const container = useRef<HTMLDivElement>(null);
  const review = useRef<ReturnType<typeof mountDiffReview> | null>(null);
  const [error, setError] = useState<string>();
  const [height, setHeight] = useState(MIN_REVIEW_HEIGHT);
  const rows = useMemo(() => monacoDiffRows(diff), [diff]);
  const sourcePath = diff.new_path || diff.old_path || diff.file_path;
  const latest = useRef({ rows, sourcePath });
  const updating = useRef(false);
  const { fontSize, fontFamily, lineHeight, tabSize, themeId, editorItalicComments, editorFontLigatures } = useMonacoEditorSettings();

  useEffect(() => {
    const instance = mountDiffReview(container.current!);
    review.current = instance;
    let closed = false;
    const editors = [instance.editor.getOriginalEditor(), instance.editor.getModifiedEditor()] as const;
    const resize = () => {
      if (!closed) setHeight(Math.max(MIN_REVIEW_HEIGHT, Math.min(MAX_EMBEDDED_REVIEW_HEIGHT, Math.max(...editors.map(view => view.getContentHeight())))));
    };
    const listeners = editors.flatMap((view, index) => {
      let pressed: { lineNumber: number; column: number } | null = null;
      return [view.onDidContentSizeChange(resize), view.onMouseDown(event => {
        pressed = !updating.current && event.event.leftButton && !event.event.shiftKey
          && (event.event.ctrlKey || event.event.metaKey)
          ? event.target.position : null;
      }), view.onMouseUp(event => {
        const start = pressed;
        pressed = null;
        const position = event.target.position;
        // Source navigation is explicit: Ctrl/Cmd-click. Ordinary selection and
        // drag-selection must remain in the review.
        if (updating.current || !start || !position || !event.event.leftButton
          || !view.getSelection()?.isEmpty() || start.lineNumber !== position.lineNumber
          || start.column !== position.column) return;
        const side = index === 0 ? "left" : "right";
        const row = projectReviewRows(latest.current.rows, side).rows[position.lineNumber - 1];
        const line = row?.newLine ?? row?.oldLine;
        if (!line) return;
        const state = useFileSystemStore.getState();
        const path = latest.current.sourcePath;
        const absolute = /^(?:[A-Za-z]:[\\/]|\/|[a-z]+:\/\/)/i.test(path);
        const target = absolute || !state.rootFolderPath ? path : joinPath(state.rootFolderPath, path);
        void state.handleFileSelect(target, false, line, position.column, undefined, false)
          .catch(error => { if (!closed) setError(String(error)); });
      })];
    });
    listeners.push(instance.editor.onDidUpdateDiff(resize));
    return () => {
      closed = true; listeners.forEach(listener => listener.dispose());
      instance.dispose(); review.current = null;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setError(undefined);
    updating.current = true;
    void review.current!.update({ rows, language: toMonacoLanguageId(detectLanguageFromPath(sourcePath)),
      sideBySide: viewMode === "split", collapse: false, overview: !embedded })
      .then(() => { if (!cancelled) { latest.current = { rows, sourcePath }; updating.current = false; } })
      .catch(error => { if (!cancelled) setError(String(error)); });
    return () => { cancelled = true; };
  }, [rows, sourcePath, viewMode, embedded]);

  useEffect(() => {
    review.current?.select({ matches: searchMatches.map(match => ({ rowID: `line-${match.lineIndex}`,
      startColumn: match.start + 1, endColumn: match.end + 1, current: match === currentSearchMatch })), searchIDs: searchMatches.map(match => `line-${match.lineIndex}`),
      currentID: currentSearchMatch ? `line-${currentSearchMatch.lineIndex}` : null,
      revealID: currentSearchMatch ? `line-${currentSearchMatch.lineIndex}` : null });
  }, [searchMatches, currentSearchMatch]);

  useEffect(() => {
    review.current?.configure({ fontSize, fontFamily, lineHeight, fontLigatures: editorFontLigatures,
      renderWhitespace: showWhitespace ? "all" : "none", scrollbar: { alwaysConsumeMouseWheel: false } });
    review.current?.editor.getModel()?.original.updateOptions({ tabSize });
    review.current?.editor.getModel()?.modified.updateOptions({ tabSize });
  }, [fontSize, fontFamily, lineHeight, tabSize, showWhitespace, editorFontLigatures]);

  useEffect(() => {
    const apply = (next?: string) => monacoEditor.setTheme(next
      ? defineMonacoTheme(next, editorItalicComments) : defineActiveMonacoTheme(themeId, editorItalicComments));
    apply();
    const unsubscribe = [themeRegistry.onRegistryChange(apply), themeRegistry.onThemeChange(apply), themeRegistry.onReady(apply)];
    return () => unsubscribe.forEach(stop => stop());
  }, [themeId, editorItalicComments]);

  return <div className="relative min-h-0 w-full overflow-hidden bg-background" style={{ height: embedded ? height : "100%" }}>
    <div ref={container} className="absolute inset-0" title="Ctrl/Cmd-click to open source" />
    {error && <div role="alert" className="absolute inset-0 bg-background p-4 text-destructive">{error}</div>}
  </div>;
}
