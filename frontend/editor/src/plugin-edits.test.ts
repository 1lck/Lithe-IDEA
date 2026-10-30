import { expect, test } from "bun:test";
import { CompositionTracker, applyPluginEdits, checkPluginEdits, savedPluginSelections, selectionView, toPluginSelections,
  type PluginEdit, type PluginEditModel, type PluginEditView, type PluginRange } from "./plugin-edits";

/** Line model double with Monaco's validateRange clamping and an undo stack of
 * stack elements: every pushStackElement closes the open element. */
class FakeModel implements PluginEditModel {
  lines: string[];
  undo: string[][] = [];
  private open: string[] | undefined;
  calls: string[] = [];
  constructor(text: string) { this.lines = text.split("\n"); }
  get value() { return this.lines.join("\n"); }
  validateRange(range: PluginRange): PluginRange {
    const clamp = (line: number, column: number) => {
      const l = Math.min(Math.max(line, 1), this.lines.length);
      return [l, Math.min(Math.max(column, 1), this.lines[l - 1].length + 1)];
    };
    const [startLineNumber, startColumn] = clamp(range.startLineNumber, range.startColumn);
    const [endLineNumber, endColumn] = clamp(range.endLineNumber, range.endColumn);
    return { startLineNumber, startColumn, endLineNumber, endColumn };
  }
  pushStackElement() { this.calls.push("stop"); this.open = undefined; }
  pushEditOperations(_before: unknown, operations: { range: PluginRange; text: string }[]) {
    this.calls.push("edit");
    if (!this.open) { this.open = [...this.lines]; this.undo.push(this.open); }
    const offsetOf = (line: number, column: number) =>
      this.lines.slice(0, line - 1).reduce((sum, text) => sum + text.length + 1, 0) + column - 1;
    let text = this.value;
    for (const { range, text: insert } of [...operations].sort((a, b) =>
      offsetOf(b.range.startLineNumber, b.range.startColumn) - offsetOf(a.range.startLineNumber, a.range.startColumn))) {
      text = text.slice(0, offsetOf(range.startLineNumber, range.startColumn)) + insert +
        text.slice(offsetOf(range.endLineNumber, range.endColumn));
    }
    this.lines = text.split("\n");
    return null;
  }
  type(text: string) { this.pushEditOperations(null, [{ range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 }, text }]); }
  undoOnce() { const previous = this.undo.pop(); if (previous) this.lines = previous; this.open = undefined; }
}

class FakeView implements PluginEditView {
  start?: () => void; end?: () => void;
  constructor(public model: unknown, public focused = false,
    public selections = [{ selectionStartLineNumber: 1, selectionStartColumn: 1, positionLineNumber: 1, positionColumn: 1 }]) {}
  getModel() { return this.model; }
  getSelections() { return this.selections; }
  hasTextFocus() { return this.focused; }
  onDidCompositionStart(listener: () => void) { this.start = listener; return { dispose() {} }; }
  onDidCompositionEnd(listener: () => void) { this.end = listener; return { dispose() {} }; }
}

const edit = (sl: number, sc: number, el: number, ec: number, text: string): PluginEdit =>
  ({ startLineNumber: sl, startColumn: sc, endLineNumber: el, endColumn: ec, text });
const gate = (model: FakeModel, edits: PluginEdit[], overrides: Partial<Parameters<typeof checkPluginEdits>[0]> = {}) =>
  checkPluginEdits({ model, edits, readonly: false, busy: false, revision: 4, expectedRevision: 4,
    pendingEdits: 0, composing: false, ...overrides });

test("multi-selection batch with emoji and Chinese is one undo element", () => {
  const model = new FakeModel("a😀b\n中文");
  model.type("");
  const edits = [edit(1, 2, 1, 4, "X"), edit(2, 1, 2, 2, "英\n")];
  expect(gate(model, edits)).toBeUndefined();
  applyPluginEdits(model, edits, null);
  expect(model.value).toBe("aXb\n英\n文");
  expect(model.calls.slice(-3)).toEqual(["stop", "edit", "stop"]);
  // Typing right after the batch must not join its undo element.
  model.type("z");
  model.undoOnce();
  model.undoOnce();
  expect(model.value).toBe("a😀b\n中文");
});

test("rejects unacknowledged input, readonly, busy, composition and clamped ranges", () => {
  const model = new FakeModel("ab");
  const ok = [edit(1, 1, 1, 3, "x")];
  expect(gate(model, ok, { revision: 5 })).toBe("versionConflict");
  expect(gate(model, ok, { pendingEdits: 1 })).toBe("versionConflict");
  expect(gate(model, ok, { readonly: true })).toBe("readOnly");
  expect(gate(model, ok, { busy: true })).toBe("busy");
  expect(gate(model, ok, { composing: true })).toBe("composition");
  expect(gate(model, [edit(1, 1, 1, 4, "x")])).toBe("outOfRange");
  expect(gate(model, [edit(2, 1, 2, 1, "x")])).toBe("outOfRange");
  expect(model.calls).toEqual([]);
});

test("composition is tracked per view showing the model", () => {
  const model = {}, other = {};
  const tracker = new CompositionTracker();
  const showing = new FakeView(model), elsewhere = new FakeView(other);
  tracker.track(showing); tracker.track(elsewhere);
  elsewhere.start!();
  expect(tracker.isComposing(model, [showing, elsewhere])).toBe(false);
  showing.start!();
  expect(tracker.isComposing(model, [showing, elsewhere])).toBe(true);
  showing.end!();
  expect(tracker.isComposing(model, [showing, elsewhere])).toBe(false);
  showing.start!(); tracker.forget(showing);
  expect(tracker.isComposing(model, [showing])).toBe(false);
});

test("selections come from the focused view, keep direction and primary order", () => {
  const model = {};
  const background = new FakeView(model);
  const focused = new FakeView(model, true, [
    { selectionStartLineNumber: 2, selectionStartColumn: 5, positionLineNumber: 2, positionColumn: 1 },
    { selectionStartLineNumber: 1, selectionStartColumn: 1, positionLineNumber: 1, positionColumn: 1 },
  ]);
  const view = selectionView(model, [new FakeView({}), background, focused], background);
  expect(view).toBe(focused);
  expect(toPluginSelections(view!.getSelections())).toEqual([
    { anchorLine: 2, anchorColumn: 5, activeLine: 2, activeColumn: 1 },
    { anchorLine: 1, anchorColumn: 1, activeLine: 1, activeColumn: 1 },
  ]);
  expect(selectionView(model, [background], undefined)).toBe(background);
  expect(selectionView(model, [new FakeView({})], undefined)).toBeUndefined();
  expect(savedPluginSelections({ cursorState: [{ selectionStart: { lineNumber: 3, column: 2 }, position: { lineNumber: 1, column: 1 } }] }))
    .toEqual([{ anchorLine: 3, anchorColumn: 2, activeLine: 1, activeColumn: 1 }]);
  expect(savedPluginSelections(null)).toEqual([]);
});
