import type * as monaco from "monaco-editor";
import { FindModelBoundToEditorModel } from "monaco-editor/esm/vs/editor/contrib/find/browser/findModel.js";
import { FindReplaceState } from "monaco-editor/esm/vs/editor/contrib/find/browser/findState.js";

export interface NativeFindInput {
  id: string; token: string; visible: boolean; query: string;
  matchCase: boolean; wholeWord: boolean; regex: boolean;
  command?: "next" | "previous" | "replace" | "replaceAll";
  replacement?: string;
}

// Use the pinned Monaco search/replace engine without its widget. The host owns
// the find bar; Monaco still owns regex semantics, decorations and undo groups.
export function mountNativeFind(view: monaco.editor.IStandaloneCodeEditor, report: (index: number, count: number) => void) {
  const state = new FindReplaceState();
  const search = new FindModelBoundToEditorModel(view, state);
  const changed = state.onFindReplaceStateChange(() => report(state.matchesPosition, state.matchesCount));
  return {
    update(input: NativeFindInput, writable: boolean) {
      state.change({ searchString: input.query, matchCase: input.matchCase, wholeWord: input.wholeWord,
        isRegex: input.regex, replaceString: input.replacement ?? "" }, !input.command);
      if (input.command === "next") search.moveToNextMatch();
      if (input.command === "previous") search.moveToPrevMatch();
      if (writable && input.command === "replace") search.replace();
      if (writable && input.command === "replaceAll") search.replaceAll();
      report(state.matchesPosition, state.matchesCount);
      return { index: state.matchesPosition, count: state.matchesCount };
    },
    dispose() { changed.dispose(); search.dispose(); state.dispose(); },
  };
}
