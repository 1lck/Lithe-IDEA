import { createWheelScrollAnimation } from "@/ui/wheel-scroll-animation";

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

interface HorizontalScrollContainer {
  scrollLeft: number;
  scrollWidth: number;
  clientWidth: number;
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

/**
 * Horizontal counterpart for touchpad side swipes. Only a container that overflows
 * horizontally moves, so vertical-only scrollers keep ignoring sideways gestures.
 */
export function applyHorizontalWheelToScrollContainer(
  element: HorizontalScrollContainer,
  deltaX: number,
) {
  if (deltaX === 0) return false;

  const maxScrollLeft = Math.max(0, element.scrollWidth - element.clientWidth);
  if (maxScrollLeft === 0) return false;
  const nextScrollLeft = Math.max(0, Math.min(maxScrollLeft, element.scrollLeft + deltaX));
  if (nextScrollLeft === element.scrollLeft) return false;

  element.scrollLeft = nextScrollLeft;
  return true;
}

function getLineHeight(element: HTMLElement) {
  const lineHeight = Number.parseFloat(getComputedStyle(element).lineHeight);
  return Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : 16;
}

function applyVerticalWheelEvent(
  element: HTMLElement,
  event: WheelEvent,
  animate?: (axis: "x" | "y", delta: number) => boolean,
) {
  if (event.ctrlKey || event.metaKey || event.defaultPrevented) return false;

  const delta = getWheelDeltaPixels(event, {
    lineHeight: getLineHeight(element),
    pageWidth: element.clientWidth,
    pageHeight: element.clientHeight,
  });

  // Sideways swipes latch onto the same clipped descendants as vertical ones, so a
  // horizontally scrollable container applies them itself too.
  if ((animate && event.shiftKey) || !isMostlyVerticalWheel(event.deltaX, event.deltaY)) {
    const horizontalDelta = animate && event.shiftKey && delta.x === 0 ? delta.y : delta.x;
    return animate
      ? animate("x", horizontalDelta)
      : applyHorizontalWheelToScrollContainer(element, horizontalDelta);
  }
  return animate ? animate("y", delta.y) : applyVerticalWheelToScrollContainer(element, delta.y);
}

export function bindScrollContainerWheel(
  element: HTMLElement,
  options: { smooth?: boolean; eventTarget?: HTMLElement; stopPropagation?: boolean } = {},
) {
  const eventTarget = options.eventTarget ?? element;
  const view = element.ownerDocument.defaultView;
  const scheduler = view ? {
    now: () => view.performance.now(),
    request: (callback: () => void) => view.requestAnimationFrame(callback),
    cancel: (id: number) => view.cancelAnimationFrame(id),
  } : null;
  const horizontal = options.smooth && scheduler ? createWheelScrollAnimation({
    read: () => element.scrollLeft,
    write: (position) => { element.scrollLeft = position; },
    maximum: () => Math.max(0, element.scrollWidth - element.clientWidth),
    scheduler,
  }) : null;
  const vertical = options.smooth && scheduler ? createWheelScrollAnimation({
    read: () => element.scrollTop,
    write: (position) => { element.scrollTop = position; },
    maximum: () => Math.max(0, element.scrollHeight - element.clientHeight),
    scheduler,
  }) : null;
  const stop = () => { horizontal?.stop(); vertical?.stop(); };
  const reducedMotion = view?.matchMedia?.("(prefers-reduced-motion: reduce)");
  const animate = (axis: "x" | "y", delta: number) => {
    if (reducedMotion?.matches) {
      stop();
      return axis === "x"
        ? applyHorizontalWheelToScrollContainer(element, delta)
        : applyVerticalWheelToScrollContainer(element, delta);
    }
    return (axis === "x" ? horizontal : vertical)?.scroll(delta) ?? false;
  };
  const onWheel = (event: WheelEvent) => {
    if (!event.cancelable) return;
    if (!applyVerticalWheelEvent(element, event, vertical ? animate : undefined)) return;
    event.preventDefault();
    if (options.stopPropagation) event.stopPropagation();
  };
  const onVisibilityChange = () => {
    if (element.ownerDocument.hidden) stop();
  };

  eventTarget.addEventListener("wheel", onWheel, { capture: true, passive: false });
  if (vertical) {
    eventTarget.addEventListener("keydown", stop, true);
    eventTarget.addEventListener("pointerdown", stop, true);
    element.ownerDocument.addEventListener("visibilitychange", onVisibilityChange);
  }
  return () => {
    eventTarget.removeEventListener("wheel", onWheel, { capture: true });
    eventTarget.removeEventListener("keydown", stop, true);
    eventTarget.removeEventListener("pointerdown", stop, true);
    element.ownerDocument.removeEventListener("visibilitychange", onVisibilityChange);
    stop();
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
