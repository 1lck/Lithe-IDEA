// Host-internal plugin document edits (plugin API plan API-09/API-10).
//
// Positions are Monaco's one-based line/column in UTF-16 code units, the same
// numbers the native service uses, so no coordinate conversion happens here.
// The helpers take structural model/view types so they stay testable without
// the browser-only Monaco bundle.

export type PluginRange = { startLineNumber: number; startColumn: number; endLineNumber: number; endColumn: number };
export type PluginEdit = PluginRange & { text: string };
export type PluginSelection = { anchorLine: number; anchorColumn: number; activeLine: number; activeColumn: number };
type MonacoSelection = { selectionStartLineNumber: number; selectionStartColumn: number; positionLineNumber: number; positionColumn: number };

export type PluginEditModel = {
  validateRange(range: PluginRange): PluginRange;
  pushStackElement(): void;
  pushEditOperations(before: MonacoSelection[] | null, operations: { range: PluginRange; text: string; forceMoveMarkers?: boolean }[],
    cursor: () => null): unknown;
};
type Disposable = { dispose(): void };
export type PluginEditView = {
  getModel(): unknown;
  getSelections(): MonacoSelection[] | null;
  hasTextFocus(): boolean;
  onDidCompositionStart(listener: () => void): Disposable;
  onDidCompositionEnd(listener: () => void): Disposable;
};

export type PluginEditStatus = "applied" | "versionConflict" | "composition" | "readOnly" | "outOfRange" | "busy";

/** Tracks IME composition per view; a composing view owns uncommitted user input. */
export class CompositionTracker {
  private readonly composing = new Set<PluginEditView>();

  track(view: PluginEditView): Disposable[] {
    return [
      view.onDidCompositionStart(() => { this.composing.add(view); }),
      view.onDidCompositionEnd(() => { this.composing.delete(view); }),
    ];
  }

  forget(view: PluginEditView) { this.composing.delete(view); }

  /** True when any view showing `model` has an active composition. */
  isComposing(model: unknown, views: readonly PluginEditView[]): boolean {
    return views.some(view => this.composing.has(view) && view.getModel() === model);
  }
}

/** Gate checked before anything is applied. Order: busy, readonly, version, composition, range. */
export function checkPluginEdits(input: {
  model: PluginEditModel; edits: readonly PluginEdit[]; readonly: boolean; busy: boolean;
  revision: number; expectedRevision: number; pendingEdits: number; composing: boolean;
}): Exclude<PluginEditStatus, "applied"> | undefined {
  if (input.busy) return "busy";
  if (input.readonly) return "readOnly";
  // Local input increments the revision before it is acknowledged, so typing
  // that Swift has not seen yet rejects the batch instead of being overwritten.
  if (input.revision !== input.expectedRevision || input.pendingEdits > 0) return "versionConflict";
  if (input.composing) return "composition";
  for (const edit of input.edits) {
    const valid = input.model.validateRange(edit);
    if (valid.startLineNumber !== edit.startLineNumber || valid.startColumn !== edit.startColumn ||
        valid.endLineNumber !== edit.endLineNumber || valid.endColumn !== edit.endColumn) return "outOfRange";
  }
  return undefined;
}

/** Applies a checked batch as exactly one undo element. `text` must use LF. */
export function applyPluginEdits(model: PluginEditModel, edits: readonly PluginEdit[], before: MonacoSelection[] | null) {
  // Closing stack elements on both sides keeps neighbouring typing out of the
  // batch's undo element, so one Undo restores the text from before the batch.
  model.pushStackElement();
  model.pushEditOperations(before, edits.map(edit => ({
    range: { startLineNumber: edit.startLineNumber, startColumn: edit.startColumn,
      endLineNumber: edit.endLineNumber, endColumn: edit.endColumn },
    text: edit.text,
  })), () => null);
  model.pushStackElement();
}

/** The view whose selections represent the document: focused, last focused, then any. */
export function selectionView<View extends PluginEditView>(model: unknown, views: readonly View[], lastFocused?: View): View | undefined {
  const showing = views.filter(view => view.getModel() === model);
  return showing.find(view => view.hasTextFocus()) ?? showing.find(view => view === lastFocused) ?? showing[0];
}

/** Monaco selections as anchor/active pairs, primary first as Monaco reports them. */
export function toPluginSelections(selections: readonly MonacoSelection[] | null | undefined): PluginSelection[] {
  return (selections ?? []).map(selection => ({
    anchorLine: selection.selectionStartLineNumber, anchorColumn: selection.selectionStartColumn,
    activeLine: selection.positionLineNumber, activeColumn: selection.positionColumn,
  }));
}

type SavedCursor = { selectionStart: { lineNumber: number; column: number }; position: { lineNumber: number; column: number } };

/** Selections from a saved view state, used when no view currently shows the document. */
export function savedPluginSelections(state: { cursorState: readonly SavedCursor[] } | null | undefined): PluginSelection[] {
  return (state?.cursorState ?? []).map(cursor => ({
    anchorLine: cursor.selectionStart.lineNumber, anchorColumn: cursor.selectionStart.column,
    activeLine: cursor.position.lineNumber, activeColumn: cursor.position.column,
  }));
}
