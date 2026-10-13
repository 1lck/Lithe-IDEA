import { afterEach, beforeEach, expect, test } from "bun:test";
import type * as monaco from "monaco-editor";
import type { ReviewRow } from "@lithe/editor/diff-review";
import { installHappyDom } from "@/test-utils/happy-dom";
import { mountIndependentCommitDiff } from "./independent-commit-diff-surface";

let restore: () => void;
let owner: ReturnType<typeof mountIndependentCommitDiff> | undefined;
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => {
  owner?.dispose();
  owner = undefined;
  restore();
});
function fixture(
  prepareLanguage: () => Promise<unknown> = async () => {},
  changed: () => void = () => {},
  wholeFileAdded = false,
) {
  const host = document.createElement("div");
  document.body.append(host);
  const frames = new Map<number, FrameRequestCallback>();
  let nextFrame = 0,
    disposed = 0,
    disconnected = false;
  const models: Array<{
    text: string;
    getLineCount: () => number;
    getLineMaxColumn: (line: number) => number;
  }> = [];
  const viewStates: Array<{
    top: number;
    left: number;
    horizontalRange: number;
    width: number;
    height: number;
    caret: number;
    selection: unknown;
    subscriptions: Map<string, Set<(event: any) => void>>;
    items: monaco.editor.IModelDeltaDecoration[];
    options: any;
    findCalls: number;
    revealed: number[];
    focusCalls: number;
  }> = [];
  const runtime = {
    Uri: { parse: (uri: string) => uri },
    Range: class {
      constructor(
        public startLineNumber: number,
        public startColumn: number,
        public endLineNumber: number,
        public endColumn: number,
      ) {}
    },
    editor: {
      EditorOption: { fontInfo: "font", lineHeight: "height" },
      ScrollType: { Immediate: 1 },
      createModel: (text: string) => {
        const model = {
          text,
          getValue: () => model.text,
          setValue: (text: string) => {
            model.text = text;
          },
          getLineCount: () => model.text.split("\n").length,
          getLineMaxColumn: (line: number) => (model.text.split("\n")[line - 1]?.length ?? 0) + 1,
          updateOptions: () => {},
          dispose: () => {
            disposed++;
          },
        };
        models.push(model);
        return model;
      },
      setModelLanguage: () => {},
      create: (_node: HTMLElement, options: any) => {
        const model = options.model;
        const state = {
          top: 0,
          left: 0,
          horizontalRange: 100,
          width: 0,
          height: 0,
          caret: 1,
          focusCalls: 0,
          selection: null as unknown,
          subscriptions: new Map<string, Set<(event: any) => void>>(),
          items: [] as monaco.editor.IModelDeltaDecoration[],
          options,
          findCalls: 0,
          revealed: [] as number[],
        };
        viewStates.push(state);
        const emit = (name: string, event: any = {}) =>
          state.subscriptions.get(name)?.forEach((fn) => fn(event));
        const subscribe = (name: string) => (fn: (event: any) => void) => {
          const set = state.subscriptions.get(name) ?? new Set();
          state.subscriptions.set(name, set);
          set.add(fn);
          return {
            dispose: () => {
              set.delete(fn);
            },
          };
        };
        const view = {
          getModel: () => model,
          getOption: (key: string) =>
            key === "font"
              ? { fontFamily: "monospace", fontSize: 14, typicalHalfwidthCharacterWidth: 8 }
              : 22,
          getContentHeight: () => model.getLineCount() * 22 + (state.options.padding?.bottom ?? 0),
          getScrollHeight: () => model.getLineCount() * 22 + (state.options.padding?.bottom ?? 0),
          getScrollWidth: () => state.width + state.horizontalRange,
          getTopForLineNumber: (line: number) => (line - 1) * 22,
          getBottomForLineNumber: (line: number) => line * 22,
          getScrollTop: () => state.top,
          getScrollLeft: () => state.left,
          setScrollTop: (value: number) => {
            state.top = Math.max(
              0,
              Math.min(
                model.getLineCount() * 22 + (state.options.padding?.bottom ?? 0) - state.height,
                value,
              ),
            );
            emit("scroll", { scrollTopChanged: true });
          },
          setScrollLeft: (value: number) => {
            state.left = Math.max(0, Math.min(state.horizontalRange, value));
            emit("scroll", { scrollLeftChanged: true });
          },
          getLayoutInfo: () => ({
            width: state.width,
            height: state.height,
            contentWidth: state.width,
          }),
          layout: (size: any) => {
            Object.assign(state, size);
          },
          updateOptions: (next: any) => {
            Object.assign(state.options, next);
          },
          getVisibleRanges: () => [
            {
              startLineNumber: Math.floor(state.top / 22) + 1,
              endLineNumber: Math.min(
                model.getLineCount(),
                Math.ceil((state.top + state.height) / 22),
              ),
            },
          ],
          getScrolledVisiblePosition: ({ lineNumber }: { lineNumber: number }) => ({
            top: (lineNumber - 1) * 22 - state.top,
            height: 22,
          }),
          getPosition: () => ({ lineNumber: state.caret, column: 1 }),
          setPosition: ({ lineNumber }: { lineNumber: number }) => {
            state.caret = lineNumber;
            emit("cursor");
          },
          getSelection: () => state.selection,
          setSelection: (selection: any) => {
            state.selection = selection;
          },
          focus: () => { state.focusCalls++; emit("focus"); },
          revealLineInCenter: (line: number) => {
            state.revealed.push(line);
          },
          getAction: () => ({
            run: async () => {
              state.findCalls++;
            },
          }),
          createDecorationsCollection: () => ({
            set: (items: any) => {
              state.items = items;
            },
            clear: () => {
              state.items = [];
            },
          }),
          onDidScrollChange: subscribe("scroll"),
          onDidContentSizeChange: subscribe("size"),
          onDidChangeCursorPosition: subscribe("cursor"),
          onDidFocusEditorText: subscribe("focus"),
          onKeyDown: subscribe("key"),
          onMouseDown: subscribe("down"),
          onMouseUp: subscribe("up"),
          dispose: () => {
            disposed++;
          },
        };
        return view;
      },
    },
  } as unknown as typeof monaco;
  let resize: () => void = () => {};
  owner = mountIndependentCommitDiff(host, {
    runtime,
    wholeFileAdded,
    prepareLanguage,
    source: () => {},
    changed,
    splitLayout: () => {},
    requestFrame: (fn) => {
      frames.set(++nextFrame, fn);
      return nextFrame;
    },
    cancelFrame: (id) => {
      frames.delete(id);
    },
    observeResize: (node, fn) => {
      Object.defineProperties(node, { clientWidth: { value: 800 }, clientHeight: { value: 220 } });
      resize = fn;
      return {
        disconnect: () => {
          disconnected = true;
        },
      };
    },
  });
  resize();
  const flush = () => {
    const pending = [...frames.values()];
    frames.clear();
    pending.forEach((fn) => fn(0));
  };
  const context = (id: number): ReviewRow => ({
    id: String(id),
    left: `line ${id}`,
    right: `line ${id}`,
    oldLine: 100 + id,
    newLine: 200 + id,
    kind: "context",
  });
  const rows: ReviewRow[] = [
    ...Array.from({ length: 5 }, (_, id) => context(id)),
    { id: "old", left: "old", right: null, oldLine: 105, newLine: null, kind: "removal" },
    ...Array.from({ length: 10 }, (_, id) => ({
      id: `new${id}`,
      left: null,
      right: `new ${id}`,
      oldLine: null,
      newLine: 205 + id,
      kind: "addition" as const,
    })),
    ...Array.from({ length: 30 }, (_, id) => context(id + 15)),
  ];
  return {
    host,
    rows,
    flush,
    frames,
    models,
    viewStates,
    get disposed() {
      return disposed;
    },
    get disconnected() {
      return disconnected;
    },
  };
}

