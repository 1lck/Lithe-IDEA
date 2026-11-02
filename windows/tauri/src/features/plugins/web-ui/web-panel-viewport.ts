import type { WebPanelLayout } from "./web-panel-session";

// Native child windows cannot be painted beneath DOM portals. Observe the
// existing semantic overlay owners, rather than recreating their open state.
const OVERLAYS =
  '[role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], [role="tooltip"], [data-native-web-overlay], [data-sonner-toast], [data-prevent-dialog-escape="true"]';

export function webPanelLayout(element: HTMLElement): WebPanelLayout {
  const rect = element.getBoundingClientRect();
  const viewport = element.ownerDocument.documentElement;
  const x = Math.max(0, rect.left);
  const y = Math.max(0, rect.top);
  const width = Math.max(0, Math.min(rect.right, viewport.clientWidth) - x);
  const height = Math.max(0, Math.min(rect.bottom, viewport.clientHeight) - y);
  const scale = element.ownerDocument.defaultView?.devicePixelRatio ?? 1;
  const occluded = [...element.ownerDocument.querySelectorAll<HTMLElement>(OVERLAYS)].some(
    (overlay) => {
      if (element.contains(overlay) || overlay.hidden || !overlay.getClientRects().length)
        return false;
      const style = element.ownerDocument.defaultView!.getComputedStyle(overlay);
      if (style.visibility === "hidden" || style.display === "none") return false;
      if (overlay.matches('[aria-modal="true"], [role="alertdialog"]')) return true;
      const bounds = overlay.getBoundingClientRect();
      return (
        bounds.left < x + width && bounds.right > x && bounds.top < y + height && bounds.bottom > y
      );
    },
  );
  return {
    bounds: { x: x * scale, y: y * scale, width: width * scale, height: height * scale },
    visible: !element.ownerDocument.hidden && width > 0 && height > 0 && !occluded,
    focus: false,
  };
}

/** Layout reads remain local and coalesce into one animation frame. Cleanup
 * cancels the frame and every observer before the native owner is released. */
export function observeWebPanelViewport(
  element: HTMLElement,
  update: (layout: WebPanelLayout) => void,
) {
  const document = element.ownerDocument;
  const view = document.defaultView!;
  let frame: number | undefined;
  let last = "";
  let disposed = false;
  const measure = () => {
    frame = undefined;
    if (disposed) return;
    const layout = webPanelLayout(element);
    const identity = JSON.stringify(layout);
    if (identity !== last) {
      last = identity;
      update(layout);
    }
  };
  const schedule = () => {
    if (!disposed && frame === undefined) frame = view.requestAnimationFrame(measure);
  };
  const resize = new view.ResizeObserver(schedule);
  // A neighboring pane can move this slot without changing its own size.
  // Observe its layout ancestors, keeping reads local to the same frame.
  for (let ancestor: HTMLElement | null = element; ancestor; ancestor = ancestor.parentElement)
    resize.observe(ancestor);
  const overlays = new view.MutationObserver(schedule);
  overlays.observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: [
      "role",
      "aria-modal",
      "aria-hidden",
      "hidden",
      "data-open",
      "data-closed",
      "data-native-web-overlay",
      "data-sonner-toast",
      "data-visible",
      "data-removed",
      "data-starting-style",
      "data-ending-style",
    ],
  });
  view.addEventListener("resize", schedule);
  document.addEventListener("scroll", schedule, true);
  document.addEventListener("visibilitychange", schedule);
  measure();
  return () => {
    disposed = true;
    if (frame !== undefined) view.cancelAnimationFrame(frame);
    resize.disconnect();
    overlays.disconnect();
    view.removeEventListener("resize", schedule);
    document.removeEventListener("scroll", schedule, true);
    document.removeEventListener("visibilitychange", schedule);
  };
}
