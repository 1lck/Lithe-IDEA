import type { editor } from "monaco-editor";

type CursorUndoEditor = Pick<
  editor.IStandaloneCodeEditor,
  "onDidChangeCursorSelection" | "onDidChangeModelContent" | "onDidChangeModel" | "trigger"
>;

// Monaco owns positions, selections and scroll history. This view-local policy
// consumes only the latest keyboard move before returning to text undo.
export function createCursorAwareUndo(view: CursorUndoEditor, writable: boolean) {
  let pending: "undo" | "redo" | undefined;
  let selectionRevision = 0;
  const clear = () => {
    pending = undefined;
  };
  const listeners = [
    view.onDidChangeModel(clear),
    view.onDidChangeModelContent(clear),
    view.onDidChangeCursorSelection((event) => {
      const selections = [event.selection, ...event.secondarySelections];
      const changed =
        event.oldSelections &&
        (event.oldSelections.length !== selections.length ||
          event.oldSelections.some((old, index) => !old.equalsSelection(selections[index])));
      if (changed) selectionRevision++;
      pending =
        event.source === "keyboard" &&
        event.oldModelVersionId === event.modelVersionId &&
        changed
          ? "undo"
          : undefined;
    }),
  ];

  const cursorUndo = () => {
    clear();
    const before = selectionRevision;
    view.trigger("lithe-api", "cursorUndo", null);
    // An empty native stack emits no changed selection and must not consume redo.
    if (selectionRevision !== before) pending = "redo";
  };
  const cursorRedo = () => {
    clear();
    view.trigger("lithe-api", "cursorRedo", null);
  };

  return {
    cursorUndo,
    cursorRedo,
    undo() {
      if (pending === "undo") {
        cursorUndo();
      } else {
        clear();
        if (writable) view.trigger("lithe-api", "undo", null);
      }
    },
    redo() {
      const cursorRedo = pending === "redo";
      clear();
      if (cursorRedo) view.trigger("lithe-api", "cursorRedo", null);
      else if (writable) view.trigger("lithe-api", "redo", null);
    },
    dispose() {
      clear();
      for (const listener of listeners) listener.dispose();
    },
  };
}