test("commit block controls stay outside code and follow independent scroll coordinates", async () => {
  const f = fixture();
  const events: unknown[] = [];
  const center = f.host.querySelector<HTMLElement>(".independent-center")!;
  const logWidth = parseFloat(center.style.width);
  owner!.setBlockControls({
    blocks: [{ id: "old", checked: false, indeterminate: false, canToggle: true, canRollback: true,
      leftStart: 5, rightStart: 5 }], disabled: false,
    includeTitle: "include", excludeTitle: "exclude", rollbackTitle: "rollback",
    onToggle: (...args) => events.push(args), onRollback: id => events.push(id),
  });
  await owner!.update(f.rows, "plaintext", false, false);
  f.flush();
  expect(parseFloat(center.style.width) - logWidth).toBeGreaterThanOrEqual(36);
  const toggle = () => f.host.querySelector<HTMLButtonElement>(".commit-diff-block-toggle")!;
  expect(f.host.querySelector<HTMLElement>(".independent-numbers-0")!.style.paddingLeft).toBe("");
  expect(f.host.querySelector<HTMLElement>(".independent-numbers-1")!.style.paddingRight).toBe("");
  expect(toggle().style.top).toBe("112px");
  toggle().click();
  f.host.querySelector<HTMLButtonElement>(".commit-diff-block-rollback")!.click();
  expect(events).toEqual([["old", true], "old"]);
  owner!.views[1].setScrollTop(44);
  f.flush();
  expect(toggle().style.top).toBe("68px");
  expect(f.host.querySelector(".independent-code-1 .commit-diff-block-toggle")).toBeNull();
  owner!.setBlockControls(undefined);
  f.flush();
  expect(parseFloat(center.style.width)).toBe(logWidth);
  expect(f.host.querySelector(".commit-diff-block-toggle")).toBeNull();
});

