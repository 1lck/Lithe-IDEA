import { editor as monacoEditor, KeyCode } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import {
  computeGitGutterChanges,
  gitGutterChangeIndexAtLine,
  gitGutterMarkerLines,
  gitGutterPeekAnchorLine,
  gitGutterPeekRows,
  trimFinalEmptyLine,
  type GitGutterChange,
} from "@/features/git/utils/git-gutter-changes";
import { GitGutterPeekSession, type GitGutterPeek } from "./git-gutter-peek-session";
import {
  createGitGutterPeekWidget,
  type GitGutterPeekLabels,
  type GitGutterPeekWidget,
} from "./git-gutter-peek-widget";
import { monacoLineDiff } from "./monaco-line-diff";

export const GIT_GUTTER_MARKER_CLASS = "lithe-git-gutter";

/** Pause after typing before the gutter is recomputed against the Git base. */
const GIT_GUTTER_RECOMPUTE_DELAY_MS = 250;

export interface GitGutterControllerOptions {
  language(): string;
  labels(peek: GitGutterPeek): GitGutterPeekLabels;
  markerTooltip(kind: GitGutterChange["kind"]): string;
  /** Staging writes the change into the index, so it needs saved, writable text. */
  canStage(): boolean;
  stage(change: GitGutterChange, base: readonly string[]): Promise<boolean>;
  openDiff(): void;
}

export interface GitGutterController {
  /** The index text to compare against, or null when the file has no Git base. */
  setBase(base: readonly string[] | null): void;
  /** Re-evaluates button state, for example after the document was saved. */
  refreshPeek(): void;
  dispose(): void;
}

/**
 * Git change markers in the line-decoration gutter and their inline review.
 * Markers compare the live editor text with the Git index, so unsaved edits
 * show up as changes. Any edit closes an open review; a review only acts on
 * the change list computed for the current model version.
 */
export function createGitGutterController(
  editor: Monaco.editor.IStandaloneCodeEditor,
  model: Monaco.editor.ITextModel,
  options: GitGutterControllerOptions,
): GitGutterController {
  const decorations = editor.createDecorationsCollection();
  const session = new GitGutterPeekSession();
  let base: readonly string[] | null = null;
  let widget: GitGutterPeekWidget | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let staging = false;
  let disposed = false;

  const closePeek = () => {
    session.close();
    widget?.dispose();
    widget = null;
  };

  const editorLines = () => trimFinalEmptyLine(model.getLinesContent());

  const render = (peek: GitGutterPeek | null) => {
    if (!peek) {
      closePeek();
      return;
    }
    widget ??= createGitGutterPeekWidget(editor, {
      previous: () => navigate("previous"),
      next: () => navigate("next"),
      stage: () => void stage(),
      openDiff: () => options.openDiff(),
      close: () => {
        closePeek();
        editor.focus();
      },
    });
    widget.show({
      rows: gitGutterPeekRows(session.changeList, peek.index, editorLines()),
      anchorLine: gitGutterPeekAnchorLine(peek.change),
      language: options.language(),
      labels: options.labels(peek),
      canNavigate: peek.total > 1,
      canStage: base !== null && options.canStage(),
      staging,
    });
  };

  const navigate = (direction: "previous" | "next") => {
    if (disposed) return;
    render(session.navigate(direction, model.getVersionId()));
  };

  const stage = async () => {
    const peek = session.peek;
    const snapshot = base;
    const version = model.getVersionId();
    if (disposed || staging || !peek || !snapshot || !options.canStage()) return;
    if (!session.isCurrent(peek, version)) return;
    staging = true;
    render(peek);
    try {
      // A successful write emits a Git change event; the refreshed base then
      // drops this change from the list and closes the review.
      await options.stage(peek.change, snapshot);
    } finally {
      staging = false;
      if (!disposed && session.peek) render(session.peek);
    }
  };

  const recompute = () => {
    timer = null;
    if (disposed || model.isDisposed()) return;
    const changes = base ? computeGitGutterChanges(base, editorLines(), monacoLineDiff) : null;
    const lineCount = model.getLineCount();
    decorations.set(
      (changes ?? []).map((change) => {
        const { start, end } = gitGutterMarkerLines(change, lineCount);
        return {
          range: { startLineNumber: start, startColumn: 1, endLineNumber: end, endColumn: 1 },
          options: {
            isWholeLine: true,
            linesDecorationsClassName: `${GIT_GUTTER_MARKER_CLASS} ${GIT_GUTTER_MARKER_CLASS}-${change.kind}`,
            linesDecorationsTooltip: options.markerTooltip(change.kind),
            stickiness: monacoEditor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
          },
        };
      }),
    );
    render(session.setChanges(changes ?? [], model.getVersionId()));
  };

  const schedule = (delay: number) => {
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(recompute, delay);
  };

  const disposables = [
    model.onDidChangeContent(() => {
      // The review describes text that no longer exists; markers keep
      // following Monaco's tracked ranges until the recompute lands.
      closePeek();
      session.invalidate();
      schedule(GIT_GUTTER_RECOMPUTE_DELAY_MS);
    }),
    editor.onDidChangeModel(() => {
      closePeek();
      session.invalidate();
      decorations.clear();
    }),
    editor.onMouseDown((event) => {
      if (
        event.target.type !== monacoEditor.MouseTargetType.GUTTER_LINE_DECORATIONS ||
        !event.target.position ||
        !event.event.leftButton ||
        !event.target.element?.classList.contains(GIT_GUTTER_MARKER_CLASS)
      ) {
        return;
      }
      event.event.preventDefault();
      event.event.stopPropagation();
      const version = model.getVersionId();
      const index = gitGutterChangeIndexAtLine(
        session.changeList,
        event.target.position.lineNumber,
        model.getLineCount(),
      );
      if (index < 0) return;
      if (session.peek?.index === index) {
        closePeek();
        return;
      }
      render(session.open(index, version));
      // Monaco keeps focus where it was on gutter clicks; take it so Escape
      // closes the review, as in VS Code.
      editor.focus();
    }),
    editor.onKeyDown((event) => {
      if (event.keyCode !== KeyCode.Escape || !session.peek) return;
      event.preventDefault();
      event.stopPropagation();
      closePeek();
    }),
  ];

  return {
    setBase(next) {
      if (disposed) return;
      base = next;
      schedule(0);
    },
    refreshPeek() {
      if (!disposed && session.peek) render(session.peek);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      if (timer !== null) clearTimeout(timer);
      disposables.forEach((disposable) => disposable.dispose());
      closePeek();
      decorations.clear();
    },
  };
}
