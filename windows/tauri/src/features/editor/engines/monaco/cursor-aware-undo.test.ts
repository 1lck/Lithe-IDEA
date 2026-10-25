import { describe, expect, test } from "bun:test";
import type { editor, Selection } from "monaco-editor";
import { createCursorAwareUndo } from "./cursor-aware-undo";

function emitter<T>(defaultEvent: T) {
  const listeners = new Set<(event: T) => void>();
  return {
    subscribe(listener: (event: T) => void) {
      listeners.add(listener);
      return {
        dispose: () => {
          listeners.delete(listener);
        },
      };
    },
    fire(event: T = defaultEvent) {
      for (const listener of listeners) listener(event);
    },
    count: () => listeners.size,
  };
}

// The policy consumes selection equality, while the browser probe exercises
// Monaco's real selections and cursor stack.
function cursorSelection(
  startLine: number,
  startColumn: number,
  endLine: number,
  endColumn: number,
): Selection {
  return {
    selectionStartLineNumber: startLine,
    selectionStartColumn: startColumn,
    positionLineNumber: endLine,
    positionColumn: endColumn,
    equalsSelection(other: Selection) {
      return (
        startLine === other.selectionStartLineNumber &&
        startColumn === other.selectionStartColumn &&
        endLine === other.positionLineNumber &&
        endColumn === other.positionColumn
      );
    },
  } as Selection;
}

function harness(writable = true) {
  const selection = emitter<editor.ICursorSelectionChangedEvent | null>(null);
  const content = emitter<editor.IModelContentChangedEvent>({
    changes: [],
    eol: "\n",
    versionId: 2,
    isUndoing: false,
    isRedoing: false,
    isFlush: false,
    isEolChange: false,
    detailedReasonsChangeLengths: [],
  });
  const model = emitter<editor.IModelChangedEvent>({ oldModelUrl: null, newModelUrl: null });
  const calls: string[] = [];
  let cursorActionsMove = true;
  const from = cursorSelection(1, 4, 1, 4);
  const to = cursorSelection(2, 4, 2, 4);
  const move = (overrides: Partial<editor.ICursorSelectionChangedEvent> = {}) => {
    selection.fire({
      selection: to,
      secondarySelections: [],
      oldSelections: [from],
      source: "keyboard",
      modelVersionId: 2,
      oldModelVersionId: 2,
      reason: 3,
      ...overrides,
    });
  };
  const history = createCursorAwareUndo(
    {
      onDidChangeCursorSelection: (listener) =>
        selection.subscribe((event) => {
          if (event) listener(event);
        }),
      onDidChangeModelContent: content.subscribe,
      onDidChangeModel: model.subscribe,
      trigger(_source, command) {
        calls.push(command);
        if (!cursorActionsMove && (command === "cursorUndo" || command === "cursorRedo")) return;
        // Monaco's native cursor actions synchronously emit an API selection;
        // text actions change the model before publishing their new selection.
        if (command === "undo" || command === "redo") content.fire();
        move({ source: "api" });
      },
    },
    writable,
  );
  return {
    history, calls, move, from, content, model, selection,
    setCursorActionsMove: (value: boolean) => {
      cursorActionsMove = value;
    },
  };
}

describe("cursor-aware text undo", () => {
  test("independent cursor undo lets generic redo restore the cursor before text", () => {
    const h = harness();
    try {
      h.move();
      h.history.cursorUndo();
      h.history.redo();
      h.history.redo();
      expect(h.calls).toEqual(["cursorUndo", "cursorRedo", "redo"]);
    } finally {
      h.history.dispose();
    }
  });

  test("explicit cursor redo consumes recovery and empty cursor undo leaves text redo available", () => {
    const h = harness();
    try {
      h.history.cursorUndo();
      h.history.cursorRedo();
      h.history.redo();
      h.setCursorActionsMove(false);
      h.history.cursorUndo();
      h.history.redo();
      expect(h.calls).toEqual(["cursorUndo", "cursorRedo", "redo", "cursorUndo", "redo"]);
    } finally {
      h.history.dispose();
    }
  });

  test("recovers one keyboard move, then undoes text even after multiple moves", () => {
    const h = harness();
    try {
      h.content.fire();
      h.move();
      h.move();
      h.history.undo();
      h.history.undo();
      h.history.redo();
      expect(h.calls).toEqual(["cursorUndo", "undo", "redo"]);
    } finally {
      h.history.dispose();
    }
  });

  test("redo restores the recovered cursor once, then returns to text history", () => {
    const h = harness();
    try {
      h.move();
      h.history.undo();
      h.history.redo();
      h.history.redo();
      expect(h.calls).toEqual(["cursorUndo", "cursorRedo", "redo"]);
    } finally {
      h.history.dispose();
    }
  });

  test("edits, model changes, mouse moves and version changes invalidate recovery", () => {
    const h = harness();
    try {
      for (const invalidate of [
        () => h.content.fire(),
        () => h.model.fire(),
        () => h.move({ source: "mouse" }),
        () => h.move({ oldModelVersionId: 1 }),
        () => h.move({ oldSelections: null }),
        () => h.move({ selection: h.from }),
      ]) {
        h.move();
        invalidate();
        h.history.undo();
        h.move();
        h.history.undo();
        invalidate();
        h.history.redo();
      }
      expect(h.calls).toEqual(
        Array.from({ length: 6 }, () => ["undo", "cursorUndo", "redo"]).flat(),
      );
    } finally {
      h.history.dispose();
    }
  });

  test("tracks selection and cursor-count changes without borrowing another view's history", () => {
    const first = harness();
    const second = harness();
    try {
      first.move({ selection: cursorSelection(1, 4, 2, 4) });
      second.history.undo();
      first.history.undo();
      first.move({ selection: first.from, secondarySelections: [cursorSelection(2, 4, 2, 4)] });
      first.history.undo();
      expect(first.calls).toEqual(["cursorUndo", "cursorUndo"]);
      expect(second.calls).toEqual(["undo"]);
    } finally {
      first.history.dispose();
      second.history.dispose();
    }
  });

  test("allows cursor recovery in read-only views and disposes every listener", () => {
    const h = harness(false);
    try {
      h.history.undo();
      h.move();
      h.history.undo();
      h.history.redo();
      h.history.undo();
      h.history.redo();
      expect(h.calls).toEqual(["cursorUndo", "cursorRedo"]);
    } finally {
      h.history.dispose();
    }
    expect([h.selection.count(), h.content.count(), h.model.count()]).toEqual([0, 0, 0]);
    h.move();
    h.history.undo();
    expect(h.calls).toEqual(["cursorUndo", "cursorRedo"]);
  });
});
