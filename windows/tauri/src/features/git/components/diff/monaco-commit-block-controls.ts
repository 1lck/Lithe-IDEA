import type * as monaco from "monaco-editor";
import { commitDiffBlockControl, type CommitDiffBlockControls } from "./commit-diff-block-controls";

/** Unified review uses Monaco's public gutter-widget API. Monaco owns folding
 * and scroll placement; no internal DOM or synthetic action rows are needed. */
export function mountMonacoCommitBlockControls(
  view: monaco.editor.IStandaloneCodeEditor, runtime: typeof monaco,
  controls: CommitDiffBlockControls,
) {
  let disposed = false;
  let frame: number | null = null;
  const widgets = new Map<string, monaco.editor.IGlyphMarginWidget[]>();
  function draw() {
    frame = null;
    if (disposed) return;
    const wanted = new Set<string>();
    const count = view.getModel()?.getLineCount() ?? 1;
    for (const range of view.getVisibleRanges()) {
      let low = 0, high = controls.blocks.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (Math.min(count, controls.blocks[middle].rightStart + 1) < range.startLineNumber) low = middle + 1;
        else high = middle;
      }
      for (let index = low; index < controls.blocks.length; index++) {
        const block = controls.blocks[index];
        const line = Math.max(1, Math.min(count, block.rightStart + 1));
        if (line > range.endLineNumber) break;
        wanted.add(block.id);
        if (widgets.has(block.id)) continue;
        const pair = (["rollback", "toggle"] as const).map(action => {
          const node = commitDiffBlockControl(block, controls, action);
          const widget: monaco.editor.IGlyphMarginWidget = {
            getId: () => `lithe-commit-${block.id}-${action}`,
            getDomNode: () => node,
            getPosition: () => ({
              lane: action === "rollback" ? runtime.editor.GlyphMarginLane.Left : runtime.editor.GlyphMarginLane.Right,
              range: new runtime.Range(line, 1, line, 1), zIndex: 10,
            }),
          };
          view.addGlyphMarginWidget(widget);
          return widget;
        });
        widgets.set(block.id, pair);
      }
    }
    for (const [id, pair] of widgets) {
      if (!wanted.has(id)) { pair.forEach(widget => view.removeGlyphMarginWidget(widget)); widgets.delete(id); }
    }
  }
  const schedule = () => { if (!disposed && frame === null) frame = requestAnimationFrame(draw); };
  const listeners = [view.onDidScrollChange(schedule), view.onDidLayoutChange(schedule),
    view.onDidChangeHiddenAreas(schedule)];
  draw();
  return { dispose() {
    if (disposed) return;
    disposed = true;
    if (frame !== null) cancelAnimationFrame(frame);
    listeners.forEach(listener => listener.dispose());
    widgets.forEach(pair => pair.forEach(widget => view.removeGlyphMarginWidget(widget)));
    widgets.clear();
  } };
}
