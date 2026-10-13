import type * as monaco from "monaco-editor";
import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import {
  startDocumentResizeSession,
  type DocumentResizeSession,
} from "@/utils/document-resize-session";
import type { ReviewRow } from "@lithe/editor/diff-review";
import { commitDiffChangeID } from "../../utils/commit-diff-blocks";
import { commitDiffBlockControl, type CommitDiffBlockControls } from "./commit-diff-block-controls";
import {
  commitDiffConnectorPath,
  commitDiffConnectorBorderPath,
} from "../../utils/commit-diff-chrome-geometry";
import {
  commitDiffWordRanges,
  planIndependentCommitDiff,
  commitDiffScrollAnchors,
  transferCommitDiffLine,
  type IndependentChange,
} from "../../utils/independent-commit-diff";

const RAIL_WIDTH = 12,
  RAIL_GAP = 4,
  SLIDER_WIDTH = 8,
  WHEEL_SENSITIVITY = EDITOR_CONSTANTS.MOUSE_WHEEL_SCROLL_SENSITIVITY,
  MIN_CODE_WIDTH = 80,
  GUTTER_INSET = 10,
  BLOCK_ACTION_WIDTH = 22,
  BLOCK_ACTION_SIZE = 18,
  CONNECTOR_WIDTH = 16;
const SVG_NS = "http://www.w3.org/2000/svg";
let nextID = 0;
type Side = 0 | 1;
interface Options {
  runtime: typeof monaco;
  wholeFileAdded?: boolean;
  prepareLanguage: (language: string) => Promise<unknown>;
  requestFrame?: (callback: FrameRequestCallback) => number;
  cancelFrame?: (handle: number) => void;
  observeResize?: (node: HTMLElement, callback: () => void) => { disconnect: () => void };
  source: (side: Side, line: number, column: number) => void;
  changed: () => void;
  failed?: (error: unknown) => void;
  splitLayout: (width: number) => void;
}

/** Single-file layout owner; standalone Monaco controls only own text and selection.
 * Git owns the edit script. Vertical scrolling follows its matching boundaries;
 * each pane keeps its own scrollbar and code selection; horizontal offsets sync.
 * Note: .agents/notes/implemented/feature/2026-10-04-windows-commit-file-diff-preview.md
 */