test("whole added file has one full-width real stream, no empty deletion or connector", async () => {
  const f = fixture(async () => {}, () => {}, true);
  await owner!.update(f.rows.filter(row => row.right !== null).map(row => ({ ...row, left: null,
    oldLine: null, kind: "addition" as const })), "plaintext", false, true);
  f.flush();
  expect(f.host.querySelector<HTMLElement>(".independent-code-0")!.hidden).toBe(true);
  expect(f.host.querySelector<HTMLElement>(".independent-rail-0")!.hidden).toBe(true);
  expect(f.host.querySelector(".independent-connections")!.childElementCount).toBe(0);
  expect(f.viewStates[1].width).toBeGreaterThan(600);
});

test("vertical scroll follows corresponding context while horizontal offsets synchronize", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, true);
  f.flush();
  const initial = f.host.querySelector("path")!.getAttribute("d");
  owner!.views[1].setScrollTop(100);
  f.flush();
  expect(f.viewStates.map((state) => state.top)).toEqual([78, 100]);
  owner!.views[0].setScrollTop(60);
  owner!.views[0].setScrollLeft(50);
  f.flush();
  expect(f.viewStates.map((state) => state.top)).toEqual([60, 258]);
  expect(owner!.views[0].getTopForLineNumber(7) - f.viewStates[0].top).toBe(
    owner!.views[1].getTopForLineNumber(16) - f.viewStates[1].top,
  );
  expect(f.viewStates.map((state) => state.left)).toEqual([50, 50]);
  expect(f.host.querySelector("path")!.getAttribute("d")).not.toBe(initial);
  expect(f.host.querySelector(".independent-center svg")?.nextElementSibling?.className).toContain(
    "independent-numbers",
  );
  expect(f.host.querySelectorAll(".independent-rail")).toHaveLength(2);
  expect(f.host.querySelectorAll(".independent-rail-0 .independent-overview span")).toHaveLength(1);
  expect(f.models[0].getLineCount()).toBe(36);
  expect(f.models[1].getLineCount()).toBe(45);
  expect(f.viewStates.every((state) => state.options.scrollBeyondLastColumn === 0)).toBe(true);
  expect(f.viewStates.every((state) => state.options.scrollbar.vertical === "hidden")).toBe(true);
});

