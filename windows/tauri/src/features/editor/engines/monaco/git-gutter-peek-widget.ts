import { editor as monacoEditor } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import { mountDiffReview, type ReviewRow } from "@lithe/editor/diff-review";

const { EditorOption } = monacoEditor;

const WIDGET_ID = "lithe.gitGutterPeek";
const HEADER_HEIGHT = 28;
const MIN_BODY_LINES = 3;
const MAX_BODY_LINES = 20;
/** The review never covers more than this share of the editor viewport. */
const MAX_VIEWPORT_SHARE = 0.6;

export interface GitGutterPeekLabels {
  title: string;
  previous: string;
  next: string;
  stage: string;
  stageUnavailable: string;
  openDiff: string;
  close: string;
}

export interface GitGutterPeekView {
  rows: ReviewRow[];
  /** Editor line below which the review opens; 0 places it above line 1. */
  anchorLine: number;
  language: string;
  labels: GitGutterPeekLabels;
  canNavigate: boolean;
  canStage: boolean;
  staging: boolean;
}

export interface GitGutterPeekHandlers {
  previous(): void;
  next(): void;
  stage(): void;
  openDiff(): void;
  close(): void;
}

export interface GitGutterPeekWidget {
  show(view: GitGutterPeekView): void;
  dispose(): void;
}

function iconButton(codicon: string, onClick: () => void): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "lithe-git-peek-button";
  const icon = document.createElement("span");
  icon.className = `codicon codicon-${codicon}`;
  icon.setAttribute("aria-hidden", "true");
  button.append(icon);
  // Keep focus in the editor; the review is a transient inspection surface.
  button.addEventListener("mousedown", (event) => event.preventDefault());
  button.addEventListener("click", onClick);
  return button;
}

function labelButton(button: HTMLButtonElement, label: string) {
  button.title = label;
  button.setAttribute("aria-label", label);
}

/**
 * An inline, read-only review of one Git change, embedded between editor
 * lines like VS Code's dirty-diff peek. A view zone reserves the space and an
 * overlay widget renders into it, so Monaco moves it while scrolling without
 * React state updates. The diff uses the shared review renderer with its own
 * models, which `dispose` releases.
 */
export function createGitGutterPeekWidget(
  editor: Monaco.editor.ICodeEditor,
  handlers: GitGutterPeekHandlers,
): GitGutterPeekWidget {
  const root = document.createElement("div");
  root.className = "lithe-git-peek";
  root.setAttribute("role", "region");
  root.style.top = "-1000px";

  const header = document.createElement("div");
  header.className = "lithe-git-peek-header";
  header.style.height = `${HEADER_HEIGHT}px`;
  const title = document.createElement("span");
  title.className = "lithe-git-peek-title";
  const actions = document.createElement("div");
  actions.className = "lithe-git-peek-actions";
  const stage = iconButton("add", handlers.stage);
  const previous = iconButton("arrow-up", handlers.previous);
  const next = iconButton("arrow-down", handlers.next);
  const openDiff = iconButton("go-to-file", handlers.openDiff);
  const close = iconButton("close", handlers.close);
  actions.append(stage, next, previous, openDiff, close);
  header.append(title, actions);

  const body = document.createElement("div");
  body.className = "lithe-git-peek-body";
  root.append(header, body);
  root.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    handlers.close();
  });

  const review = mountDiffReview(body);
  const overlay: Monaco.editor.IOverlayWidget = {
    getId: () => WIDGET_ID,
    getDomNode: () => root,
    // Positioned by the view zone callbacks below, like Monaco's ZoneWidget.
    getPosition: () => null,
  };
  editor.addOverlayWidget(overlay);

  let zoneId: string | null = null;
  let height = 0;
  let anchorLine = -1;
  let disposed = false;

  const layoutWidth = () => {
    const info = editor.getLayoutInfo();
    root.style.width = `${Math.max(0, info.width - info.minimap.minimapWidth - info.verticalScrollbarWidth)}px`;
  };
  layoutWidth();
  const layoutListener = editor.onDidLayoutChange(layoutWidth);

  const removeZone = () => {
    if (zoneId === null) return;
    const id = zoneId;
    zoneId = null;
    editor.changeViewZones((accessor) => accessor.removeZone(id));
  };

  return {
    show(view) {
      if (disposed) return;
      title.textContent = view.labels.title;
      root.setAttribute("aria-label", view.labels.title);
      labelButton(previous, view.labels.previous);
      labelButton(next, view.labels.next);
      labelButton(openDiff, view.labels.openDiff);
      labelButton(close, view.labels.close);
      labelButton(stage, view.canStage ? view.labels.stage : view.labels.stageUnavailable);
      previous.disabled = !view.canNavigate;
      next.disabled = !view.canNavigate;
      stage.disabled = !view.canStage || view.staging;

      const lineHeight = editor.getOption(EditorOption.lineHeight);
      const viewportLines = Math.floor(
        (editor.getLayoutInfo().height * MAX_VIEWPORT_SHARE - HEADER_HEIGHT) / lineHeight,
      );
      const bodyLines = Math.max(
        MIN_BODY_LINES,
        Math.min(view.rows.length, MAX_BODY_LINES, Math.max(MIN_BODY_LINES, viewportLines)),
      );
      const nextHeight = HEADER_HEIGHT + bodyLines * lineHeight + 2;
      body.style.height = `${nextHeight - HEADER_HEIGHT - 2}px`;
      root.style.height = `${nextHeight}px`;

      if (zoneId === null || height !== nextHeight || view.anchorLine !== anchorLine) {
        removeZone();
        height = nextHeight;
        anchorLine = view.anchorLine;
        editor.changeViewZones((accessor) => {
          zoneId = accessor.addZone({
            afterLineNumber: view.anchorLine,
            heightInPx: nextHeight,
            domNode: document.createElement("div"),
            onDomNodeTop: (top) => {
              root.style.top = `${top}px`;
            },
          });
        });
        editor.revealLinesInCenterIfOutsideViewport(
          Math.max(1, view.anchorLine),
          Math.max(1, view.anchorLine + 1),
        );
      }

      review.configure({
        fontFamily: editor.getOption(EditorOption.fontFamily),
        fontSize: editor.getOption(EditorOption.fontSize),
        lineHeight,
        renderIndicators: true,
        scrollbar: { alwaysConsumeMouseWheel: false },
      });
      void review.update({
        rows: view.rows,
        language: view.language,
        sideBySide: false,
        collapse: false,
        overview: false,
        highlightWords: true,
      });
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      layoutListener.dispose();
      removeZone();
      editor.removeOverlayWidget(overlay);
      review.dispose();
      root.remove();
    },
  };
}
