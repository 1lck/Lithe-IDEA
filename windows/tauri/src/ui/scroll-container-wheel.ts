const DOM_DELTA_LINE = 1;
const DOM_DELTA_PAGE = 2;

// Chromium/WebView2 can latch wheel events onto overflow:hidden descendants
// instead of the intended scroller. Apply the delta to the real container.

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

export function applyVerticalWheelToScrollContainer(
  element: VerticalScrollContainer,
  deltaY: number,
) {
  if (deltaY === 0) return false;

  const maxScrollTop = Math.max(0, element.scrollHeight - element.clientHeight);
  const nextScrollTop = Math.max(0, Math.min(maxScrollTop, element.scrollTop + deltaY));
  if (nextScrollTop === element.scrollTop) return false;

  element.scrollTop = nextScrollTop;
  return true;
}

function getLineHeight(element: HTMLElement) {
  const lineHeight = Number.parseFloat(getComputedStyle(element).lineHeight);
  return Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : 16;
}

function applyVerticalWheelEvent(element: HTMLElement, event: WheelEvent) {
  if (event.ctrlKey || event.metaKey || event.defaultPrevented) return false;
  if (!isMostlyVerticalWheel(event.deltaX, event.deltaY)) return false;

  const delta = getWheelDeltaPixels(event, {
    lineHeight: getLineHeight(element),
    pageWidth: element.clientWidth,
    pageHeight: element.clientHeight,
  });

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
