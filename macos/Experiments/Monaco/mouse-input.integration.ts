import { editor as monacoEditor, Range } from "monaco-editor/esm/vs/editor/editor.api.js";
import { installWebKitMouseInput } from "../../EditorFrontend/mouse-input";

const source = "alpha beta gamma delta\nsecond line with words\nthird line for selection";
const assert = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
type Emit = (type: string, line: number, column: number, buttons: number, options?: MouseEventInit) => MouseEvent;

function withEditor(run: (view: monacoEditor.IStandaloneCodeEditor, emit: Emit) => void) {
  const container = document.createElement("div");
  container.style.cssText = "position:fixed;inset:0;width:800px;height:400px;z-index:10000";
  document.body.append(container);
  const model = monacoEditor.createModel(source, "plaintext");
  const view = monacoEditor.create(container, {
    model, fontSize: 16, minimap: { enabled: false }, scrollBeyondLastLine: false,
  });
  const node = view.getDomNode()!;
  try {
    view.render(true);
    const emit: Emit = (type, lineNumber, column, buttons, options = {}) => {
      const position = view.getScrolledVisiblePosition({ lineNumber, column })!;
      const bounds = node.getBoundingClientRect();
      const clientX = bounds.left + position.left + 1;
      const clientY = bounds.top + position.top + position.height / 2;
      const target = document.elementFromPoint(clientX, clientY);
      assert(target && node.contains(target), "mouse fixture missed its editor");
      const init: PointerEventInit = {
        bubbles: true, cancelable: true, view: window, clientX, clientY,
        button: 0, buttons, detail: 1, pointerId: 1, pointerType: "mouse", isPrimary: true, ...options,
      };
      const event = type.startsWith("pointer") ? new PointerEvent(type, init) : new MouseEvent(type, init);
      target!.dispatchEvent(event);
      return event;
    };
    run(view, emit);
  } finally {
    // Synthetic input cannot acquire native capture. Release both possible
    // monitoring targets before disposing, including after failed assertions.
    node.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, pointerId: 1, pointerType: "mouse" }));
    view.dispose(); model.dispose(); container.remove();
  }
}

function releasedTap(emit: Emit, line: number, column: number, detail = 1) {
  // WebKit #219670: an IME can dispatch the release before the press. Unlike
  // an ordinary click, the late mousedown reports no currently pressed buttons.
  emit("pointerup", line, column, 0);
  emit("mouseup", line, column, 0);
  emit("pointerdown", line, column, 0);
  return emit("mousedown", line, column, 0, { detail });
}

function click(emit: Emit, line: number, column: number, options: MouseEventInit = {}) {
  emit("pointerdown", line, column, 1, options);
  emit("mousedown", line, column, 1, options);
  emit("pointerup", line, column, 0, options);
  emit("mouseup", line, column, 0, options);
}

function expectCaret(view: monacoEditor.IStandaloneCodeEditor, line: number, column: number) {
  assert(view.getSelection()!.equalsRange(new Range(line, column, line, column)), "unpressed movement extended the caret");
}

export const mouseInputCases: { name: string; run(): void }[] = [
  {
    name: "IME reordered taps remain independent clicks during unpressed movement",
    run: () => withEditor((view, emit) => {
      releasedTap(emit, 1, 3);
      expectCaret(view, 1, 3);
      emit("pointermove", 3, 12, 0);
      expectCaret(view, 1, 3);
      releasedTap(emit, 2, 5, 2);
      expectCaret(view, 2, 5);
      emit("pointermove", 1, 18, 0);
      expectCaret(view, 2, 5);
      assert(view.getValue() === source, "clicks modified text");
    }),
  },
  {
    name: "IME reordered click on selected text cannot drag it on hover",
    run: () => withEditor((view, emit) => {
      view.setSelection(new Range(1, 1, 1, 6));
      releasedTap(emit, 1, 3);
      emit("pointermove", 3, 12, 0);
      emit("pointerup", 3, 12, 0);
      assert(view.getValue() === source, "unpressed movement relocated selected text");
    }),
  },
  {
    name: "pressed drag still selects and stops when released",
    run: () => withEditor((view, emit) => {
      emit("pointerdown", 1, 3, 1);
      emit("mousedown", 1, 3, 1);
      emit("pointermove", 3, 12, 1);
      assert(view.getSelection()!.equalsRange(new Range(1, 3, 3, 12)), "normal drag selection changed");
      emit("pointerup", 3, 12, 0);
      emit("mouseup", 3, 12, 0);
      emit("pointermove", 1, 18, 0);
      assert(view.getSelection()!.equalsRange(new Range(1, 3, 3, 12)), "released drag kept selecting");
    }),
  },
  {
    name: "ordinary and reordered double clicks retain word selection",
    run: () => withEditor((view, emit) => {
      click(emit, 1, 8);
      click(emit, 1, 8, { detail: 2 });
      assert(view.getSelection()!.equalsRange(new Range(1, 7, 1, 11)), "ordinary double click lost word selection");
      releasedTap(emit, 2, 10);
      releasedTap(emit, 2, 10, 2);
      assert(view.getSelection()!.equalsRange(new Range(2, 8, 2, 12)), "reordered double click lost word selection");
      emit("pointermove", 3, 12, 0);
      assert(view.getSelection()!.equalsRange(new Range(2, 8, 2, 12)), "double click kept selecting after release");
    }),
  },
  {
    name: "shift click continues extending an existing selection",
    run: () => withEditor((view, emit) => {
      click(emit, 1, 3);
      click(emit, 2, 10, { shiftKey: true });
      assert(view.getSelection()!.equalsRange(new Range(1, 3, 2, 10)), "shift click lost its anchor");
    }),
  },
  {
    name: "WebKit normalization preserves event identity and releases its listener",
    run: () => {
      // A separate document isolates lifecycle checks from the production host's listener.
      const isolated = document.implementation.createHTMLDocument();
      const node = isolated.createElement("div");
      isolated.body.append(node);
      const input = installWebKitMouseInput(isolated);
      const event = (buttons: number, button = 0) => new MouseEvent("mousedown", {
        bubbles: true, buttons, button, detail: 2, shiftKey: true, metaKey: true, clientX: 17, clientY: 23,
      });
      try {
        const outside = event(0); node.dispatchEvent(outside);
        assert(outside.buttons === 0, "non-editor control was changed");
        node.className = "monaco-editor";
        const left = event(0); node.dispatchEvent(left);
        assert(left.buttons === 1 && left.detail === 2 && left.shiftKey && left.metaKey &&
          left.clientX === 17 && left.clientY === 23, "normalization replaced click semantics");
        const middle = event(0, 1); node.dispatchEvent(middle);
        assert(middle.buttons === 4, "middle button used the wrong mask");
        const right = event(0, 2); node.dispatchEvent(right);
        assert(right.buttons === 0, "context menu press was changed");
        const held = event(5); node.dispatchEvent(held);
        assert(held.buttons === 5, "existing button combination was changed");
      } finally { input.dispose(); }
      const after = event(0); node.dispatchEvent(after);
      assert(after.buttons === 0, "disposed listener still normalized input");
    },
  },
];
