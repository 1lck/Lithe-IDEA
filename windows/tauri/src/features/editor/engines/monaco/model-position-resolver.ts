import type { editor, IPosition } from "monaco-editor";
import type { EditorModelPositionResolver } from "../../view-model/view-layout";

type PositionModel = Pick<editor.ITextModel, "isDisposed" | "getOffsetAt" | "getLineLength"> & {
  validatePosition(position: IPosition): IPosition;
};
type PositionEditor = Pick<editor.ICodeEditor, "getTopForLineNumber" | "getOffsetForColumn"> & {
  getModel(): PositionModel | null;
};

/** Resolve against the live model: a reused surface may be loading or showing another file. */
export function createMonacoModelPositionResolver(
  getEditor: () => PositionEditor | null,
  lineHeight: number,
): EditorModelPositionResolver {
  return (line, column) => {
    const view = getEditor();
    const model = view?.getModel();
    if (!view || !model || model.isDisposed()) return null;
    const position = model.validatePosition({ lineNumber: line + 1, column: column + 1 });

    try {
      const modelLine = position.lineNumber - 1;
      const top = view.getTopForLineNumber(position.lineNumber);
      const lineLength = model.getLineLength(position.lineNumber);
      return {
        line: modelLine,
        column: position.column - 1,
        offset: model.getOffsetAt(position),
        viewLine: modelLine,
        modelLine,
        top,
        left: view.getOffsetForColumn(position.lineNumber, position.column),
        height: lineHeight,
        segment: {
          viewLine: modelLine,
          modelLine,
          startColumn: 0,
          endColumn: lineLength,
          top,
          height: lineHeight,
        },
      };
    } catch (error) {
      if (model.isDisposed()) return null;
      throw error;
    }
  };
}
