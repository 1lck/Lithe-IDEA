import type { editor } from "monaco-editor";
import { debugSourcePathKey } from "../utils/debug-source-path";
import { useDebuggerStore } from "../stores/debugger.store";
import type { DebugBreakpoint, DebugStackFrame } from "../types/debugger.types";

/** Projection of the existing breakpoint/frame owner, not another debugger model. */
export function debugDecorations(
  filePath: string,
  breakpoints: DebugBreakpoint[],
  frame?: DebugStackFrame,
): editor.IModelDeltaDecoration[] {
  const key = debugSourcePathKey(filePath);
  const line = (number: number) => ({
    startLineNumber: number,
    startColumn: 1,
    endLineNumber: number,
    endColumn: 1,
  });
  const decorations: editor.IModelDeltaDecoration[] = breakpoints
    .filter((point) => debugSourcePathKey(point.filePath) === key)
    .map((point) => ({
      range: line(point.line + 1),
      options: {
        glyphMarginClassName: point.enabled
          ? "lithe-debug-breakpoint"
          : "lithe-debug-breakpoint-disabled",
        glyphMargin: { position: 2 },
        stickiness: 1,
      },
    }));
  if (frame?.sourcePath && debugSourcePathKey(frame.sourcePath) === key && frame.line > 0) {
    decorations.push({
      range: line(frame.line),
      options: {
        isWholeLine: true,
        className: "lithe-debug-paused-line",
      },
    });
  }
  return decorations;
}

export function bindMonacoDebugDecorations(view: editor.IStandaloneCodeEditor, filePath: string) {
  const collection = view.createDecorationsCollection();
  const sync = () => {
    const state = useDebuggerStore.getState();
    const frame =
      state.activeSession?.status === "paused"
        ? (state.stackFrames.find((item) => item.id === state.selectedFrameId) ??
          state.stackFrames[0])
        : undefined;
    collection.set(debugDecorations(filePath, state.breakpoints, frame));
  };
  const unsubscribe = useDebuggerStore.subscribe((state, previous) => {
    if (
      state.breakpoints !== previous.breakpoints ||
      state.stackFrames !== previous.stackFrames ||
      state.selectedFrameId !== previous.selectedFrameId ||
      state.activeSession?.status !== previous.activeSession?.status
    )
      sync();
  });
  sync();
  return {
    dispose() {
      unsubscribe();
      collection.clear();
    },
  };
}