test("horizontal synchronization is bidirectional and shorter content does not pull the master back", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  owner!.views[1].setScrollTop(100);
  const tops = f.viewStates.map((state) => state.top);
  f.viewStates[1].horizontalRange = 20;
  const widths = owner!.views.map((view) => view.getScrollWidth());
  owner!.views[0].setScrollLeft(80);
  expect(f.viewStates.map((state) => state.left)).toEqual([80, 20]);
  owner!.views[1].setScrollLeft(15);
  expect(f.viewStates.map((state) => state.left)).toEqual([15, 15]);
  owner!.views[0].setScrollLeft(100);
  expect(f.viewStates.map((state) => state.left)).toEqual([100, 20]);
  owner!.views[1].setScrollLeft(0);
  expect(f.viewStates.map((state) => state.left)).toEqual([0, 0]);
  expect(f.viewStates.map((state) => state.top)).toEqual(tops);
  expect(owner!.views.map((view) => view.getScrollWidth())).toEqual(widths);
});

test("unequal blocks suppress sub-line backtracking and resume matching context", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  owner!.views[1].setScrollTop(100);
  expect(f.viewStates[0].top).toBe(78);
  owner!.views[1].setScrollTop(101);
  owner!.views[1].setScrollTop(103);
  expect(f.viewStates[0].top).toBe(78);
  owner!.views[1].setScrollTop(280);
  expect(f.viewStates[0].top).toBe(82);
  expect(owner!.views[0].getTopForLineNumber(8) - f.viewStates[0].top).toBe(
    owner!.views[1].getTopForLineNumber(17) - f.viewStates[1].top,
  );
});

test("both EOF positions align with five lines of padding and retain real model counts", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  owner!.configure({ padding: { top: 0, bottom: 110 }, scrollBeyondLastLine: false }, 4);
  owner!.views[1].setScrollTop(owner!.views[1].getScrollHeight());
  expect(f.models.map((model) => model.getLineCount())).toEqual([36, 45]);
  for (const side of [0, 1]) {
    const view = owner!.views[side];
    expect(f.viewStates[side].top).toBe(view.getScrollHeight() - view.getLayoutInfo().height);
    expect(
      view.getLayoutInfo().height -
        (view.getBottomForLineNumber(f.models[side].getLineCount()) - view.getScrollTop()),
    ).toBe(110);
  }
});

test("either outside scrollbar drives synchronization for wheel, keyboard and track clicks", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  f.flush();
  const left = f.host.querySelector(".independent-rail-0")!;
  const right = f.host.querySelector(".independent-rail-1")!;
  right.dispatchEvent(new window.WheelEvent("wheel", { deltaY: 80, cancelable: true }));
  expect(f.viewStates.map((state) => state.top)).toEqual([72, 160]);
  left.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", cancelable: true }));
  expect(f.viewStates.map((state) => state.top)).toEqual([94, 292]);
  right.dispatchEvent(
    new window.PointerEvent("pointerdown", { button: 0, clientY: 100, bubbles: true }),
  );
  expect(f.viewStates[0].top).toBeGreaterThan(94);
  expect(f.viewStates[1].top).toBeGreaterThan(292);
});

test("insertion, deletion and replacement borders cross their code viewport without spacer rows", async () => {
  const f = fixture();
  const rows: ReviewRow[] = [
    { id: "insert", kind: "addition", left: null, right: "inserted", oldLine: null, newLine: 1 },
    f.rows[0],
    { id: "before", kind: "removal", left: "before", right: null, oldLine: 2, newLine: null },
    { id: "after", kind: "addition", left: null, right: "after", oldLine: null, newLine: 3 },
    f.rows[1],
    { id: "delete", kind: "removal", left: "deleted", right: null, oldLine: 4, newLine: null },
  ];
  await owner!.update(rows, "plaintext", false, true);
  f.flush();
  expect(
    f.host.querySelectorAll(".independent-code-0 [data-kind=inserted][data-empty=true]"),
  ).toHaveLength(1);
  // At BOF half of the empty-side border is above the viewport; clipping must
  // not shift that half down and create a two-pixel seam against the divider.
  expect(
    f.host.querySelector<HTMLElement>(".independent-code-0 [data-kind=inserted][data-empty=true]")!
      .style.height,
  ).toBe("1px");
  expect(
    f.host.querySelectorAll(".independent-code-1 [data-kind=deleted][data-empty=true]"),
  ).toHaveLength(1);
  for (const side of [0, 1]) {
    expect(f.host.querySelectorAll(`.independent-code-${side} [data-kind=modified]`)).toHaveLength(
      2,
    );
    expect(f.models[side].getLineCount()).toBe(4);
  }
  expect(f.host.querySelectorAll(".independent-connection-fill")).toHaveLength(3);
});

