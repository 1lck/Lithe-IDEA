import { editor as monacoEditor } from "monaco-editor/esm/vs/editor/editor.api.js";
import type * as Monaco from "monaco-editor";
import { SourceText, type SourceTextChange } from "./source-text";
import { toMonacoModelValue } from "./line-endings";

export interface SourceModelChange {
  previousContent: string;
  content: string;
  changes: SourceTextChange[];
  external: boolean;
}
const sources = new WeakMap<Monaco.editor.ITextModel, EditorModelSource>();

/** A model has one source mirror even when multiple React surfaces observe it. */
export function acquireEditorModelSource(model: Monaco.editor.ITextModel, content: string): EditorModelSource {
  let source = sources.get(model);
  if (!source) {
    source = new EditorModelSource(model, content);
    sources.set(model, source);
  }
  return source;
}

export class EditorModelSource {
  private source: SourceText;
  private external = false;
  content: string;
  lastChange: SourceModelChange | undefined;

  constructor(private readonly model: Monaco.editor.ITextModel, content: string) {
    model.setEOL(monacoEditor.EndOfLineSequence.LF);
    this.source = new SourceText(content, model.getAlternativeVersionId());
    this.content = content;
    const subscription = model.onDidChangeContent(event => {
      const previousContent = this.content;
      if (this.external) {
        this.lastChange = { previousContent, content: this.content, changes: [], external: true };
        return;
      }
      const changes = this.source.apply(event.changes, model.getAlternativeVersionId());
      let next = previousContent;
      for (const change of [...changes].sort((a, b) => b.offset - a.offset)) {
        next = next.slice(0, change.offset) + change.text + next.slice(change.offset + change.length);
      }
      this.content = next;
      this.lastChange = { previousContent, content: next, changes, external: false };
    });
    model.onWillDispose(() => { subscription.dispose(); sources.delete(model); });
  }

  replace(content: string): void {
    this.external = true;
    try {
      this.model.setValue(toMonacoModelValue(content));
      this.model.setEOL(monacoEditor.EndOfLineSequence.LF);
      this.source = new SourceText(content, this.model.getAlternativeVersionId());
      this.content = content;
    } finally { this.external = false; }
  }
}

/** Positions for LSP are calculated against the source before a simultaneous batch. */
export function sourcePositionAt(content: string, offset: number): { line: number; column: number } {
  let line = 0, start = 0;
  for (let index = 0; index < offset; index++) {
    if (content[index] === "\r") {
      if (index + 1 < offset && content[index + 1] === "\n") index++;
      line++; start = index + 1;
    } else if (content[index] === "\n") { line++; start = index + 1; }
  }
  return { line, column: offset - start };
}
