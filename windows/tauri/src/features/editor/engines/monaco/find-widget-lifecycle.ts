import type * as Monaco from "monaco-editor";

export interface FindWidgetState {
  readonly isRevealed: boolean;
  change(next: { isRevealed: boolean }, moveCursor: boolean): void;
}

interface FindController {
  getState(): FindWidgetState;
}

/**
 * Closes Monaco's find widget without clearing its query. Inactive editor
 * surfaces stay mounted, so each instance can otherwise keep a revealed find
 * widget when the user switches files or panes.
 */
export function closeFindWidget(
  editor: Pick<Monaco.editor.ICodeEditor, "getContribution">,
): boolean {
  const controller = editor.getContribution<Monaco.editor.IEditorContribution & FindController>(
    "editor.contrib.findController",
  );
  const state = controller?.getState();
  if (!state?.isRevealed) return false;
  state.change({ isRevealed: false }, false);
  return true;
}
