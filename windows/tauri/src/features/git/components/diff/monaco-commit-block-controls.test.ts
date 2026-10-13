import { expect, test } from "bun:test";
import type * as monaco from "monaco-editor";
import { installHappyDom } from "@/test-utils/happy-dom";
import { mountMonacoCommitBlockControls } from "./monaco-commit-block-controls";

test("unified review exposes accessible mixed checkboxes, separate rollback lanes, and removes widgets", () => {
  const restore = installHappyDom();
  const widgets = new Set<monaco.editor.IGlyphMarginWidget>();
  const toggles: unknown[] = [];
  const view = { getModel: () => ({ getLineCount: () => 30 }),
    getVisibleRanges: () => [{ startLineNumber: 1, endLineNumber: 30 }],
    onDidScrollChange: () => ({ dispose() {} }), onDidLayoutChange: () => ({ dispose() {} }),
    onDidChangeHiddenAreas: () => ({ dispose() {} }),
    addGlyphMarginWidget: (widget: monaco.editor.IGlyphMarginWidget) => widgets.add(widget),
    removeGlyphMarginWidget: (widget: monaco.editor.IGlyphMarginWidget) => widgets.delete(widget),
  } as unknown as monaco.editor.IStandaloneCodeEditor;
  const runtime = { editor: { GlyphMarginLane: { Left: 1, Right: 3 } },
    Range: class { constructor(public startLineNumber: number) {} },
  } as unknown as typeof monaco;
  const owner = mountMonacoCommitBlockControls(view, runtime, {
    blocks: [{ id: "first", checked: false, indeterminate: true, canToggle: true, canRollback: true,
      leftStart: 5, rightStart: 8 }], disabled: false,
    includeTitle: "include", excludeTitle: "exclude", rollbackTitle: "rollback",
    onToggle: (...args) => toggles.push(args), onRollback: id => toggles.push(id),
  });
  try {
    const [rollback, toggle] = [...widgets];
    expect(rollback.getPosition()!.lane).toBe(1);
    expect(toggle.getPosition()!.lane).toBe(3);
    expect(toggle.getPosition()!.range.startLineNumber).toBe(9);
    expect(toggle.getDomNode().getAttribute("aria-checked")).toBe("mixed");
    (toggle.getDomNode() as HTMLButtonElement).click();
    (rollback.getDomNode() as HTMLButtonElement).click();
    expect(toggles).toEqual([["first", true], "first"]);
    owner.dispose();
    expect(widgets.size).toBe(0);
  } finally { owner.dispose(); restore(); }
});

test("unified block widgets follow visible ranges and dispose coalesced frame work", () => {
  const restore = installHappyDom();
  // Drive frames explicitly: scrolling/folding must neither allocate every
  // file block nor leave callbacks and widgets alive after the owner closes.
  const frames = new Map<number, FrameRequestCallback>();
  let nextFrame = 0;
  globalThis.requestAnimationFrame = callback => { frames.set(++nextFrame, callback); return nextFrame; };
  globalThis.cancelAnimationFrame = id => { frames.delete(id); };
  const events = new Set<() => void>();
  const subscribe = (callback: () => void) => {
    events.add(callback);
    return { dispose() { events.delete(callback); } };
  };
  const flush = () => {
    const callbacks = [...frames.values()];
    frames.clear();
    callbacks.forEach(callback => callback(0));
  };
  const widgets = new Set<monaco.editor.IGlyphMarginWidget>();
  let ranges = [{ startLineNumber: 1, endLineNumber: 10 }];
  const view = {
    getModel: () => ({ getLineCount: () => 2000 }), getVisibleRanges: () => ranges,
    onDidScrollChange: subscribe, onDidLayoutChange: subscribe, onDidChangeHiddenAreas: subscribe,
    addGlyphMarginWidget: (widget: monaco.editor.IGlyphMarginWidget) => widgets.add(widget),
    removeGlyphMarginWidget: (widget: monaco.editor.IGlyphMarginWidget) => widgets.delete(widget),
  } as unknown as monaco.editor.IStandaloneCodeEditor;
  const runtime = { editor: { GlyphMarginLane: { Left: 1, Right: 3 } },
    Range: class { constructor(public startLineNumber: number) {} },
  } as unknown as typeof monaco;
  let owner: ReturnType<typeof mountMonacoCommitBlockControls> | undefined;
  try {
    owner = mountMonacoCommitBlockControls(view, runtime, {
      blocks: Array.from({ length: 100 }, (_, index) => ({ id: `block-${index}`,
        checked: false, indeterminate: false, canToggle: true, canRollback: true,
        leftStart: index * 20, rightStart: index * 20 })), disabled: false,
      includeTitle: "include", excludeTitle: "exclude", rollbackTitle: "rollback",
      onToggle() {}, onRollback() {},
    });
    expect(widgets.size).toBe(2);
    expect([...widgets].every(widget => widget.getDomNode().dataset.blockId === "block-0")).toBe(true);
    ranges = [{ startLineNumber: 1001, endLineNumber: 1010 }];
    events.forEach(callback => callback());
    expect(frames.size).toBe(1);
    flush();
    expect(widgets.size).toBe(2);
    expect([...widgets].every(widget => widget.getDomNode().dataset.blockId === "block-50")).toBe(true);
    ranges = [];
    events.forEach(callback => callback());
    flush();
    expect(widgets.size).toBe(0);
    events.forEach(callback => callback());
    expect(frames.size).toBe(1);
    owner.dispose();
    expect(frames.size).toBe(0);
    expect(events.size).toBe(0);
  } finally { owner?.dispose(); restore(); }
});
