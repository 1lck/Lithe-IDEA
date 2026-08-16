import { editor as monacoEditor } from "monaco-editor";
import type * as Monaco from "monaco-editor";

const WIDGET_ID = "lithe.inlineGitBlame";

export interface InlineGitBlameWidget {
  show(lineNumber: number, column: number, content: string): void;
  hide(): void;
  dispose(): void;
}

/**
 * Render git blame after the line as a content widget so it does not join
 * Monaco's text hit-testing. Injected `after` text steals clicks at EOL and
 * can collapse a drag-select when decorations are replaced.
 */
export function createInlineGitBlameWidget(
  editor: Monaco.editor.IStandaloneCodeEditor,
): InlineGitBlameWidget {
  const node = document.createElement("div");
  node.className = "monaco-inline-git-blame";
  node.setAttribute("aria-hidden", "true");
  let position: Monaco.IPosition | null = null;

  const widget: Monaco.editor.IContentWidget = {
    getId: () => WIDGET_ID,
    getDomNode: () => node,
    suppressMouseDown: true,
    allowEditorOverflow: true,
    getPosition: () =>
      position
        ? {
            position,
            preference: [monacoEditor.ContentWidgetPositionPreference.EXACT],
          }
        : null,
  };

  editor.addContentWidget(widget);

  return {
    show(lineNumber, column, content) {
      node.textContent = content;
      position = { lineNumber, column };
      editor.layoutContentWidget(widget);
    },
    hide() {
      if (!position && node.textContent === "") return;
      node.textContent = "";
      position = null;
      editor.layoutContentWidget(widget);
    },
    dispose() {
      editor.removeContentWidget(widget);
    },
  };
}