test("outside scroll rails reserve code space and wider gutters adjoin both pane edges", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  f.flush();
  const left = f.host.querySelector<HTMLElement>(".independent-code-0")!;
  const right = f.host.querySelector<HTMLElement>(".independent-code-1")!;
  const center = f.host.querySelector<HTMLElement>(".independent-center")!;
  const root = f.host.querySelector<HTMLElement>(".independent-commit-diff")!;
  const railWidth = parseFloat(root.style.getPropertyValue("--independent-rail-width"));
  const railGap = parseFloat(root.style.getPropertyValue("--independent-rail-gap"));
  expect(railGap).toBeGreaterThan(0);
  expect(parseFloat(left.style.left)).toBe(railWidth + railGap);
  expect(parseFloat(left.style.left) + parseFloat(left.style.width)).toBe(
    parseFloat(center.style.left),
  );
  expect(parseFloat(right.style.left)).toBe(
    parseFloat(center.style.left) + parseFloat(center.style.width),
  );
  expect(parseFloat(right.style.left) + parseFloat(right.style.width)).toBe(
    800 - railWidth - railGap,
  );
  expect(parseFloat(center.style.width)).toBeGreaterThanOrEqual(100);
  expect(f.viewStates.every((state) => state.width > 250)).toBe(true);
  owner!.configure({ fontSize: 14 }, 4);
  expect(f.viewStates.every((state) => state.options.mouseWheelScrollSensitivity === 2)).toBe(true);
  expect(f.viewStates.every((state) => state.options.scrollbar.horizontalSliderSize < 12)).toBe(
    true,
  );
});

test("rail wheels honor line units and leave Ctrl-wheel to the browser", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  const rail = f.host.querySelector(".independent-rail-0")!;
  rail.dispatchEvent(new window.WheelEvent("wheel", { deltaY: 3, deltaMode: 1, cancelable: true }));
  expect(f.viewStates.map((state) => state.top)).toEqual([132, 330]);
  const zoom = new window.WheelEvent("wheel", { deltaY: 40, ctrlKey: true, cancelable: true });
  // Happy DOM's WheelEvent extends UIEvent and omits MouseEvent modifiers.
  Object.defineProperty(zoom, "ctrlKey", { value: true });
  rail.dispatchEvent(zoom);
  expect(zoom.defaultPrevented).toBe(false);
  expect(f.viewStates[0].top).toBe(132);
});

test("word highlighting mutes compared blocks and retains full backgrounds when disabled or oversized", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, true);
  expect(
    f.viewStates.every((state) =>
      state.items.some((item) => item.options.className?.includes("independent-line-muted")),
    ),
  ).toBe(true);
  await owner!.update(f.rows, "plaintext", false, false);
  expect(
    f.viewStates.every((state) =>
      state.items.every((item) => !item.options.className?.includes("independent-line-muted")),
    ),
  ).toBe(true);
  const oversized = f.rows.map((row) =>
    row.kind === "addition" ? { ...row, right: "x".repeat(20000) } : row,
  );
  await owner!.update(oversized, "plaintext", false, true);
  expect(
    f.viewStates.every((state) =>
      state.items.every((item) => !item.options.className?.includes("independent-line-muted")),
    ),
  ).toBe(true);
});

