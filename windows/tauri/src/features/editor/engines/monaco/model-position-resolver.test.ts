import { describe, expect, test } from "bun:test";
import { createMonacoModelPositionResolver } from "./model-position-resolver";

function model(lines: string[]) {
  let disposed = false;
  return {
    isDisposed: () => disposed,
    dispose: () => {
      disposed = true;
    },
    validatePosition(position: { lineNumber: number; column: number }) {
      const lineNumber = Math.max(1, Math.min(lines.length, position.lineNumber));
      const column = Math.max(1, Math.min(lines[lineNumber - 1].length + 1, position.column));
      return { lineNumber, column };
    },
    getOffsetAt(position: { lineNumber: number; column: number }) {
      return (
        lines.slice(0, position.lineNumber - 1).reduce((sum, line) => sum + line.length + 1, 0) +
        position.column -
        1
      );
    },
    getLineLength: (lineNumber: number) => lines[lineNumber - 1].length,
  };
}

function surface() {
  let current: ReturnType<typeof model> | null = null;
  return {
    attach(next: typeof current) {
      current = next;
    },
    editor: {
      getModel: () => current,
      getTopForLineNumber: (lineNumber: number) => 100 + (lineNumber - 1) * 22,
      getOffsetForColumn: (_lineNumber: number, column: number) => (column - 1) * 8,
    },
  };
}

describe("live Monaco model position resolver", () => {
  test("resolves after an initially unloaded surface gets its editor and model", () => {
    const view = surface();
    let currentEditor: typeof view.editor | null = null;
    const resolve = createMonacoModelPositionResolver(() => currentEditor, 22);
    expect(resolve(1, 4)).toBeNull();
    currentEditor = view.editor;
    expect(resolve(1, 4)).toBeNull();

    view.attach(model(["alpha", "second"]));
    expect(resolve(1, 4)).toMatchObject({
      line: 1,
      column: 4,
      offset: 10,
      top: 122,
      left: 32,
      height: 22,
      segment: { modelLine: 1, endColumn: 6 },
    });
  });

  test("one resolver follows a reused editor to a shorter model", () => {
    const view = surface();
    const first = model(["alpha", "second"]);
    view.attach(first);
    const resolve = createMonacoModelPositionResolver(() => view.editor, 22);
    expect(resolve(1, 4)?.line).toBe(1);

    first.dispose();
    view.attach(model(["x"]));
    expect(resolve(1, 4)).toMatchObject({
      line: 0,
      column: 1,
      offset: 1,
      top: 100,
      left: 8,
      segment: { modelLine: 0, endColumn: 1 },
    });
  });

  test("stops resolving detached or disposed models and resumes after loading", () => {
    const view = surface();
    const first = model(["alpha"]);
    view.attach(first);
    const resolve = createMonacoModelPositionResolver(() => view.editor, 22);
    first.dispose();
    expect(resolve(0, 0)).toBeNull();
    view.attach(null);
    expect(resolve(0, 0)).toBeNull();
    view.attach(model(["next"]));
    expect(resolve(0, 2)).toMatchObject({ line: 0, column: 2, left: 16 });
  });
});
