const DOM_DELTA_LINE = 1;
const DOM_DELTA_PAGE = 2;

// Chromium/WebView2 can latch wheel events onto overflow:hidden tree rows
// instead of the sidebar scroller. Apply the delta to the real container.

export const SIDEBAR_SCROLL_CONTAINER_SELECTOR =
  "[data-slot='scroll-area-viewport'], [data-scroll-container], .file-tree-container";

interface WheelDeltaEvent {
  deltaX: number;
  deltaY: number;
  deltaMode: number;
}

interface WheelDeltaMetrics {
  lineHeight: number;
  pageWidth: number;
  pageHeight: number;
}

interface VerticalScrollContainer {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

export function isMostlyVerticalWheel(deltaX: number, deltaY: number) {
  return Math.abs(deltaY) >= Math.abs(deltaX);
}

export function getWheelDeltaPixels(event: WheelDeltaEvent, metrics: WheelDeltaMetrics) {
  if (event.deltaMode === DOM_DELTA_LINE) {
    return {
      x: event.deltaX * metrics.lineHeight,
      y: event.deltaY * metrics.lineHeight,
    };
  }

  if (event.deltaMode === DOM_DELTA_PAGE) {
    return {
      x: event.deltaX * metrics.pageWidth,
      y: event.deltaY * metrics.pageHeight,
    };
  }

  return { x: event.deltaX, y: event.deltaY };
}

export function canScrollVerticallyInDirection(
  element: VerticalScrollContainer,
  deltaY: number,
) {
  if (deltaY === 0) return false;

  const maxScrollTop = Math.max(0, element.scrollHeight - element.clientHeight);
  if (maxScrollTop <= 0) return false;
  if (deltaY < 0) return element.scrollTop > 0;
  return element.scrollTop < maxScrollTop;
}

export function applyVerticalWheelToScrollContainer(
  element: VerticalScrollContainer,
  deltaY: number,
) {
  if (!canScrollVerticallyInDirection(element, deltaY)) return false;

  const maxScrollTop = Math.max(0, element.scrollHeight - element.clientHeight);
  element.scrollTop = Math.max(0, Math.min(maxScrollTop, element.scrollTop + deltaY));
  return true;
}

/**
 * Decide whether a capture-phase outer scroller should yield to a nested
 * scrollable (textarea / overflow container) that can still move in `deltaY`.
 */
export function resolveWheelScrollChainTarget(args: {
  nestedCanScrollInDirection: boolean;
  outerCanScrollInDirection: boolean;
}): "nested" | "outer" | "none" {
  if (args.nestedCanScrollInDirection) return "nested";
  if (args.outerCanScrollInDirection) return "outer";
  return "none";
}

/** Pure composedPath walk used by tests and mirrored by the DOM helper below. */
export function findNestedScrollableInComposedPath(args: {
  path: Array<{ id: string; scrollable: boolean; canScrollInDirection: boolean }>;
  outerId: string;
}): string | null {
  for (const node of args.path) {
    if (node.id === args.outerId) break;
    if (!node.scrollable) continue;
    if (node.canScrollInDirection) return node.id;
  }
  return null;
}

function getLineHeight(element: HTMLElement) {
  const lineHeight = Number.parseFloat(getComputedStyle(element).lineHeight);
  return Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : 16;
}

function isVerticallyScrollableElement(element: HTMLElement) {
  if (element instanceof HTMLTextAreaElement) {
    return element.scrollHeight > element.clientHeight;
  }

  const overflowY = getComputedStyle(element).overflowY;
  if (overflowY !== "auto" && overflowY !== "scroll" && overflowY !== "overlay") {
    return false;
  }
  return element.scrollHeight > element.clientHeight;
}

function findNestedVerticalScrollTarget(
  outer: HTMLElement,
  event: WheelEvent,
  deltaY: number,
): HTMLElement | null {
  const path = typeof event.composedPath === "function" ? event.composedPath() : [];
  for (const node of path) {
    if (!(node instanceof HTMLElement)) continue;
    if (node === outer) break;
    if (!outer.contains(node)) continue;
    if (!isVerticallyScrollableElement(node)) continue;
    if (canScrollVerticallyInDirection(node, deltaY)) return node;
  }
  return null;
}

function applyVerticalWheelEvent(element: HTMLElement, event: WheelEvent) {
  if (event.ctrlKey || event.metaKey || event.defaultPrevented) return false;
  if (!isMostlyVerticalWheel(event.deltaX, event.deltaY)) return false;

  const delta = getWheelDeltaPixels(event, {
    lineHeight: getLineHeight(element),
    pageWidth: element.clientWidth,
    pageHeight: element.clientHeight,
  });

  const nested = findNestedVerticalScrollTarget(element, event, delta.y);
  const target = resolveWheelScrollChainTarget({
    nestedCanScrollInDirection: nested !== null,
    outerCanScrollInDirection: canScrollVerticallyInDirection(element, delta.y),
  });

  if (target === "nested" || target === "none") return false;
  return applyVerticalWheelToScrollContainer(element, delta.y);
}

export function bindScrollContainerWheel(element: HTMLElement) {
  const onWheel = (event: WheelEvent) => {
    if (!applyVerticalWheelEvent(element, event)) return;
    event.preventDefault();
  };

  element.addEventListener("wheel", onWheel, { capture: true, passive: false });
  return () => {
    element.removeEventListener("wheel", onWheel, { capture: true });
  };
}

export function bindOverlayWheelToScrollContainer(
  overlay: HTMLElement,
  getScrollContainer: () => HTMLElement | null,
) {
  const onWheel = (event: WheelEvent) => {
    const element = getScrollContainer();
    if (!element) return;
    if (!applyVerticalWheelEvent(element, event)) return;
    event.preventDefault();
  };

  overlay.addEventListener("wheel", onWheel, { passive: false });
  return () => {
    overlay.removeEventListener("wheel", onWheel);
  };
}

export function querySidebarScrollContainer(root: ParentNode | null) {
  if (!root) return null;
  return root.querySelector<HTMLElement>(SIDEBAR_SCROLL_CONTAINER_SELECTOR);
}
