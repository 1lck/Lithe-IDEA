import { editor as monacoEditor } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import { documentUsesCrlf, toMonacoModelValue } from "./line-endings";

export function applyMonacoModelContent(model: Monaco.editor.ITextModel, content: string): void {
  const value = toMonacoModelValue(content);
  const wantsCrlf = documentUsesCrlf(content);
  if (model.getValueLength() !== value.length) {
    model.setValue(value);
  } else if (toMonacoModelValue(model.getValue()) !== value) {
    model.setValue(value);
  }
  if ((model.getEOL() === "\r\n") !== wantsCrlf) {
    model.setEOL(
      wantsCrlf ? monacoEditor.EndOfLineSequence.CRLF : monacoEditor.EndOfLineSequence.LF,
    );
  }
}