test("explicit difference navigation reveals both boundaries before resuming vertical synchronization", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  owner!.reveal(owner!.plan.changes[0]);
  expect(f.viewStates.map((state) => state.revealed)).toEqual([[6], [6]]);
  owner!.views[0].setScrollTop(80);
  expect(f.viewStates.map((state) => state.top)).toEqual([80, 278]);
});

test("Passive preview positions the first difference without taking focus; explicit navigation still focuses", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  const change = owner!.plan.changes[0];
  owner!.reveal(change, false);
  expect(f.viewStates.map((state) => state.revealed)).toEqual([[6], [6]]);
  expect(f.viewStates.map((state) => state.focusCalls)).toEqual([0, 0]);
  owner!.reveal(change);
  expect(f.viewStates.reduce((count, state) => count + state.focusCalls, 0)).toBe(1);
});
test("central number selection retains its initial anchor through reverse Shift-clicks", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, false);
  f.flush();
  const click = (line: number, shiftKey = false) =>
    f.host
      .querySelector(`.independent-numbers-0 [data-model-line='${line}']`)!
      .dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0, shiftKey }));
  click(3);
  click(1, true);
  click(2, true);
  expect(f.viewStates[0].selection).toMatchObject({
    selectionStartLineNumber: 3,
    positionLineNumber: 2,
  });
});
test("word preference changes retain text models, scroll offsets and release all owned resources", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", false, true);
  f.flush();
  owner!.views[1].setScrollTop(100);
  f.flush();
  const previous = f.viewStates.map((state) => state.top);
  await owner!.update(f.rows, "plaintext", false, false);
  f.flush();
  expect(f.viewStates.map((state) => state.top)).toEqual(previous);
  expect(f.models).toHaveLength(2);
  owner!.refresh();
  expect(f.frames.size).toBe(1);
  owner!.dispose();
  owner!.dispose();
  expect(f.frames.size).toBe(0);
  expect(f.disposed).toBe(4);
  expect(f.disconnected).toBe(true);
  expect(
    f.viewStates.every((state) => [...state.subscriptions.values()].every((set) => set.size === 0)),
  ).toBe(true);
  expect(f.host.querySelector(".independent-commit-diff")).toBeNull();
});
test("late tokenizer completion cannot revive an unmounted preview", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const f = fixture(() => gate);
  const update = owner!.update(f.rows, "plaintext", false, true);
  try {
    owner!.dispose();
    release();
    await update;
    expect(f.host.children).toHaveLength(0);
    expect(f.models[0].text).toBe("");
  } finally {
    release();
    await update;
  }
});

test("native find expands omitted context before searching the complete patch projection", async () => {
  const f = fixture();
  await owner!.update(f.rows, "plaintext", true, false);
  f.flush();
  expect(f.models[0].getLineCount()).toBeLessThan(36);
  const key = {
    ctrlKey: true,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    browserEvent: { key: "f" },
    preventDefault: () => {},
    stopPropagation: () => {},
  };
  f.viewStates[1].subscriptions.get("key")!.forEach((listener) => listener(key));
  f.flush();
  expect(f.models[0].getLineCount()).toBe(36);
  expect(f.models[1].getLineCount()).toBe(45);
  expect(f.viewStates[1].findCalls).toBe(1);
});

test("initial difference navigation observes both new models after synchronous cursor events", async () => {
  let first = true;
  const f = fixture(
    async () => {},
    () => {
      if (first && owner?.ready) {
        first = false;
        owner.reveal(owner.plan.changes[0]);
      }
    },
  );
  // Monaco emits cursor changes while setValue resets a model. Reproduce that
  // event between the two replacements; the new comparison must stay unready.
  const original = f.models[0] as (typeof f.models)[0] & { setValue: (text: string) => void };
  const setValue = original.setValue;
  original.setValue = (text) => {
    setValue(text);
    f.viewStates[0].subscriptions.get("cursor")!.forEach((listener) => listener({}));
  };
  await owner!.update(f.rows, "plaintext", false, true);
  f.flush();
  expect(owner!.views[1].getPosition()?.lineNumber).toBe(6);
  expect(f.models[1].getLineCount()).toBe(45);
});