export function mountIndependentCommitDiff(host: HTMLElement, options: Options) {
  const monaco = options.runtime;
  const requestFrame = options.requestFrame ?? requestAnimationFrame;
  const cancelFrame = options.cancelFrame ?? cancelAnimationFrame;
  const root = document.createElement("div");
  root.className = "independent-commit-diff";
  if (options.wholeFileAdded) root.dataset.wholeFileAdded = "true";
  root.style.setProperty("--independent-rail-width", `${RAIL_WIDTH}px`);
  root.style.setProperty("--independent-slider-width", `${SLIDER_WIDTH}px`);
  root.style.setProperty("--independent-gutter-inset", `${GUTTER_INSET}px`);
  root.style.setProperty("--independent-block-action-width", `${BLOCK_ACTION_WIDTH}px`);
  root.style.setProperty("--independent-block-action-size", `${BLOCK_ACTION_SIZE}px`);
  host.append(root);
  const nodes = [0, 1].map((side) => {
    const node = document.createElement("div");
    node.className = `independent-code independent-code-${side}`;
    root.append(node);
    return node;
  });
  const center = document.createElement("div");
  center.className = "independent-center";
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.classList.add("independent-connections");
  center.append(svg);
  const numbers = [0, 1].map((side) => {
    const node = document.createElement("div");
    node.className = `independent-numbers independent-numbers-${side}`;
    center.append(node);
    return node;
  });
  root.append(center);
  const sash = document.createElement("div");
  sash.className = "independent-sash";
  sash.tabIndex = 0;
  sash.setAttribute("role", "separator");
  sash.setAttribute("aria-label", "Resize diff panes");
  sash.setAttribute("aria-orientation", "vertical");
  root.append(sash);
  const rails = [0, 1].map((side) => {
    const rail = document.createElement("div");
    rail.className = `independent-rail independent-rail-${side}`;
    rail.tabIndex = 0;
    rail.setAttribute("role", "scrollbar");
    rail.setAttribute("aria-orientation", "vertical");
    rail.setAttribute("aria-label", side ? "New revision scroll" : "Previous revision scroll");
    const marks = document.createElement("div");
    marks.className = "independent-overview";
    const thumb = document.createElement("div");
    thumb.className = "independent-thumb";
    rail.append(marks, thumb);
    root.append(rail);
    return { rail, marks, thumb };
  });
  const actions = [0, 1].map(side => {
    const node = document.createElement("div");
    node.className = `independent-block-actions independent-block-actions-${side}`;
    center.append(node);
    return node;
  });
  let blockControls: CommitDiffBlockControls | undefined;
  let blocksByID = new Map<string, CommitDiffBlockControls["blocks"][number]>();
  if (options.wholeFileAdded) {
    // An absent original file is not a deleted empty line. Show only real new rows.
    nodes[0].hidden = true;
    numbers[0].hidden = true;
    actions[0].hidden = true;
    rails[0].rail.hidden = true;
    sash.hidden = true;
  }
  const id = ++nextID;
  const models = [0, 1].map((side) =>
    monaco.editor.createModel(
      "",
      "plaintext",
      monaco.Uri.parse(`lithe-independent-review://${id}/${side}`),
    ),
  );
  const views = nodes.map((node, index) =>
    monaco.editor.create(node, {
      model: models[index],
      readOnly: true,
      domReadOnly: true,
      lineNumbers: "off",
      lineDecorationsWidth: 0,
      glyphMargin: false,
      minimap: { enabled: false },
      overviewRulerLanes: 0,
      overviewRulerBorder: false,
      folding: false,
      stickyScroll: { enabled: false },
      scrollBeyondLastLine: false,
      scrollBeyondLastColumn: 0,
      smoothScrolling: false,
      mouseWheelScrollSensitivity: WHEEL_SENSITIVITY,
      wordWrap: "off",
      padding: { top: 0, bottom: 0 },
      renderValidationDecorations: "off",
      occurrencesHighlight: "off",
      selectionHighlight: false,
      renderLineHighlight: "none",
      guides: { indentation: false, bracketPairs: false, highlightActiveIndentation: false },
      scrollbar: {
        vertical: "hidden",
        verticalScrollbarSize: 0,
        horizontal: "visible",
        horizontalScrollbarSize: RAIL_WIDTH,
        horizontalSliderSize: SLIDER_WIDTH,
        useShadows: false,
        alwaysConsumeMouseWheel: false,
        ignoreHorizontalScrollbarInContentHeight: true,
      },
    }),
  );
  // Empty-side insertion/deletion lines must cross the visible code viewport,
  // including space beyond the longest line, without enlarging its scroll range.
  const borders = nodes.map((node) => {
    const layer = document.createElement("div");
    layer.className = "independent-chunk-borders";
    node.append(layer);
    return layer;
  });
  const decorations = views.map((view) => view.createDecorationsCollection());
  let plan = planIndependentCommitDiff([], false, new Set());
  let scrollAnchors = commitDiffScrollAnchors([], 0, 0);
  let syncing = false,
    scrollSyncPaused = 0;
  const withoutScrollSync = (operation: () => void) => {
    scrollSyncPaused++;
    try {
      operation();
    } finally {
      scrollSyncPaused--;
    }
  };
  let rawRows: readonly ReviewRow[] = [],
    collapse = false,
    words = true,
    focused: Side = 1;
  let closed = false,
    ready = false,
    frame: number | null = null;
  let ratio = 0.5,
    gutter = 44,
    centerWidth = 120,
    width = 0,
    height = 0;
  let version = 0,
    dirtyGeometry = true,
    digits = 3;
  let changePixels: Array<{
    change: IndependentChange;
    left: readonly [number, number];
    right: readonly [number, number];
  }> = [];
  const expanded = new Set<string>();
  let drag: DocumentResizeSession | undefined;

  const pixels = (side: Side, start: number, end: number): readonly [number, number] => {
    const view = views[side],
      count = models[side].getLineCount();
    const top =
      start >= count ? view.getBottomForLineNumber(count) : view.getTopForLineNumber(start + 1);
    return [top, end === start ? top : view.getBottomForLineNumber(Math.min(count, end))];
  };
  function geometry() {
    if (!dirtyGeometry) return;
    dirtyGeometry = false;
    changePixels = [];
    for (const change of plan.changes) {
      const a = pixels(0, change.leftStart, change.leftEnd),
        b = pixels(1, change.rightStart, change.rightEnd);
      changePixels.push({ change, left: a, right: b });
    }
    for (const side of [0, 1] as const) {
      const markers = document.createDocumentFragment(),
        total = Math.max(1, views[side].getScrollHeight());
      for (const value of changePixels) {
        const [start, end] = side ? value.right : value.left;
        const mark = document.createElement("span");
        mark.className = `independent-overview-${value.change.kind}`;
        mark.style.top = `${(Math.max(0, height - RAIL_WIDTH) * start) / total}px`;
        mark.style.height = `${Math.max(2, (Math.max(0, height - RAIL_WIDTH) * (end - start)) / total)}px`;
        markers.append(mark);
      }
      rails[side].marks.replaceChildren(markers);
    }
  }
  function schedule() {
    if (!closed && frame === null) frame = requestFrame(draw);
  }
  function layout() {
    if (closed) return;
    width = root.clientWidth;
    height = root.clientHeight;
    const font = views[0].getOption(monaco.editor.EditorOption.fontInfo);
    const actionWidth = blockControls ? BLOCK_ACTION_WIDTH : 0;
    gutter = Math.ceil(digits * font.typicalHalfwidthCharacterWidth + GUTTER_INSET * 2) + actionWidth;
    if (options.wholeFileAdded) {
      const railInset = Math.min(RAIL_WIDTH + RAIL_GAP, width);
      const railWidth = Math.min(RAIL_WIDTH, railInset);
      centerWidth = Math.min(gutter, Math.max(0, width - railInset));
      const codeWidth = Math.max(0, width - centerWidth - railInset);
      rails[1].rail.style.width = `${railWidth}px`;
      nodes[1].style.cssText = `left:${centerWidth}px;width:${codeWidth}px`;
      withoutScrollSync(() => views[1].layout({ width: codeWidth, height }));
      center.style.cssText = `left:0;width:${centerWidth}px;height:${Math.max(0, height - RAIL_WIDTH)}px`;
      numbers[1].style.width = `${centerWidth}px`;
      actions[1].style.width = numbers[1].style.width;
      numbers[1].style.fontFamily = font.fontFamily;
      numbers[1].style.fontSize = `${font.fontSize}px`;
      options.splitLayout(0);
      dirtyGeometry = true;
      schedule();
      return;
    }
    centerWidth = Math.min(
      gutter * 2 + CONNECTOR_WIDTH,
      Math.max(0, width - Math.min(width, MIN_CODE_WIDTH * 2)),
    );
    // Integer pane edges keep Monaco's integer layout and SVG gutters adjoining.
    const leftEdge = Math.round(
      Math.max(0, Math.min(width - centerWidth, width * ratio - centerWidth / 2)),
    );
    const rightStart = leftEdge + centerWidth,
      split = leftEdge + centerWidth / 2;
    const railInset = Math.min(RAIL_WIDTH + RAIL_GAP, leftEdge, width - rightStart);
    const railWidth = Math.min(RAIL_WIDTH, railInset),
      railGap = railInset - railWidth;
    root.style.setProperty("--independent-rail-gap", `${railGap}px`);
    rails.forEach(({ rail }) => {
      rail.style.width = `${railWidth}px`;
    });
    const leftWidth = Math.max(0, leftEdge - railInset),
      rightWidth = Math.max(0, width - rightStart - railInset);
    nodes[0].style.cssText = `left:${railInset}px;width:${leftWidth}px`;
    nodes[1].style.cssText = `left:${rightStart}px;width:${rightWidth}px`;
    withoutScrollSync(() => {
      views[0].layout({ width: leftWidth, height });
      views[1].layout({ width: rightWidth, height });
    });
    center.style.cssText = `left:${leftEdge}px;width:${centerWidth}px;height:${Math.max(0, height - RAIL_WIDTH)}px`;
    sash.style.left = `${split - 3}px`;
    sash.setAttribute("aria-valuenow", String(Math.round(100 * ratio)));
    svg.setAttribute("width", String(centerWidth));
    svg.setAttribute("height", String(Math.max(0, height - RAIL_WIDTH)));
    for (const [side, number] of numbers.entries()) {
      number.style.width = `${Math.min(gutter, centerWidth / 2)}px`;
      actions[side].style.width = number.style.width;
      number.style.fontFamily = font.fontFamily;
      number.style.fontSize = `${font.fontSize}px`;
    }
    options.splitLayout(split);
    dirtyGeometry = true;
    schedule();
  }
  function draw() {
    frame = null;
    if (closed || !ready) return;
    geometry();
    const paths = document.createDocumentFragment();
    const edges = borders.map(() => document.createDocumentFragment());
    const controls = actions.map(() => document.createDocumentFragment());
    const offsets = views.map((view) => view.getScrollTop());
    // Binary-search both independently scrolling viewports before creating paths.
    const bound = (side: Side, offset: number, end: boolean) => {
      let low = 0,
        high = changePixels.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        const range = side ? changePixels[middle].right : changePixels[middle].left;
        if (range[end ? 1 : 0] < offset) low = middle + 1;
        else high = middle;
      }
      return low;
    };
    const start = Math.min(bound(0, offsets[0], true), bound(1, offsets[1], true));
    const end = Math.max(
      bound(0, offsets[0] + height, false),
      bound(1, offsets[1] + height, false),
    );
    for (let index = start; index < end; index++) {
      const value = changePixels[index],
        change = value.change;
      const a = value.left.map((y) => y - offsets[0]) as [number, number];
      const b = value.right.map((y) => y - offsets[1]) as [number, number];
      if (Math.max(a[1], b[1]) < 0 || Math.min(a[0], b[0]) > height) continue;
      const block = blocksByID.get(commitDiffChangeID(plan, change));
      if (blockControls && block) {
        for (const side of [0, 1] as const) {
          if (options.wholeFileAdded && side === 0) continue;
          const y = (side ? b : a)[0];
          if (y < 0 || y > height - RAIL_WIDTH - 20) continue;
          const button = commitDiffBlockControl(block, blockControls, side ? "toggle" : "rollback");
          const lineHeight = views[side].getOption(monaco.editor.EditorOption.lineHeight);
          button.style.top = `${y + Math.max(0, (lineHeight - BLOCK_ACTION_SIZE) / 2)}px`;
          controls[side].append(button);
        }
      }
      if (options.wholeFileAdded) continue;
      const path = document.createElementNS(SVG_NS, "path");
      path.dataset.kind = change.kind;
      path.setAttribute("d", commitDiffConnectorPath(centerWidth, a, b, gutter));
      path.classList.add(`commit-diff-connection-${change.kind}`);
      path.classList.add("independent-connection-fill");
      paths.append(path);
      const border = document.createElementNS(SVG_NS, "path");
      border.setAttribute("d", commitDiffConnectorBorderPath(centerWidth, a, b, gutter));
      border.classList.add(
        `commit-diff-connection-${change.kind}`,
        "independent-connection-border",
      );
      paths.append(border);
      for (const side of [0, 1] as const) {
        const range = side ? b : a;
        const empty = range[0] === range[1];
        for (const y of empty ? [range[0] - 1] : [range[0], range[1] - 1]) {
          if (y + (empty ? 2 : 1) <= 0 || y >= height - RAIL_WIDTH) continue;
          const top = Math.max(0, y),
            bottom = Math.min(height - RAIL_WIDTH, y + (empty ? 2 : 1));
          const edge = document.createElement("div");
          edge.className = `independent-chunk-border independent-overview-${change.kind}`;
          edge.dataset.kind = change.kind;
          edge.dataset.empty = String(empty);
          edge.style.cssText = `top:${top}px;height:${bottom - top}px`;
          edges[side].append(edge);
        }
      }
    }
    svg.replaceChildren(paths);
    actions.forEach((layer, side) => layer.replaceChildren(controls[side]));
    borders.forEach((layer, side) => layer.replaceChildren(edges[side]));
    views.forEach((view, side) => {
      if (options.wholeFileAdded && side === 0) return;
      const rows = side === 0 ? plan.left : plan.right,
        fragment = document.createDocumentFragment();
      const lineHeight = view.getOption(monaco.editor.EditorOption.lineHeight);
      for (const range of view.getVisibleRanges())
        for (let line = range.startLineNumber; line <= range.endLineNumber; line++) {
          const row = rows[line - 1],
            position = view.getScrolledVisiblePosition({ lineNumber: line, column: 1 });
          if (!row || !position) continue;
          const button = document.createElement("button");
          button.type = "button";
          button.tabIndex = -1;
          button.dataset.modelLine = String(line);
          button.dataset.side = String(side);
          const number = side === 0 ? row.oldLine : row.newLine;
          button.textContent =
            number === null ? (row.id.startsWith("fold-") ? "⋯" : "") : String(number);
          button.style.cssText = `top:${position.top}px;height:${lineHeight}px;line-height:${lineHeight}px`;
          if (blockControls) {
            button.style[side ? "paddingRight" : "paddingLeft"] = `${GUTTER_INSET + BLOCK_ACTION_WIDTH}px`;
            // IDEA's mirrored old gutter aligns numbers towards its action column.
            button.style.textAlign = side ? "right" : "left";
          }
          fragment.append(button);
        }
      numbers[side].replaceChildren(fragment);
      const { rail, thumb } = rails[side];
      const track = Math.max(0, height - RAIL_WIDTH),
        total = view.getScrollHeight(),
        viewport = view.getLayoutInfo().height;
      const max = Math.max(0, total - viewport),
        thumbHeight = Math.min(track, Math.max(24, (track * viewport) / Math.max(1, total)));
      thumb.style.height = `${thumbHeight}px`;
      thumb.style.top = `${max ? (offsets[side] / max) * (track - thumbHeight) : 0}px`;
      thumb.hidden = max === 0;
      rail.setAttribute("aria-valuemin", "0");
      rail.setAttribute("aria-valuemax", String(max));
      rail.setAttribute("aria-valuenow", String(offsets[side]));
    });
  }
  function decorate() {
    const values: monaco.editor.IModelDeltaDecoration[][] = [[], []];
    const muted = new Set<IndependentChange>();
    // Word comparison has a per-block limit plus a total character budget. Large
    // replacements keep whole-line highlighting instead of blocking scrolling.
    let wordBudget = 128_000;
    if (words)
      for (const change of plan.changes) {
        if (change.kind !== "modified") continue;
        const texts = [
          plan.left
            .slice(change.leftStart, change.leftEnd)
            .map((row) => row.left!)
            .join("\n"),
          plan.right
            .slice(change.rightStart, change.rightEnd)
            .map((row) => row.right!)
            .join("\n"),
        ];
        wordBudget -= texts[0].length + texts[1].length;
        if (wordBudget < 0) break;
        const ranges = commitDiffWordRanges(texts[0], texts[1]);
        if (ranges.left.length || ranges.right.length) muted.add(change);
        for (const side of [0, 1] as const) {
          const start = side ? change.rightStart : change.leftStart;
          for (const [a, b, kind] of side ? ranges.right : ranges.left) {
            const before = texts[side].slice(0, a).split("\n"),
              after = texts[side].slice(0, b).split("\n");
            values[side].push({
              range: new monaco.Range(
                start + before.length,
                before[before.length - 1].length + 1,
                start + after.length,
                after[after.length - 1].length + 1,
              ),
              options: { className: `independent-word-${kind}`, zIndex: 1 },
            });
          }
        }
      }
    // IDEA uses its middle background only when inner fragments were computed.
    // Native decorations stay below viewLines; never change syntax foregrounds.
    for (const change of plan.changes)
      for (const side of [0, 1] as const) {
        const start = side ? change.rightStart : change.leftStart,
          end = side ? change.rightEnd : change.leftEnd;
        if (end > start)
          values[side].push({
            range: new monaco.Range(start + 1, 1, end, 1),
            options: {
              isWholeLine: true,
              className: `commit-diff-line-${change.kind}${muted.has(change) ? " independent-line-muted" : ""}`,
            },
          });
      }
    [plan.left, plan.right].forEach((rows, side) =>
      rows.forEach((row, index) => {
        if (row.kind === "information")
          values[side].push({
            range: new monaco.Range(index + 1, 1, index + 1, 1),
            options: {
              isWholeLine: true,
              className: row.id.startsWith("fold-")
                ? "independent-fold"
                : "lithe-review-information",
            },
          });
      }),
    );
    decorations.forEach((value, side) => value.set(values[side]));
  }
  function replace() {
    // setValue emits cursor/scroll events synchronously. Neither navigation nor
    // scroll mapping may observe a new left model paired with the old right one.
    const wasReady = ready;
    ready = false;
    plan = planIndependentCommitDiff(rawRows, collapse, expanded);
    scrollAnchors = commitDiffScrollAnchors(plan.changes, plan.left.length, plan.right.length);
    digits = Math.max(
      3,
      ...[plan.left, plan.right].map((rows) =>
        rows.reduce(
          (max, row) => Math.max(max, String(row.oldLine ?? row.newLine ?? "").length),
          3,
        ),
      ),
    );
    models.forEach((model, side) => {
      const rows = side ? plan.right : plan.left;
      const text = rows.map((row) => (side ? row.right : row.left)).join("\n");
      if (model.getValue() !== text) model.setValue(text);
    });
    dirtyGeometry = true;
    decorate();
    layout();
    ready = wasReady;
    options.changed();
    schedule();
  }
  function expand(side: Side, line: number) {
    const row = (side ? plan.right : plan.left)[line - 1];
    if (!row?.id.startsWith("fold-")) return false;
    const top = views[side].getTopForLineNumber(line) - views[side].getScrollTop();
    expanded.add(row.id);
    replace();
    views[side].setScrollTop(Math.max(0, views[side].getTopForLineNumber(line) - top));
    return true;
  }
  function synchronizeScroll(side: Side) {
    if (options.wholeFileAdded || !ready || closed || syncing || scrollSyncPaused) return;
    const other: Side = side === 0 ? 1 : 0;
    const master = views[side],
      slave = views[other];
    const lineHeight = master.getOption(monaco.editor.EditorOption.lineHeight);
    const anchor = master.getLayoutInfo().height / 3;
    const offset = master.getScrollTop() + anchor;
    const line = Math.max(0, Math.floor(offset / lineHeight));
    const transfer = (value: number) => transferCommitDiffLine(scrollAnchors, side, value);
    const mapped = transfer(line);
    const top = (target: Side, value: number) => {
      const count = models[target].getLineCount();
      return value < count
        ? views[target].getTopForLineNumber(value + 1)
        : views[target].getBottomForLineNumber(count) +
            (value - count) * views[target].getOption(monaco.editor.EditorOption.lineHeight);
    };
    const phase = offset - top(side, line);
    const wanted = Math.round(
      Math.max(
        0,
        Math.min(
          slave.getScrollHeight() - slave.getLayoutInfo().height,
          top(other, mapped) - anchor + phase,
        ),
      ),
    );
    const current = slave.getScrollTop();
    // IDEA avoids sub-line backtracking when adjacent master lines map to one
    // slave line inside an unequal block. End boundaries resume exact alignment.
    const minorBackward = phase < lineHeight / 2 && line > 0 && mapped === transfer(line - 1);
    const minorForward = phase > lineHeight / 2 && mapped === transfer(line + 1);
    if (
      ((minorForward && wanted > current) || (minorBackward && wanted < current)) &&
      Math.abs(wanted - current) < lineHeight
    )
      return;
    if (Math.abs(wanted - current) < 1) return;
    syncing = true;
    try {
      slave.setScrollTop(wanted, monaco.editor.ScrollType.Immediate);
    } finally {
      syncing = false;
    }
  }
  function synchronizeHorizontalScroll(side: Side) {
    if (options.wholeFileAdded || !ready || closed || syncing || scrollSyncPaused) return;
    const other: Side = side === 0 ? 1 : 0;
    const offset = views[side].getScrollLeft();
    if (offset === views[other].getScrollLeft()) return;
    syncing = true;
    try {
      // Like IDEA, transfer pixels directly; the editor clamps its own range.
      views[other].setScrollLeft(offset, monaco.editor.ScrollType.Immediate);
    } finally {
      syncing = false;
    }
  }
  const subscriptions = views.flatMap((view, index) => {
    const side = index as Side;
    let pressed: monaco.Position | null = null;
    return [
      view.onDidScrollChange((event) => {
        if (event.scrollTopChanged) synchronizeScroll(side);
        if (event.scrollLeftChanged) synchronizeHorizontalScroll(side);
        schedule();
      }),
      view.onDidContentSizeChange(() => {
        dirtyGeometry = true;
        schedule();
      }),
      view.onDidChangeCursorPosition(() => {
        options.changed();
        schedule();
      }),
      view.onDidFocusEditorText(() => {
        focused = side;
        options.changed();
      }),
      view.onKeyDown((event) => {
        if (
          !(event.ctrlKey || event.metaKey) ||
          event.altKey ||
          event.shiftKey ||
          event.browserEvent.key.toLowerCase() !== "f"
        )
          return;
        const folds = plan.rows.filter((row) => row.id.startsWith("fold-"));
        if (!folds.length) return;
        event.preventDefault();
        event.stopPropagation();
        const position = view.getPosition(),
          row = (side ? plan.right : plan.left)[(position?.lineNumber ?? 1) - 1];
        folds.forEach((row) => expanded.add(row.id));
        replace();
        const line =
          (side ? plan.right : plan.left).findIndex((candidate) => candidate.id === row?.id) + 1;
        if (line > 0) view.setPosition({ lineNumber: line, column: position?.column ?? 1 });
        void view
          .getAction("actions.find")
          ?.run()
          .catch((error) => options.failed?.(error));
      }),
      view.onMouseDown((event) => {
        const position = event.target.position;
        if (position && expand(side, position.lineNumber)) return;
        pressed =
          event.event.leftButton &&
          (event.event.ctrlKey || event.event.metaKey) &&
          !event.event.shiftKey
            ? position
            : null;
      }),
      view.onMouseUp((event) => {
        const start = pressed;
        pressed = null;
        const position = event.target.position;
        if (start && position && start.equals(position) && view.getSelection()?.isEmpty())
          options.source(side, position.lineNumber, position.column);
      }),
    ];
  });
  const chooseLine = (event: MouseEvent) => {
    const button = (event.target as HTMLElement).closest<HTMLElement>("[data-model-line]");
    if (!button || event.button !== 0) return;
    event.preventDefault();
    const side = Number(button.dataset.side) as Side,
      line = Number(button.dataset.modelLine);
    if (expand(side, line)) return;
    const view = views[side],
      anchor = event.shiftKey ? (view.getSelection()?.selectionStartLineNumber ?? line) : line;
    view.setSelection({
      selectionStartLineNumber: anchor,
      selectionStartColumn: anchor <= line ? 1 : models[side].getLineMaxColumn(anchor),
      positionLineNumber: line,
      positionColumn: anchor <= line ? models[side].getLineMaxColumn(line) : 1,
    });
    view.focus();
  };
  center.addEventListener("mousedown", chooseLine);
  const wheel = (event: WheelEvent, railSide?: Side) => {
    if (event.ctrlKey || !event.cancelable) return;
    event.preventDefault();
    const side: Side =
      railSide ?? (event.clientX < root.getBoundingClientRect().left + width * ratio ? 0 : 1);
    const factor =
      event.deltaMode === 1
        ? views[side].getOption(monaco.editor.EditorOption.lineHeight)
        : event.deltaMode === 2
          ? height
          : 1;
    views[side].setScrollTop(
      views[side].getScrollTop() + event.deltaY * factor * WHEEL_SENSITIVITY,
      monaco.editor.ScrollType.Immediate,
    );
    views[side].setScrollLeft(
      views[side].getScrollLeft() + event.deltaX * factor * WHEEL_SENSITIVITY,
    );
  };
  center.addEventListener("wheel", wheel, { passive: false });
  const resize = (event: PointerEvent) => {
    if (event.button !== 0) return;
    event.preventDefault();
    drag?.dispose({ commit: false });
    drag = startDocumentResizeSession({
      startX: event.clientX,
      startWidth: width * ratio,
      clampWidth: (value) => Math.max(centerWidth / 2, Math.min(width - centerWidth / 2, value)),
      applyWidth: (value) => {
        ratio = width ? value / width : 0.5;
        layout();
      },
      commitWidth: (value) => {
        ratio = width ? value / width : 0.5;
        layout();
      },
      cursor: "ew-resize",
    });
  };
  const sashKey = (event: KeyboardEvent) => {
    if (!["ArrowLeft", "ArrowRight", "Home"].includes(event.key)) return;
    event.preventDefault();
    ratio =
      event.key === "Home"
        ? 0.5
        : Math.max(0.05, Math.min(0.95, ratio + (event.key === "ArrowLeft" ? -0.025 : 0.025)));
    layout();
  };
  sash.addEventListener("pointerdown", resize);
  sash.addEventListener("keydown", sashKey);
  const railListeners = rails.map(({ rail, thumb }, side) => {
    const railWheel = (event: WheelEvent) => wheel(event, side as Side);
    const down = (event: PointerEvent) => {
      if (event.button !== 0) return;
      event.preventDefault();
      drag?.dispose({ commit: false });
      const view = views[side],
        track = Math.max(0, height - RAIL_WIDTH),
        total = view.getScrollHeight(),
        max = Math.max(0, total - height);
      const thumbHeight = thumb.offsetHeight,
        travel = Math.max(1, track - thumbHeight);
      if (event.target !== thumb)
        view.setScrollTop(
          Math.max(
            0,
            Math.min(
              max,
              ((event.clientY - rail.getBoundingClientRect().top - thumbHeight / 2) / travel) * max,
            ),
          ),
          monaco.editor.ScrollType.Immediate,
        );
      const start = view.getScrollTop();
      drag = startDocumentResizeSession({
        startX: event.clientY,
        startWidth: 0,
        axis: "y",
        cursor: "default",
        clampWidth: (value) => value,
        applyWidth: (delta) =>
          view.setScrollTop(
            Math.max(0, Math.min(max, start + (delta / travel) * max)),
            monaco.editor.ScrollType.Immediate,
          ),
        commitWidth: (delta) =>
          view.setScrollTop(
            Math.max(0, Math.min(max, start + (delta / travel) * max)),
            monaco.editor.ScrollType.Immediate,
          ),
      });
    };
    const key = (event: KeyboardEvent) => {
      const view = views[side];
      const delta =
        event.key === "ArrowDown"
          ? view.getOption(monaco.editor.EditorOption.lineHeight)
          : event.key === "ArrowUp"
            ? -view.getOption(monaco.editor.EditorOption.lineHeight)
            : event.key === "PageDown"
              ? height
              : event.key === "PageUp"
                ? -height
                : 0;
      if (!delta && event.key !== "Home" && event.key !== "End") return;
      event.preventDefault();
      view.setScrollTop(
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? view.getScrollHeight()
            : view.getScrollTop() + delta,
        monaco.editor.ScrollType.Immediate,
      );
    };
    rail.addEventListener("pointerdown", down);
    rail.addEventListener("keydown", key);
    rail.addEventListener("wheel", railWheel, { passive: false });
    return () => {
      rail.removeEventListener("pointerdown", down);
      rail.removeEventListener("keydown", key);
      rail.removeEventListener("wheel", railWheel);
    };
  });
  const observer = options.observeResize
    ? options.observeResize(root, layout)
    : (() => {
        const value = new ResizeObserver(layout);
        value.observe(root);
        return value;
      })();
  layout();
  return {
    views,
    get plan() {
      return plan;
    },
    get focused() {
      return focused;
    },
    get ready() {
      return ready;
    },
    async update(
      rows: readonly ReviewRow[],
      language: string,
      fold: boolean,
      highlightWords: boolean,
    ) {
      const request = ++version;
      ready = false;
      options.changed();
      svg.replaceChildren();
      numbers.forEach((node) => node.replaceChildren());
      actions.forEach(node => node.replaceChildren());
      rails.forEach((value) => value.marks.replaceChildren());
      decorations.forEach((value) => value.clear());
      borders.forEach((layer) => layer.replaceChildren());
      await options.prepareLanguage(language);
      if (closed || request !== version) return;
      if (rawRows !== rows) expanded.clear();
      rawRows = rows;
      collapse = fold;
      words = highlightWords;
      models.forEach((model) => monaco.editor.setModelLanguage(model, language));
      ready = true;
      replace();
    },
    configure(settings: monaco.editor.IEditorOptions, tabSize: number) {
      withoutScrollSync(() =>
        views.forEach((view) =>
          view.updateOptions({
            ...settings,
            mouseWheelScrollSensitivity: WHEEL_SENSITIVITY,
            scrollbar: {
              vertical: "hidden",
              verticalScrollbarSize: 0,
              horizontal: "visible",
              horizontalScrollbarSize: RAIL_WIDTH,
              horizontalSliderSize: SLIDER_WIDTH,
              useShadows: false,
              alwaysConsumeMouseWheel: false,
              ignoreHorizontalScrollbarInContentHeight: true,
            },
          }),
        ),
      );
      models.forEach((model) => model.updateOptions({ tabSize }));
      layout();
    },
    refresh: schedule,
    setBlockControls(value?: CommitDiffBlockControls) {
      const hadControls = Boolean(blockControls);
      blockControls = value;
      blocksByID = new Map(value?.blocks.map(block => [block.id, block]));
      if (hadControls !== Boolean(value)) layout();
      schedule();
    },
    jump() {
      const position = views[focused].getPosition();
      if (ready && position) options.source(focused, position.lineNumber, position.column);
    },
    reveal(change: IndependentChange, takeFocus = true) {
      withoutScrollSync(() => {
        const side: Side = change.rightStart === change.rightEnd ? 0 : 1;
        const line = Math.min(
          models[side].getLineCount(),
          (side ? change.rightStart : change.leftStart) + 1,
        );
        views[side].setPosition({ lineNumber: line, column: 1 });
        // Explicit navigation positions both boundaries atomically; intermediate
        // cursor/reveal events must not remap the other side before its own reveal.
        for (const target of [0, 1] as const) {
          const start = target ? change.rightStart : change.leftStart;
          views[target].revealLineInCenter(
            Math.min(models[target].getLineCount(), start + 1),
            monaco.editor.ScrollType.Immediate,
          );
        }
        focused = side;
        if (takeFocus) views[side].focus();
        options.changed();
      });
    },
    dispose() {
      if (closed) return;
      closed = true;
      version++;
      if (frame !== null) cancelFrame(frame);
      observer.disconnect();
      drag?.dispose({ commit: false });
      subscriptions.forEach((value) => value.dispose());
      railListeners.forEach((remove) => remove());
      center.removeEventListener("mousedown", chooseLine);
      center.removeEventListener("wheel", wheel);
      sash.removeEventListener("pointerdown", resize);
      sash.removeEventListener("keydown", sashKey);
      decorations.forEach((value) => value.clear());
      views.forEach((view) => view.dispose());
      models.forEach((model) => model.dispose());
      root.remove();
    },
  };
}
