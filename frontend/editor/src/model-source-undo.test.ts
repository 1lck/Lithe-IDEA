import { expect, mock, test } from "bun:test";

// EditorModelSource only touches EndOfLineSequence from the Monaco bundle; a
// stub keeps the test free of the browser-globals-laden full module.
mock.module("monaco-editor/esm/vs/editor/editor.api.js", () => ({
  editor: { EndOfLineSequence: { LF: 0, CRLF: 1 } },
}));

const { EditorModelSource } = await import("./model-source");

interface FakeContentChange {
  changes: { rangeOffset: number; rangeLength: number; text: string }[];
}

/** Minimal Monaco model double. `versionId` grows on every edit, while the
 * alternative versionId restores to the shared ancestor on undo — the exact
 * bookkeeping EditorModelSource keys its version mirror on. */
class FakeMonacoModel {
  value: string;
  versionId = 1;
  alternativeVersionId = 1;
  private listeners: ((event: FakeContentChange) => void)[] = [];

  constructor(value: string) {
    this.value = value;
  }

  setEOL(): void {}

  getAlternativeVersionId(): number {
    return this.alternativeVersionId;
  }

  onDidChangeContent(listener: (event: FakeContentChange) => void): { dispose: () => void } {
    this.listeners.push(listener);
    return { dispose: () => { this.listeners = this.listeners.filter((entry) => entry !== listener); } };
  }

  onWillDispose(): void {}

  /** Applies one edit the way Monaco does and notifies model listeners. */
  applyEdit(rangeOffset: number, rangeLength: number, text: string): void {
    this.value = this.value.slice(0, rangeOffset) + text + this.value.slice(rangeOffset + rangeLength);
    this.versionId += 1;
    this.alternativeVersionId = this.versionId;
    for (const listener of this.listeners) listener({ changes: [{ rangeOffset, rangeLength, text }] });
  }

  /** Undoes edits: content reverts while the alternative versionId returns to
   * the restored ancestor version, mirroring Monaco's undo bookkeeping. */
  undoTo(restoredVersion: number, rangeOffset: number, rangeLength: number, text: string): void {
    this.value = this.value.slice(0, rangeOffset) + text + this.value.slice(rangeOffset + rangeLength);
    this.versionId += 1;
    this.alternativeVersionId = restoredVersion;
    for (const listener of this.listeners) listener({ changes: [{ rangeOffset, rangeLength, text }] });
  }
}

test("undo after an edit updates the mirror before later model listeners read it", () => {
  const model = new FakeMonacoModel("a\n");
  const source = new EditorModelSource(model as never, "a\n");
  // The editor pipeline registers after the source; it must observe the undo,
  // not the preceding edit, even though Monaco restores the ancestor version.
  let observed: { content: string } | undefined;
  model.onDidChangeContent(() => { observed = source.lastChange; });

  model.applyEdit(2, 0, "x");
  expect(source.content).toBe("a\nx");

  model.undoTo(1, 2, 1, "");
  expect(model.value).toBe("a\n");
  expect(source.content).toBe("a\n");
  expect(observed?.content).toBe("a\n");
});

test("undoing a multi-edit typing burst keeps the mirror and lastChange aligned", () => {
  const model = new FakeMonacoModel("a\n");
  const source = new EditorModelSource(model as never, "a\n");
  const observed: string[] = [];
  model.onDidChangeContent(() => observed.push(source.lastChange?.content ?? "<missing>"));

  model.applyEdit(2, 0, "t");
  model.applyEdit(3, 0, "e");
  model.applyEdit(4, 0, "m");
  expect(source.content).toBe("a\ntem");

  model.undoTo(1, 2, 3, "");
  expect(model.value).toBe("a\n");
  expect(source.content).toBe("a\n");
  expect(observed[observed.length - 1]).toBe("a\n");
});
